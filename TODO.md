# TODO: Plan Mode（AlayaFace）

Tracking file for the **Plan Mode** feature (任务规划 → DAG → 执行/重试)。
If interrupted, the next agent should read `docs/plan-mode.md` first, then
continue from the first unchecked item in this file.

> This file IS git-tracked (unlike before). Design doc: `docs/plan-mode.md`
> (authoritative). Old Go-backend notes archived at `docs/go-backend-todo.md`.

## How to continue after an interruption (read first)

1. Read `docs/plan-mode.md` — full design (architecture, schema, runner state
   machine, backend changes, constraints C1–C5).
2. Read this file — progress table + phase checklists. Start from the first
   `[ ]` item in the earliest non-complete phase.
3. Constraints reminder: **NEVER modify AlayaCore** (it's a separate repo);
   dual backend parity (Rust + Go, same JSON contract); Elm logic stays pure
   (`Plan/*` modules, elm-test); all new params optional/backward-compatible.
4. Update this file (checkboxes + progress table) as you go. Commit when a
   phase is done.

## Environment / verification

```bash
# Elm (src-elm/)
cd src-elm && elm-test                       # unit tests
elm make src/Main.elm --output=elm.js        # compile

# Rust (src-tauri/)
cd src-tauri && cargo test                   # unit tests
cargo build

# Go (src-go/)
cd src-go && go vet ./... && go test -race ./...
go run ./cmd/alayaface-server --addr 127.0.0.1:8765 --static ../src-elm
```

Manual E2E: `make run` (Tauri) or browser via Go backend + `make run-go`.
Integration tests use `src-go/internal/fakecore` (scriptable alayacore stand-in).

## Progress

| Phase | Status |
|-------|--------|
| P0 Plan data model + detection (pure Elm) | [x] |
| P1 fs_write_file_text / fs_read_file_text (Rust+Go+bridge+Ports) | [x] |
| P2 Create Plan flow + plans dir + Plans manager | [x] |
| P3 DAG layout + SVG view + node→session click | [x] |
| P4 Runner state machine + retry + run.json + resume | [x] |
| P4.5 create_session preset/builtinTools + settings.conf + seed presets | [x] |
| P5 Polish (badges/logs/concurrency/export/docs/README) | [x] |
| P6 Plan Session (menu entry, --system planner prompt, [Plan] title) | [x] |
| P7 Plan windows (multi-instance, ⚙ menu list) + SendPrompt fix | [x] |
| P8 Node↔session binding: click node opens/resumes its session | [x] |
| P9 Keep failed/canceled sessions reopenable (lastSessionId) | [x] |
| P10 Review pass: runner race fixes + orphan cleanup | [x] |
| P11 Review pass 2: create-queue serialization + create-failure recovery | [x] |
| P12 Graceful close (save+EOF+grace) + dead-code cleanup + acceptance doc | [x] |
| P13 Attempt-session history (attempt_session_ids + detail-panel list) | [x] |
| P14 Concurrency selector in the plan header | [x] |

## P11 — 第二轮审查：创建队列串行化 + 创建失败恢复

- [x] **create_session 失败死锁**：此前失败只在 bridge console.error，Elm
      永远收不到 SessionCreated → `planCreating` 永远不释放 → 后续所有
      创建（runner + 用户）全部排队卡死（如节点 preset 无效时整个 run
      挂起）。新增 `onSessionCreateError` 端口（Ports+bridge+Main）+
      `SessionCreateError` Msg + Runner `SessionCreateFailed` 事件
      （Starting 节点按失败处理 → 自动重试/最终 Failed，不再悬挂）；
- [x] **用户创建与 runner 创建竞态（根治）**：会话创建改为**统一串行队列**
      `planCreateQueue : List CreateTask`（`RunnerCreate planId nodeId` /
      `UserCreate "normal" | "plan"`），`planCreating : Maybe CreateTask`；
      用户点击 New Session/Plan Session 在 runner 创建期间自动排队，
      SessionCreated 按标记区分：RunnerCreate→绑定节点，UserCreate→只激活
      并排空队列 → 用户会话永远不会被误绑到 runner 节点；
- [x] **runner 会话不抢焦点**：SessionCreated 中 runner 创建不激活/不聚焦
      （用户在看 DAG，点节点才打开）；`pendingSwitchOnCreate` 仅被非
      runner 会话消费（resume/用户创建不被 runner 会话偷走）；
- [x] **planResumeNode 消费加守卫**：仅非 runner 会话消费，runner 会话
      不会错误重绑；
- [x] **fs 列表污染**：run.json 每次 step 都会写 → FsWriteResult 触发
      refreshPlanList（plans 目录 list）→ 管理器未打开时结果落入文件
      选择器分支污染其列表 → 仅管理器打开时才刷新；
- [x] 测试：Elm 128（新增 SessionCreateFailed 3 例：Starting 失败→Waiting
      重试、非 Starting 忽略、耗尽→Failed）；Rust 35；Go 全绿。

## P12 — 优雅关闭 + 死代码清理 + 验收文档（无 GUI 轮次）

- [x] **close_session 优雅关闭（v2 backlog → 已实现）**：alayacore 只读
      核实（save CI 空参数→session.alaya；EOF+活动任务→drainUntilTaskDone
      跑完并 handleTaskDone 自动保存后退出；EOF+无任务→直接退出；rawio
      无 SIGINT 处理，EOF 是唯一优雅退出信号）。实现：save CI → 关 stdin
      （EOF）→ 等 ≤5s 自然退出 → SIGKILL 兜底（双后端对称）：
  - [x] Rust `alayacore.rs`：`close_child_gracefully`（try_lock 写 save
        帧→槽位置 None 关管道→宽限等待→SIGKILL）+ `kill_child` 改
        「先 EOF 宽限 3s 再杀」；`SessionHandle.stdin` 改
        `Arc<tokio::sync::Mutex<Option<ChildStdin>>>`（close 时真正
        EOF，不依赖 Arc 计数）；io.rs/mod.rs 写方对 None 返回
        "Session is disconnected"；
  - [x] Go `session.go`：`closeGracefully`（SendCmd save → Stdin.Close →
        轮询 Connected() 等 reader 观察自然退出 → 超时 kill）——
        **不自己调 cmd.Wait()**（os/exec 禁并发 Wait，-race 实测告警，
        收割统一归 reader 的 killOnce）；`core.go` KillChild 同步改
        宽限式；
  - [x] fakecore 新增 `save` 命令（写 session.alaya 标记）→ 集成测试
        `TestIntegrationGracefulCloseSavesSession`（close 后文件含
        saved 标记 + 二次 close 报 Session not found）；
  - [x] Rust 单测 +4（save 帧到达子进程 stdin / 倔强子进程超时被杀 /
        kill_child 先宽限自然退出 / 已死子进程不 panic）→ Rust 39；
  - [x] 已知限制：宽限内没跑完的长任务仍被 SIGKILL（save 已先行落盘）；
- [x] **死代码清理**：`PlanWindow.creating`/`createQueue` 遗留字段删除
      （P7 全局化后无用，仅声明+初始化无引用）；Elm 128 保持全绿；
- [x] **验收文档**：新增 `docs/manual-acceptance.md`（GUI 可用时的完整
      冒烟清单：Plan Session→Create Plan→Run→节点绑定→重试→优雅关闭→
      presets→回归；含已知限制说明）；
- [x] 文档同步：docs/plan-mode.md（§8.3 优雅关闭、§10 持久化、§13 默认值、
      §14 参考）、docs/go-backend.md（close_session 行 + killChild 说明）、
      README（优雅关闭段落）；
- [x] 测试：Elm 128 / Rust 39 / Go 全绿（-race）。
- [ ] MANUAL smoke（GUI 环境，照 docs/manual-acceptance.md 执行）

## P13 — 历史尝试会话列表（attempt_session_ids）

P9 遗留：重试后 `lastSessionId` 被新会话替换，失败那次尝试的会话目录
虽在磁盘上却不可达（只能经 last_session_id 看最近一次）。

- [x] `NodeRunState` 新增 `attemptSessions : List String`：**所有**绑定过该
      节点的会话 id（去重、顺序保留）；`bindSession` 时追加；重试/Stop/
      重新 Run 都**不**清空（跨 run 保留，旧会话目录仍在，可随时
      `resume_session` 回看）；只有全新 RunState 才为空；
- [x] run.json codec：`attempt_session_ids` 编码 + lenient 解码（elm/json
      无 map9 → 嵌套 map2 叠加，旧文件缺字段 → []，兼容 P12 之前的文件）；
- [x] UI：节点详情面板新增「历史会话 (N)」列表（短 id 按钮，monospace）；
      点击 → `PlanOpenAttemptSession planId nodeId sid`：
      - 会话存活 → ActivateSession 聚焦；
      - 已关闭 → `resume_session` + pendingSwitchOnCreate 聚焦 +
        planResumeOwner 错误路由；**planResumeNode = Nothing** —— 与
        PlanOpenNodeSession 不同，历史视图**不重绑**节点，当前活跃绑定
        不被破坏；
- [x] 测试：runner（跨重试累积 [s1,s2]、重复绑定不重复、重新 Run 保留
      历史）+ codec roundtrip（attempt_session_ids 双节点断言）+ lenient
      （缺字段 → []）；Elm 131 全绿；
- [x] 文档同步：docs/plan-mode.md §10（三字段持久化）；TODO 进度表；
      docs/manual-acceptance.md 增补历史会话验收项。

## P14 — Plan 头部并发度选择器

- [x] `PlanViewState.concurrencyInput`（留空 = 用 plan JSON 的 concurrency）；
      头部控件行新增数字输入框（1–8，title 提示默认值）；
- [x] 纯函数 `Plan.Types.parseConcurrency : String -> Maybe Int`：trim、
      无效/空 → Nothing（回退 plan 默认），有效整数 clamp 1–8（0→1，
      99→8）；导出 + 6 例单测；
- [x] `PlanRunStartAt` 两条路径（首次 Run / 完成后重 Run）都应用覆盖：
      `{ baseRun | concurrency = c }`（重 Run 保留旧 run 状态，节点状态
      由 StartRun 复位，仅替换 concurrency）；`PlanSetConcurrency` Msg
      经 updateActivePlanWin 写回；
- [x] 文档同步：TODO 进度表（P5 遗留项销项）；docs/manual-acceptance.md
      增补并发输入验收项；
- [x] 测试：Elm 137（+6 parseConcurrency）全绿。

## P10 — 全面审查修复（评审轮）

- [x] **Stop + 退避计时器 bug**：Stop 后迟到的自动重试会复活 Canceled 节点并
      重新激活 Stopped run → 新增 `RetryTick`（自动 tick 只 Waiting→Pending，
      不复活/不激活）与 `RetryNode`（手动重试，可复活）分离；
- [x] **ScheduleRetry 重复计时器**：原每个 step 对每个 Waiting 节点都发
      一次 → 改为仅节点**刚进入** Waiting 时发一次（与 step 输入态比较，
      修正 finishStep 拿到事件后状态导致去重失效的问题）；
- [x] **孤儿会话泄漏**：Stop/关闭 plan 窗口与 in-flight create 竞争时，
      创建的会话无人绑定、窗口/进程泄漏 → `PlanBindSession` 检测绑定失败
      （节点非 Running）即关闭该会话（窗口+进程）；
- [x] **Stop/PlanClose 未清创建队列** → 现在按 planId 过滤
      `planCreateQueue`；
- [x] **resume 失败未清 planResumeNode** → 后续任意 SessionCreated 会把
      无关会话错误绑定到该节点 → 成功/失败路径都清理
      `planResumeOwner`/`planResumeNode`；
- [x] **静默自动恢复覆盖新 run 竞态**：打开 plan 后立刻点 Run，迟到的
      run.json 恢复会覆盖新 run → 仅当窗口尚无 run 时才静默恢复；
- [x] **open/import 失败 UX**：错误显示在 Plans 管理器（而不是创建一个
      错误窗口）；
- [x] 清理死代码（Runner.isTerminal 未使用）；`toolConfirm="allow"` 语义
      加注释（alayacore 的 --tool-confirm 是「需确认的工具名列表」，
      "allow" 匹配不到任何工具 = 全部自动放行；有安全提示）；
- [x] 验证过无问题的项：session id(UUID) vs plan key 无冲突；fs 命令双后端
      parity；run.json 双字段 roundtrip；重放渲染完整性（HandlersTest）；
- [x] 测试：Elm 125（新增 stop+tick 不复活、手动 Retry 复活、单次重试
      计时器、Canceled 绑定不发 prompt）；Rust 35；Go 全绿。

## P9 — 失败/停止节点的会话不再丢失（lastSessionId）

评审反馈：点击 node 打开的 session 内容不完整 / 有的 session 丢失。

排查结论：
- 内容完整性：alayacore 在每次任务结束（handleTaskDone）时把**完整会话**
  写入 `session.alaya`（先保存、后发 task-done 帧），resume 时按序重放
  UT/AT/AF/UF/AR（带 history id）。新增 HandlersTest 验证 UI 能把重放的
  完整历史（用户 prompt/助手文本/工具调用/工具结果/最终回答）全部渲染；
  仅「app 在任务进行中被杀」会丢失进行中的那一轮（alayacore 保存时机
  限制，C1 不改 alayacore）。
- session 丢失根因：`closeAndClear` 对 Failed/Waiting/Canceled 节点**清空
  sessionId** → run.json 无绑定 → 重启后点击节点只剩详情面板，会话目录
  虽在却无法找回。

修复：
- [x] `NodeRunState` 新增 `lastSessionId`：关闭会话时保留（`session_id`
      清空避免重复 close，`last_session_id` 持久化到 run.json，codec
      lenient 兼容旧文件）；`bindSession` 同时写两者；重跑时两者清空；
- [x] `PlanOpenNodeSession` 优先级：sessionId（活）→ sessionId（死，
      resume）→ lastSessionId（resume，失败/停止节点的会话可回看）→
      详情面板；
- [x] resume 成功后（resume_session 每次发新 UUID）经 `planResumeNode`
      在 SessionCreated 中把节点**重新绑定**到新 id（`rebindNodeSession`），
      再次点击直接聚焦，不再报 "Session is already active"；
- [x] 测试：runner（失败保留 lastSessionId、重跑清空）、codec roundtrip
      （last_session_id）、HandlersTest 重放渲染；Elm 121 全绿。

## P8 — 节点 ↔ 会话绑定（点击节点打开对应 session）

- [x] 节点点击改为 `PlanOpenNodeSession planId nodeId`：
      sessionId 存活 → `ActivateSession` 聚焦；已关闭/重启后 → 自动
      `resume_session` 从磁盘恢复（`pendingSwitchOnCreate` 聚焦，恢复失败
      错误显示在 plan 窗口顶部，经 `planResumeOwner` 路由）；
      无 session（Failed/Blocked/Canceled）→ 节点详情面板；
- [x] 打开/导入 plan 窗口时**静默自动恢复** `<plan>.run.json`
      （`PlanReadTarget.continueRun=False`，best-effort：无文件/损坏忽略），
      恢复各节点状态与 `session_id` 绑定 —— 点击任意已运行节点即可重新
      打开其会话；`Load run`（continueRun=True）保持原语义（恢复后继续执行）；
- [x] 会话窗口标题显示绑定标记 `[Plan · planId/nodeId]`
      （`planNodeSessions : Dict String String`，绑定于 PlanBindSession /
      PlanOpenNodeSession 恢复时，CloseSession/DeleteSession 移除）；
- [x] 文档同步（docs/plan-mode.md §7.1/§10）；Elm 118 全绿（run-state
      codec 已断言 sessionId roundtrip）。

## P7 — Plan windows + runner prompt dispatch fix（评审反馈）

- [x] **Plan 界面改为独立窗口**（不再是 overlay）：`planWindows : Dict
      String PlanWindow` + `planOrder` + `planActiveId`，每个窗口自带
      `view`/`run`/`runPath`/`runLog`/`selectedNode`/`creating`/`createQueue`/
      `resumePath`；窗口可拖动/缩放/关闭（复用 `windowPositions` + drag/
      resize 机制，新增 `PlanWindowDragStart`/`PlanResizeStart`/`PlanActivate`/
      `PlanClose`）；多 plan 可同时打开、独立运行；
- [x] **系统菜单（⚙）列出所有打开的 plan**（名称 + 运行状态），点击置顶激活
      （`viewGlobalMenuPlan`）；Plans 管理器保留为 launcher（open/delete/import）；
- [x] **Run 后节点会话为空的问题已修复**：`Plan/Runner.elm` 从未生成
      `SendPrompt` effect（只定义了类型/处理端），导致会话创建并绑定为
      `Running` 后 prompt 从未发送。现在 `bindSession`（Starting→Running）
      恰好发出一次 `SendPrompt`；测试覆盖（绑定发 prompt、重复绑定不发、
      全生命周期 create→bind→prompt→done）；
- [x] **第二轮修复（仍空窗口）**：修复后 SendPrompt 虽已生成，但
      `runStepIn` 用 step **前**的旧 run 状态应用 effects → `nodePromptIn`
      按 sessionId 查 prompt 返回空串被丢弃。修复：① effects 改为在
      step **后**状态上应用（runStepIn 先更新窗口 run 再 dispatch）；
      ② `SendPrompt` 改为携带 prompt 文本（runner 绑定会话时从 plan
      解析），Update 层不再依赖查表，杜绝此类丢失；新增测试
      “SendPrompt carries the exact plan prompt”；Elm 测试 118；
- [x] 手动关闭节点会话窗口 → 注入 `SessionDisconnected`（防 runner 悬挂）；
- [x] `planCreating`/`planCreateQueue` 升级为 `(planId, nodeId)` 全局串行，
      `SessionCreated` → `PlanBindSession ts planId nodeId sid` 无歧义绑定；
      runner 事件（TaskDone/Error/Disconnect）按 sessionId 路由到所属窗口
      （`findPlanIdBySession`）；
- [x] FsReadResult 改为 `planReadTarget`（planId/path/isResume）路由：
      打开/导入 → 新建或聚焦窗口；Load run → 恢复该窗口 run 并 ContinueRun；
- [x] 文档同步（docs/plan-mode.md §7.1/偏差说明、README）；
- [x] 测试：Elm 117（新增 prompt dispatch 3 例）。

## Design decisions (defaults, see docs/plan-mode.md §13)

- Concurrency default 2 (1–8); default_max_attempts 3; retry backoff 2s.
- Failure = SM task_error | SM error | session disconnect. Timeout: OFF (v2).
- v1 prompts are self-contained (no upstream output injection).
- Runner sessions: toolConfirm="allow"; node-level `preset`/`tools` optional.
- Persistence: `~/.alayaface/plans/<planId>.json` + `<planId>.run.json`.
- Resume v1 = re-run unfinished/failed/blocked nodes from scratch (new sessions).
- Seed presets: Default / Fast / Deep / Data / Safe (Safe disables execute_command).
- `--builtin-tools` semantics: empty config = don't pass flag = alayacore all-on;
  non-empty comma list = subset. MCP-only ("none") deferred to v2.

---

## P0 — Plan data model + detection (pure Elm)

- [x] `src/Plan/Types.elm`: Plan / TaskNode / NodeStatus / RunState / FailureRecord
      types + JSON decoders/encoders (snake_case, matching schema in design §5)
- [x] `Plan/Types.elm`: normalize (fill defaults: concurrency=2,
      default_max_attempts=3, depends_on=[], max_attempts←default,
      schema_version=1) + validate (id unique/non-empty, title/prompt non-empty,
      deps exist, no self-dep, Kahn cycle detection) → readable error list
- [x] `Plan/Detect.elm`: `extractPlanJson : String -> Maybe String` (first
      ```json … ``` fence, unescape)
- [x] tests: `tests/PlanTypesTest.elm` (decode ok/err, cycle, unknown dep, dup id,
      normalize, roundtrip) + `tests/PlanDetectTest.elm` (fence edges: no fence,
      empty, multiple, ```json vs ```text, CRLF)
- [x] `elm-test` green (87 tests; note: elm-explorations/test 2.2.0 has no
      Expect.true/false — use Expect.equal True; RunStatus ctors renamed
      InProgress/FailedRun to avoid NodeStatus ctor clash)

## P1 — fs_write_file_text / fs_read_file_text (dual backend)

- [x] Rust `src-tauri/src/commands/fs.rs`: `fs_write_file_text(path, content,
      createParents)` + `fs_read_file_text(path)`; errors
      `Cannot write file: ...` / `Cannot read file: ...`; register in
      `lib.rs generate_handler!`
- [x] Go `src-go/internal/server/handlers/fs.go`: same commands + register in
      RPC dispatcher; error-message parity with Rust
- [x] `src-elm/src/Ports.elm`: `fsWriteFileText` / `fsReadFileText` ports +
      `onFsWriteResult` / `onFsReadResult` subs
- [x] `src-elm/bridge.js`: wire both ports (invoke + result ports)
- [x] `src-elm/src/Main.elm`: subscriptions for result ports; new Msg(s) in
      App/Types + App/Update handlers (FsWriteResult/FsReadResult — NoOp
      until P2 wires them into plan save/load)
- [x] Tests: Rust fs roundtrip + createParents + errors; Go same + parity
      (server/fs_test.go via testEnv, full HTTP path)
- [x] `cargo test` (30) + `go test -race` + `elm-test` (87) green

## P2 — Create Plan flow + plans dir + Plans manager

- [x] App shell integration: `showPlanView`, `planView`, `planManager`,
      `pendingPlanOffers`, `homeDir` in App/Types Model; Msg wiring in
      Main/Update
- [x] "Create Plan" button under assistant message when `pendingPlanOffers`
      has an entry for it (View)
- [x] Create Plan flow: detect ```json in AT frame → offer → decode→validate→
      normalize→planId (name slug + timestamp)→ `fs_write_file_text` to
      `~/.alayaface/plans/<planId>.json` (createParents)→ open Plan window;
      validation errors shown in Plan view
- [x] Plans manager overlay: list `~/.alayaface/plans/*.json` (via fs_home_dir +
      fs_list_dir, filters out *.run.json), Open / Delete / Import via path input
      (added fs_delete_file command Rust+Go+ports+tests)
- [x] Global menu: "Plans" entry (🕸)
- [x] Plan view (P2 list form; P3 upgrades to SVG DAG): name/goal/meta/path +
      task list with id/title/preset/deps
- [ ] MANUAL smoke (Go backend browser / Tauri) — GUI env; checklist in docs/manual-acceptance.md
- [x] Note: fs_list_dir results are shared with the file picker; the
      FsListDirResult branch routes to plan list when planManager.show
- [x] Note: Elm record-update requires a variable on the left — cannot
      `{ model.planManager | ... }`; bind `pm = model.planManager` first

## P3 — DAG layout + SVG view + node→session click

- [x] `Plan/Layout.elm`: Kahn longest-path layering → columns; per-node (x,y);
      orthogonal edge routing (same-row: right→left horizontal; diff-row:
      bottom→top). Tests: diamond/chain/parallel layers + geometry
      (plan-layout tests, 8 cases)
- [x] `Plan/View.elm`: HTML/CSS DAG canvas (NO elm/svg — not in offline
      package cache; pure-div rendering), node cards (title, status color,
      retry badge, preset badge, hover failure reason), edges, node click
- [x] Node click → `PlanSelectNode` → detail panel (prompt, deps, preset,
      maxAttempts, Retry placeholder disabled); session-open wiring lands
      in P4 (needs node→session association)
- [x] Plan window header: name/goal/meta + Run/Pause/Stop (disabled
      placeholders, enabled in P4) + Export JSON (path input +
      fs_write_file_text; setPlanErrors now preserves the open plan)
- [x] CSS (style.css): plan-dag/plan-node/edge/detail styles
- [x] Elm 95 tests green
- [ ] Manual visual acceptance — GUI env; checklist in docs/manual-acceptance.md
- [x] Note: `Expect.lessThan a b` asserts b < a in test 2.2.0 (argument
      order is expected-first, actual-second) — use `Expect.equal True (a < b)`

## P4 — Runner state machine + retry + run.json + resume

- [x] `Plan/Runner.elm`: Event/step state machine (Started via
      `step now ev run -> (run, effects)`); NodeStatus gains `Waiting`
      (backoff before auto-retry). Effects: CreateSessionFor/SendPrompt/
      CloseSessionFor/ScheduleRetry(2000ms)/PersistRunState/Notify
- [x] Scheduler: runnable = Pending && all deps Succeeded; cap
      `concurrency - running`; marks launched nodes Starting
- [x] Event handling: SessionCreatedFor→bind+SendPrompt; TaskDone (only
      for Running nodes — idle SM task frames while Starting are ignored);
      SessionError; SessionDisconnected (Running/Starting); Stop/Pause/
      Resume/ContinueRun; RetryNode (auto tick + manual, reactivates a
      finished run)
- [x] Retry: FailureRecord{attempt, reason, at} appended; attempts<max →
      Waiting + ScheduleRetry(2000) + CloseSession; attempts>=max → Failed
      + downstream Blocked (fixpoint propagation) + run FailedRun;
      run Completed when all terminal & none failed
- [x] App/Update wiring: `runStep now ev model` + applyEffects ↔ ports;
      serialized session creation (planCreating/planCreateQueue,
      PlanBindSession binds SessionCreated to its node); frame/status
      events for node-owned sessions feed the machine (PlanRunFrame with
      Time.now via Task); SendPrompt uses the node prompt
- [x] run.json persistence: PersistRunState → fs_write_file_text
      <plan>.run.json (encodeRunState/decodeRunStateOverlay/
      applyRunStateOverlay codecs in Plan/Types); written on every step
      (throttling deferred)
- [x] Resume: PlanResume reads run.json → applyRunStateOverlay →
      R.resumeState (Starting/Running/Waiting → Pending, drop stale
      sessions) → ContinueRun relaunches unfinished nodes from scratch
- [x] Tests: `tests/PlanRunnerTest.elm` (17 cases: concurrency cap, dep
      gating, retry count + FailureRecord, stop/pause/resume/manual retry,
      disconnect/task_error, late-event ignore) + run-state codec
      roundtrip in PlanTypesTest → elm-test 114 green
- [x] UI: Run/Pause/Resume/Stop/Load-run buttons (enabled by run status),
      run status badge, node click opens its session window (ActivateSession)
      when it has one else detail panel; Retry node button; failure
      history in detail panel
- [ ] fakecore/E2E: task_error → retry → success, parallel windows, node
      click opens window — GUI env; checklist in docs/manual-acceptance.md
- [x] `elm-test` green

## P4.5 — create_session preset/builtinTools + settings.conf + seed presets

- [x] Rust `alayacore.rs` spawn() + Go `core.go` Spawn(): `builtin_tools`
      arg → `--builtin-tools=<list>` when non-empty (alongside
      --tool-confirm; empty = don't pass flag = alayacore all-on)
- [x] Rust `commands/settings.rs` + Go `handlers/settings.go`:
      GlobalSettings + `builtin_tools` field; get/sync read-write (per
      preset); normalize via existing tool-list normalizer; tests both
      sides + parity (Safe seed carries the no-execute_command list)
- [x] Rust `commands/sessions.rs` create_session: optional `preset`
      (dirs::create_session_dir_from copies that preset into
      session_dir/config, excluding settings.conf) + optional
      `builtinTools` (explicit override; default = active preset
      settings.conf; passed to spawn). Go `handlers/sessions.go` same.
      NOTE: never pass preset dir as configPath (breaks resume)
- [x] `bridge.js` + `Ports.elm`: createSession carries toolConfirm/preset/
      builtinTools; syncGlobalSettings carries builtin_tools
- [x] `Overlay/Settings.elm`: "Built-in tools" input (per-preset, like
      tool confirm) + SetBuiltinTools msg + SettingsEditor.builtinTools
- [x] Seed presets: `dirs.rs`/`dirs.go` Ensure() seeds Default/Fast/Deep/
      Data/Safe (idempotent); Safe's settings.conf sets builtin_tools
      without execute_command; create_session_dir_from for a named preset
- [x] DAG node cards: tools badge (when node overrides); preset badge
      already present; runner createSession passes node preset/tools
- [x] Tests: Rust (35: spawn chain, settings builtin_tools roundtrip,
      seed presets, create_session_dir_from) + Go (parity + integration:
      create_session with Safe preset → config copied w/o settings.conf,
      unknown preset error parity, explicit builtinTools)
- [x] `cargo test` (35) + `go test -race` (8 pkgs) + `elm-test` (114) green

## P5 — Polish

- [x] Retry badge/tooltips (node attempts badge xN, hover failure reason,
      detail-panel failure history) — already landed in P3/P4
- [x] Export JSON button (path input + fs_write_file_text) — landed in P3
- [x] Run log stream in the Plan view (node status transitions, bounded 80)
- [x] README section (Plan Mode usage + presets/tool sets + never-modify
      AlayaCore note)
- [x] docs/go-backend.md command table update (fs_write/read/delete,
      create_session preset/builtinTools, get_global_settings builtin_tools)
- [x] docs/plan-mode.md status + implementation-deviation notes synced
- [x] Concurrency selector in the Plan header (edit before run) — P14;
      empty = plan JSON concurrency
- [ ] Manual GUI acceptance (Tauri + Go browser) — GUI env; checklist in
      docs/manual-acceptance.md; E2E via fakecore covers backend, runner
      covered by 128 elm tests

## P6 — Plan Session (menu entry + --system planner prompt + [Plan] title)

User-facing flow: ⚙ menu → **New Plan Session** → describe the goal in
plain language → model emits the plan JSON → existing Create Plan flow.
No implementation details exposed to the user.

- [x] spawn()/Spawn() gain `system_prompt` → `--system=<text>` when
      non-empty (appended to alayacore's default system prompt; AlayaCore
      untouched) — Rust alayacore.rs + Go core.go
- [x] create_session gains optional `systemPrompt` (Rust+Go) + SessionConfig/
      CreateConfig fields; resume/fork pass empty
- [x] Ports.createSession carries systemPrompt; bridge.js passes it
- [x] App: `CreatePlanSession` Msg → createSession with the built-in
      `planSystemPrompt` (planner instructions: emit ONE ```json block,
      schema + quality rules, then answer normally); `planSessionPending`
      marks the next SessionCreated; `planSessionIds : Set String`
- [x] View: ⚙ menu "New Plan Session" (⧉) next to New Session; session
      window title gets a "[Plan] " prefix for plan sessions
- [x] Tests: Go integration (create_session with systemPrompt works,
      fakecore answers prompts); Rust 35 / Go 8 pkgs / Elm 114 all green
- [ ] Manual GUI smoke — GUI env; checklist in docs/manual-acceptance.md

---

## Known pitfalls

- Never edit `../alayacore` — tool set = spawn params only.
- JSON contract: snake_case returns, camelCase args, null keys must exist,
  error messages capitalized & identical across Rust/Go.
- `--builtin-tools` empty ≠ all: empty config means DON'T pass the flag
  (alayacore all-on); explicit empty string means no builtin tools (v2).
- Don't pass preset dir as `configPath` in create_session — breaks
  resume_session (needs session_dir/config); use the `preset` param instead.
- settings.conf is per-preset and NOT copied into session dirs.
- Runner sessions: keep toolConfirm="allow" so tasks don't stall on confirm
  dialogs.
- Plan JSON saved to disk must be the NORMALIZED version (schema_version=1,
  defaults filled).
- `pendingPlanOffers` is per message id; clear after Create Plan consumed.
- bufferPendingEvent pattern: runner-created sessions race with events —
  reuse existing buffering for node-owned sessions.

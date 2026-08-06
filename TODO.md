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
| P15 Automated headless-browser E2E + 4 real bugs found & fixed | [x] |
| P16 Per-plan work dir isolation + task timeouts | [x] |
| P22 Plan Session role-lock + no builtin tools + **真模型验证（用户实测完整 run 跑通）** | [x] |
| P24 Output injection `{{tX.output}}`（TaskDone 记录输出 → run.json 持久化 → 下游 prompt 替换 → 详情面板） | [x] |
| P25 Close_session cancel-first（Stop/关窗口立即取消任务，不等 drain 跑完；历史保存到取消点） | [x] |
| P26 plan JSON 顶层 `"type": "alayaface-plan"` 标志（按钮只认显式标志，普通 ```json 不误触发；**必填无兼容**——缺失/错误值直接报错） | [x] |
| R 系列 | Plan 重构：模型自主子流程 + 递归（自动创建 / 回填自动继续 / 重跑级联 / 状态条 / 超时移除）——**详见 REFACTOR.md** | 进行中 |

## P24 — 输出注入（{{tX.output}}）

用户真模型 run 实测暴露：下游任务（如 t4）需要上游 t1/t2/t3 的产出，
但 v1 prompt 自包含 → 模型只能重搜/瞎编。真模型 run 也确认了任务输出
确实落盘到 per-plan work 目录（模型用 write_file 写 `work/` 下文件），
但文件命名无固定约定 → 注入采用「最终回答文本」而非猜文件名。

- [x] `Plan/Inject.elm`（新纯模块）：`injectOutputs : Dict String String
      -> String -> String` 替换 `{{<taskId>.output}}`（精确匹配无空格；
      未知 id / 无输出 → 中文占位提示，原始模板绝不泄漏给模型；无
      `.output}}` 的 `{{` 原样保留）；
- [x] `NodeRunState.output : Maybe String`：TaskDone 成功时记录（会话
      最后一条非空 assistant 文本，Update 层 `lastAssistantOutput` 从
      `model.sessions` 提取，帧有序 AT 先于 SM task-done）；失败/重试
      不记录；StartRun 重跑清空；
- [x] runner：`TaskDone sid isError (Maybe String)` 三参事件；
      `bindSession` 生成 `SendPrompt` 时经 `outputsOf run`（Succeeded 且
      有输出）注入 —— 节点只在依赖全 Succeeded 后调度，注入时机成立；
- [x] run.json codec：`output` 字段 encode + lenient decode（缺省
      Nothing，兼容旧文件）→ resume/静默恢复后下游仍能注入；
- [x] UI：节点详情面板新增 Output 区（无记录显示占位）；
- [x] 规划器教学：`planSystemPrompt` 规则改为「下游需要上游产出时用
      {{t1.output}} 引用（仅限已声明依赖的任务）」；
- [x] 测试：`PlanInjectTest`（10 例）+ runner 6 例（成功记录/失败不记录/
      下游注入/缺失占位/未知 id 占位/重 Run 清空）+ codec roundtrip +
      lenient → **Elm 172**；
- [x] E2E：fixture t2 prompt 引用 `{{t1.output}}`；fakecore `streamReply`
      追加回显收到的 prompt（`Received prompt: ...`，成为节点最终回答）
      → e2e 断言 t2 会话含 t1 输出文本（`research the topic and
      summarize findings`）+ 注入标签 + 无原始模板；`make e2e` ALL PASS
      （含新步骤 7c：注入断言 + 关 t2 后曲线隐藏）；
- [x] 文档：docs/plan-mode.md §5 表、新增 §8.6、§10 持久化、§13 决策、
      §12 进度表。

## P25 — close_session cancel-first（Stop 能真正停掉所有节点）

用户实测反馈：**Stop 无法停止所有 Node**。排查确认：P12 的优雅关闭
语义是 EOF → alayacore `drainUntilTaskDone()` **把当前任务跑完再保存
退出**——手动关窗口想保存没问题，但 Stop 是"立刻停"，不该等任务
跑完（任务 ≤5s 宽限内能跑完就完整跑完，用户看到 Stop 后节点仍在执行）。

用户决策：**不要向后兼容，一定要发 cancel**（alayacore 原生命令，
C1 安全：`cancelTask` → `activeTask.cancel()` → 任务经 `taskResultCh`
→ `handleTaskDone` **自动保存到取消点** → 历史不丢太多）。

- [x] Go `closeGracefully`：**cancel → save → EOF → 宽限 → SIGKILL**
      （cancel 为 fire-and-forget，SendCmd 不阻塞等 CO；错误忽略）；
      `kill_child` 路径保持 EOF 宽限（无 stdin 句柄，无法发 cancel）；
- [x] Rust `close_child_gracefully_with_timeout` 对称：同一 stdin mutex
      锁内先写 cancel 帧再写 save 帧再 EOF；
- [x] fakecore 挂起模式：hang-once 不再 `sleep(30s)` 阻塞主循环——挂起
      期间继续读 stdin、吞掉 UE、响应 CI `cancel`（回 task-done 帧 +
      CO，退出挂起）——模拟真实 alayacore"任务卡住但命令循环活着"
      （alayacore cancel 走 cancelReqCh，不依赖输入管道）；
- [x] 测试：Rust 更新（断言 cancel 帧先于 save 帧到达子进程 stdin）；
      Go 新增 `TestIntegrationCloseCancelsHungTask`（挂起任务 close 后
      <3s 退出——cancel 中断挂起，而非等 30s+宽限）；Go -race 全绿；
- [x] E2E：fakecore 挂起模式 + Stop 步骤（t3 挂起 → Stop → 窗口关闭、
      badge Stopped）ALL PASS；
- [x] 文档：plan-mode.md §8.3（重写为 cancel-first）/§10/§13、README、
      manual-acceptance §5。

## P26 — plan JSON 顶层 type 标志（alayaface-plan）

用户提议：普通消息里出现 ```json 代码块也会触发 Create Plan 按钮（误报），
加一个顶层标志更保险。**后续修正（用户指示）：不向后兼容，格式不对直接
报错** —— `type` 标志必填，缺失也拒绝（不再 lenient 兼容旧文件）。

- [x] `Plan.Types.planTypeMarker = "alayaface-plan"` + `Plan.planType : Maybe String`：
      decode lenient（缺失 → Nothing）；**validate 必填**：缺失 →
      `Missing top-level "type": "alayaface-plan" marker`，值错误 →
      `Not an AlayaFace plan: ...`；`encodePlan` 总是写
      `"type": "alayaface-plan"`（保存/导出/重新生成都带标志）；
- [x] `Plan.Detect.hasPlanTypeMarker`：块内容顶层 `type` 解码 == marker；
      Update 层 AT 检测在 `extractPlanJson` 之后要求 marker == True 才插入
      `pendingPlanOffers` —— 普通 ```json 代码示例不再出按钮；
- [x] Plan Session `planSystemPrompt`：JSON 示例加 `"type": "alayaface-plan"`
      + 规则「顶层必须包含该标志，否则框架不识别」；
- [x] 测试：PlanTypesTest +3（encode 带标志 / **缺失标志拒绝** / 错误值
      拒绝）；全部既有测试 JSON 补齐标志；PlanDetectTest +5（精确标志
      true / 无标志 false / 错误值 false / 无效 JSON false / 非对象 false）
      → **Elm 180**；
- [x] E2E：fakecore fixture 带标志 → Create Plan offer 正常出现；Browse
      导入的 importedPlan 带标志 → 打开成功；**新增** legacy-no-marker.json
      （无标志）→ 管理器显示 `Missing top-level "type"...` 且不开窗口；
      ALL PASS；
- [x] 文档：plan-mode.md §5 schema/字段表（type 必填）、§6.7、§12、§13 已确认。

---

## R 系列 — Plan 重构：模型自主子流程 + 递归

> **核心文档：`REFACTOR.md`**（完整设计 + 阶段流程 + 已确认决策 D1–D15）。
> 中断恢复：读 REFACTOR.md → 本清单 → 从第一个 `[ ]` 继续。
> 每阶段完成：全量测试 → 提交 → push 三 remote（origin/gitee/org）。

### R1 基础：schema 与纯逻辑（Plan/Types + Runner）
- [x] Plan/Types.elm：删 `defaultTimeoutSeconds`/`timeoutSeconds` 字段与 validate 校验
      （decode 忽略未知字段 → 旧 plan 文件带 timeout 照常打开）；NodeStatus 新增
      `WaitingForPlan`（nodeStatusToString/FromString `"waiting_for_plan"`）；
- [x] Plan/Runner.elm：删 `Tick`/`checkTimeouts`/`timeoutNode`；TaskDone 事件加
      `delegated : Bool`（Update 层按"最后消息含 plan JSON"判定传入）；
      WaitingForPlan 迁移：TaskDone+delegated → WaitingForPlan；`ResumeDelegatedNode`
      回填继续 → Running；等待中 Stop → Canceled；等待中手动 TaskDone(非委托) →
      Succeeded；等待中 TaskDone error → 忽略保持等待；
- [x] 测试：删超时 5 例（runner）+ 3 例（schema timeout）；加 WaitingForPlan 迁移 7 例
      + codec roundtrip 1 例；Elm 180 全绿；Rust 42 / Go -race 8 包不受影响

### R2 检测与自动创建
- [x] App/Update.elm：pendingPlanOffers 改造为自动创建（检测即创建，不弹按钮）；
      解析失败错误内联到原消息（injectPlanErrorIntoSession）；
- [x] planSystemPrompt 重写（去角色锁，建议性）+ 所有 session 创建注入
      （普通会话 + 节点会话 = 递归入口）；
- [x] 删除 Plan Session：菜单入口、CreatePlanSession Msg、planSessionPending、
      planSessionIds、[Plan] 标题、Plan Session 的 builtinTools=""；
- [x] fakecore：planMode 触发改为 prompt 含 "plan" 关键词；E2E：New Session 流程 +
      自动创建断言 + t3 hang marker 预置（超时移除后第一次 run 不挂起）+ 删 t3
      超时断言；E2E ALL PASS；
- [ ] 重放跳过检测（防重复创建）→ R3 随 meta.json 绑定实现

### R3 回填 + 状态条 + 持久化
- [x] **重放跳过检测**（R2 遗留）：messageBoundToPlan（meta origin 绑定查重）；
- [x] meta.json codec（Plan/Meta.elm：origin/feedbacks/created_at）+ 自动创建写 origin；
- [x] 状态条组件（View + CSS + PlanStatusOpen）：消息下 plan 绑定（名称/状态/打开）；
- [x] 回填：feedbackCompletedPlan（Completed → 节点 output 汇总 + [Plan: xxx] →
      发 origin 会话自动继续；节点会话 → ResumeDelegatedNode；Failed/Stopped 零回填；
      写 feedbacks）；
- [x] [Plan: xxx] 链接渲染（viewTextWithPlanLinks → PlanStatusOpen）；
- [x] 重启恢复：fsHomeDir 扫描 meta.json 队列读取 → planMetas；fs_list_dir 缺失目录
      返回空（Rust+Go）；fakecore msgSeq 递增 echo id；
- [x] 测试：PlanMetaTest +3；E2E 回填/状态条断言；Elm 183 / Rust 42 / Go -race /
      E2E ALL PASS

### R4 关闭规则 + 重跑级联
- [x] closeAndClear：Succeeded 也关节点窗口（保留 lastSessionId 绑定，点击 resume 回看）；
      WaitingForPlan 不关（等子 plan）；
- [x] Plan Completed → 先回填 → 自动关 Plan 窗口（Task.perform PlanClose）；Failed/Stopped
      保留；planRunStatuses（内存缓存 run 状态，窗口关后状态条仍显示真实状态）；
- [x] 重跑（RestartRun 事件 + PlanRunRestart Msg + restartPlanCascade）：跳过 Succeeded；
      未完成节点重置（Blocked → Pending 可再调度）；WaitingForPlan 节点不重置 →
      subPlansOfPlan（meta origin 反查）级联重跑子 plan（planId 不变，无限下钻）；
      状态条 [重新执行]（Failed/Stopped/Paused 时显示）；
- [x] 顺带修复潜伏 bug：run.json 恢复的节点 nodeId=""（encode 未写 node_id）→
      allDepsSucceeded 失效 → 恢复的 run 无法调度（Load run 续跑也受影响）——
      decode 时用 dict key 补 nodeId；
- [x] fakecore：[Plan 结果] 前缀总是正常回复（回填含节点输出关键词不误判 marker 场景）；
- [x] E2E 重写：run 完成判定用状态条（plan 窗口自动关）；run.json 断言重试证据；
      节点点击 → resume（成功节点窗口已关）；8b Stop 保留（t3 挂起 → Stop → 窗口关闭）；
      ALL PASS；Elm 183 / Rust 42 / Go -race 全绿

### R5 清理 + 文档 + 真机 bug 修复
- [x] **真机 bug 修复（boot 帧门控）**：alayacore 启动即发 `SM task in_progress:false`
      （早于任何 prompt）→ `planEventFromFrame` 误判 TaskDone → 节点标 Succeeded（空
      output）→ closeAndClear 立即 CloseSessionFor（cancel-first）→ "第一条 prompt 后
      立马 Canceled"、run 毫秒完成。修复：`Model.planTaskStarted : Set String` 门控
      （仅见过 in_progress:true 的会话派发 TaskDone）；CloseSession 清理；
      fakecore 对齐帧序列（boot 带 in_progress:false + 回复前发 in_progress:true）
      使 E2E 覆盖；真机验证（LLaMA.CPP gemma-4-12B）：修复前三节点 12ms/7ms 秒完 +
      AT "Canceled"，修复后三节点真实产出、链式依赖严格顺序、无 Canceled；
- [x] E2E 全量重写（R4 完成，commit 4bc7456）：fixture t3 保留 hang-once（供 Stop）；
      E2E 开头预置 t3 hang marker（第一次 run 秒成功）；递归/回填/状态条/重跑级联步骤；
- [ ] 死代码清理（P22 残余、plan-offer-btn CSS）；Time.every 订阅删除；
- [ ] 文档：docs/plan-mode.md（§5/§6.7/§7/§8.5 超时移除/§13、§6.4 boot 帧门控）、README、
      docs/manual-acceptance.md；
- [ ] 全量验证：Elm / Rust / Go -race / make e2e 全绿 → 提交 → push 三 remote

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

## P15 — 无头浏览器 E2E 自动化 + 真实 bug 修复（不需要 GUI/真模型）

回答「一定要人来测吗」：**不需要**。单测已全自动；manual-acceptance 的
核心 GUI 流程也可全自动——用 **fakecore 当假模型**（我们自己的脚本化
alayacore 替身）+ **系统 Chrome 无头** + Go 后端，跑真实 DOM。

- [x] `e2e/plan-e2e.mjs`（node + puppeteer-core，零模型依赖）：
      ⚙ → New Plan Session → prompt → fakecore 回 fenced plan JSON →
      Create Plan offer → Plan 窗口 DAG → 并发覆盖 → Run → t1/t2/t3
      Succeeded（t2 首次失败经 marker 自动重试）→ runLog 断言重试 →
      点 t1 节点 → 会话激活且显示回复 → 截图 5 张 → 清理；`make e2e`；
- [x] fakecore 扩展（协议合规 + 场景脚本）：
      - 接受 `--system`/`--builtin-tools`（此前未知 flag 会启动失败）；
      - `--system` 非空（= Plan Session）→ 首个 UE 回完整 AT 帧带
        fenced plan JSON；
      - `streamReply` 补发 `SM task in_progress=false` 结束帧（此前
        runner 永远收不到 TaskDone —— 单测外的缺口）；
      - `fail-once` 场景：prompt 含 "fail-once" → 按 prompt 哈希的共享
        marker（tmp）首进程回 task_error、重试进程成功 —— 跨进程
        模拟「失败一次后自动重试成功」；
      - Ar/At 用不同 history_id（此前共用 "hist-1"，违反真实协议）；
- [x] **E2E 抓到的 4 个真实 bug（单测覆盖不到）**：
  1. **fs_home_dir 从未在 init 获取**：首次 Create Plan 时 homeDir="" →
     保存到 `/.alayaface/...` 500 → 修复：`Main.elm` init 加
     `Ports.fsHomeDir {}`（Tauri 同样受益）；
  2. **WriteActivePreset 固定 tmp 名**：init 播种与 create_session 的
     Ensure 并发 → rename 竞态 500 → 修复：tmp 名唯一（pid+nanos），
     Rust+Go 对称；
  3. **Elm `historyContents` 按 history_id 共享、不区分 At/Ar**：同 id
     跨 role 时 At delta 丢失 → assistant 消息为空（fakecore 共用
     "hist-1" 暴露；真实 alayacore id 唯一所以单测构造不出）→ 修复：
     key 加 tag 前缀（防御）+ fakecore 协议合规；
  4. fakecore 缺 SM task 结束帧（见上）；
- [x] 文档：README「Automated E2E」段、TODO、Makefile `make e2e`；
- [x] 测试：Elm 137 / Rust 39 / Go 8 包（-race）全绿；`make e2e` 全过
      （6 个 PASS + 5 张截图）。
- [ ] 可选：真实模型 E2E（OpenAI 兼容 API key 或本地 .gguf）—— 需要
      用户提供其一；不做也不阻塞（fakecore 已覆盖协议+UI 全链路）。

## P16 — per-plan 工作目录隔离 + 任务超时（用户确认的两项）

### 目录隔离（§8.4）
- [x] `create_session` / `resume_session` 加可选 `workDir`（Rust+Go）：
      非空 → 后端 MkdirAll + spawn 设子进程 cwd（`Command::current_dir`
      / `cmd.Dir`，纯 AlayaFace 侧、C1 安全）；fork/probe/普通会话不传
      （向后兼容）；
- [x] Elm：`planWorkDir planId model` = `plans/<planId>/work`；
      `nodeSessionArgsIn` 传 workDir；plan 节点 resume（PlanOpenNodeSession /
      PlanOpenAttemptSession）传 workDir；普通 resume 不传；Ports+bridge
      带 workDir 字段；
- [x] fakecore 启动 SM 帧上报 `cwd`（测试可断言）；
- [x] 测试：Go `TestSpawnWorkDir`（spawn cwd）+ `TestIntegrationSessionWorkDir`
      （create/resume 带 workDir → cwd 匹配；不带 → 后端 cwd）+ Rust 机制级
      `spawn_current_dir_mechanism` + E2E 断言 `plans/<planId>/work` 存在；
- [x] 文档：plan-mode §8.4/§13、go-backend 命令表、README、manual-acceptance。

### 任务超时（§8.5）
- [x] schema：`default_timeout_seconds`（计划级）+ `timeout_seconds`
      （节点级覆盖），缺省无超时；validate ≥1；`effectiveTimeoutSeconds`
      导出；codec roundtrip；
- [x] Runner：`Tick Int` 事件（app 层 `Time.every 1000ms` 单订阅喂所有
      InProgress plan）；schedule 在节点进入 Starting 时设 `startedAt`
      （超时从启动计，覆盖 create_session 挂起）；`checkTimeouts` →
      `failNode "Timeout after Ns"`（复用关闭+重试/终态路径）；
- [x] 测试：Elm runner 5 例（超时→Waiting+close+retry / 未到 no-op /
      无超时永不 / 节点覆盖默认 / 超时→重试→成功闭环）+ schema 3 例
      （decode/roundtrip/非法值）→ Elm 145；
- [x] E2E：fakecore `hang-once`（挂起 30s，marker 跨进程）→ t3 首次挂起
      → 5s 超时 → 自动重试成功（runLog 断言 t3 waiting + attempts [1]）；
      E2E 全过；
- [x] 文档：plan-mode §5 schema/§8.5/§13、TODO、README、manual-acceptance。
- [x] 测试：Elm 145 / Rust 40 / Go 8 包（-race）全绿；`make e2e` 全过。

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
      fs_list_dir, filters out *.run.json), Open / Delete (added fs_delete_file
      command Rust+Go+ports+tests); Import moved to Browse tab in P17
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

## P17 — Plans manager Browse tab (file-browser import)

Replace the raw "Path to plan JSON…" input with a real file browser,
reusing the multimodal picker machinery (file list + fuzzy matching).

- [x] `PlanManagerState`: `importPath` removed; added `filter` (Saved-tab fuzzy
      filter), `tab : PlanManagerTab (Saved|Browse)`, `browser : Maybe
      T.FilePickerState` (Browse-tab browser state)
- [x] Msgs: `PlanManagerSetImport`/`PlanManagerImport` removed; added
      `PlanManagerSetFilter`, `PlanManagerSwitchTab`, `PlanManagerBrowserInput/
      Navigate/Select/Confirm/Pick`
- [x] `Overlay.FilePicker.view` gains `title` + `placeholder` config fields
      (was hardcoded "Attach Media"); session caller passes originals
- [x] View: Plans overlay = Saved tab (list + fuzzy filter via
      `Fuzzy.fuzzyMatch`) | Browse tab (`Overlay.FilePicker.view` rooted at
      home dir, sessionId "plan"); Export row untouched
- [x] Update: browser handlers mirror the session file picker (parsePathInput /
      appendDirToInput / filterEntries / fsResolvePath / fsListDir);
      confirm/pick on a file → shared `openPlanFile` (PlanReadTarget +
      fs_read_file_text), on a dir → navigate
- [x] Routing: `FsListDirResult`/`FsResolvePathResult`/`FsHomeDirResult`
      dispatch by `planManager.tab`; `refreshPlanList` no-ops while Browse is
      active (fs_list_dir owned by the browser); tab switch re-requests
- [x] Tests: elm-test 145 green; cargo/go unchanged (frontend-only change)
- [ ] Manual GUI smoke: ⚙ → Plans → Browse → navigate/filter → click a plan
      JSON → opens Plan window (docs/manual-acceptance.md)

---

## P18 — Node-session resume: keep the on-disk dir id as the binding

Bug report: click node → open session → close session window → click node
again → "Session directory not found".

Root cause (two bugs):
1. **Rust parity**: `session::create` generated its OWN uuid, ignoring the
   caller — create_session returned an id whose dir (`sessions/<other>`)
   never existed, so the FIRST close→click resume failed on Rust. Go used
   `cfg.ID` (id == dir name).
2. **Frontend rebind**: `resume_session` hands out a FRESH id (Y) while
   keeping the ORIGINAL dir (X). The frontend rebound the node to Y → after
   closing Y, resume Y looked up `sessions/Y` (doesn't exist). run.json also
   persisted Y → broken across restarts.

Fix:
- [x] Rust `SessionConfig` gains `id`; `create()` uses it (matches Go);
      create_session/resume_session/fork_session pass id == dir name
      (resume keeps the fresh-UUID semantics: new id, old dir)
- [x] Elm: remove `planResumeNode` + `rebindNodeSession`; add
      `planResumeFrom` (in-flight resume origin) + `planResumedFrom`
      (live id → original dir id)
- [x] Node click: live sid → focus; live resumed-from-sid → focus
      (`findResumedLive`); else resume the ORIGINAL id (dir exists)
- [x] `SessionCreated` records `planResumedFrom` + preserves the
      `[Plan · planId/nodeId]` badge on resumed windows; no rebind
- [x] `CloseSession`/`DeleteSession` drop the mapping; `findPlanIdBySession`
      resolves resumed ids back to the node (disconnect → fail/retry intact)
- [x] run.json keeps the original id → works after app restart
- [x] E2E step 8: close t1 session → click t1 → reopens (no error) ×2
- [x] Tests: elm-test 145 / cargo test 40 / go test -race / make e2e ALL PASS

---

## P19 — Node ↔ session connection curve (focus → plan second layer + bezier)

When the user focuses a session that belongs to a plan node, raise the
node's plan window to the SECOND layer and draw a bezier curve from the
session window edge to the node card.

- [x] `App/NodeConnection.elm` (pure): `nodeLabelFor` (resolves resumed
      fresh ids via planResumedFrom), `parseNodeConnection` (node id may
      contain "/"), `nodeConnectionFor`
- [x] Model: `nodeConnection : Maybe NodeConnection`; `setNodeConnection`
      port (Maybe → bridge.js shows/hides)
- [x] `activateSessionModel`: focus session → session z = nextZIndex+1,
      plan z = nextZIndex (second layer), port sends the pair; non-node
      sessions clear; `ActivateSession` already-focused branch re-asserts
- [x] `SwitchSession` shares the same helper; `SessionCreated` resume
      branch sets the connection + z-pairing when the resumed session
      becomes active (node click → resume → curve immediately)
- [x] Clear sites: CloseSession / DeleteSession / PlanClose / PlanActivate
- [x] View: `data-session` / `data-plan` attributes for JS lookup
- [x] bridge.js: fixed SVG overlay on `<body>` (outside Elm vdom), rAF
      loop measuring `.session-panel` + `.plan-node` rects, bezier with
      perpendicular bow, anchor on session edge nearest the node, hides
      when the node is scrolled out of the plan window; z-index matches
      the plan window (above plan via DOM order, below session = planZ+1)
- [x] Tests: NodeConnectionTest (11) — labels, resumed resolution, slash
      node ids, unbound/unknown; elm-test 156 green
- [x] E2E: connection overlay visible + session z = plan z + 1 after
      focusing t1; curve hidden after close; curve back after both
      resumes; ALL PASS
- [ ] Manual GUI smoke: drag/resize windows while connected → curve
      follows (docs/manual-acceptance.md)

---

## P20 — runtime.conf seeding fix (alayacore key:value format, not JSON)

> Superseded in part by P21: instead of seeding a comment, presets are
> now EMPTY shells (no runtime.conf at all) and the heal REMOVES legacy
> seeds. P20's detection/verification work still applies.

Bug report: EVERY session window shows
`runtime.conf: key "{}": cannot parse value "": line without ':' separator (missing colon?)`
(plus `API key is required` when the unconfigured Placeholder model is used).

Root cause: alayacore parses runtime.conf as `key: value` lines (see
alayacore docs/configuration.md + internal/config/parser.go — comment
lines are skipped); AlayaFace seeded a JSON empty object `{}` into it,
so every spawned alayacore emitted an SM error frame on startup, which
the UI renders as an Error message in every session window.

Verified against the real binary: `{}` → 1 error frame; empty or `#`
comment → 0 error frames.

- [x] Seed `runtime.conf` with a `#` comment (empty semantics) instead
      of `{}` — Rust dirs.rs `DEFAULT_RUNTIME_CONF` + Go dirs.go
      `DefaultRuntimeConf`
- [x] Heal existing installs: `dirs::ensure` / `Ensure()` scans
      `presets/*/runtime.conf` AND `sessions/*/config/runtime.conf`
      (session config copies) and rewrites any file whose content is
      exactly `{}` (alayacore never writes `{}` itself, so this is a
      unique sentinel)
- [x] Tests: Rust `heals_broken_runtime_conf` + seed assertion (41);
      Go `TestHealsBrokenRuntimeConf` + seed assertion; full suites green
- [ ] Note: `API key is required` is alayacore's response when a prompt
      is sent with the active model's api_key empty (seeded Placeholder
      model). Expected until a real model is configured; optional UX
      improvement: fail plan runs fast with a clear message when the
      active model has no api_key (v2, not implemented)

---

## P21 — Config files: empty shells only (alayacore auto-creates)

Follow-up to P20, per the principle "empty config files shouldn't be
created at all — alayacore creates them; copying an EXISTING preset is
the only meaningful file source".

Verified against the real binary: an EMPTY config dir starts with ZERO
error frames, and alayacore auto-creates model.conf (a working local
Ollama default: `api_key: "no-key-by-default"` — no "API key is
required" noise) + runtime.conf (proper key:value, no "{}" parse error).

- [x] `create_preset_defaults` / `CreatePresetDefaults`: presets seed as
      EMPTY shells (dir only); Safe still gets AlayaFace-owned
      settings.conf (meaningful — disables execute_command)
- [x] Removed DEFAULT_MODEL_CONF (fake "Placeholder" model) and
      DEFAULT_RUNTIME_CONF seeds entirely
- [x] Heal upgraded: legacy seeds are now REMOVED, not rewritten —
      runtime.conf "{}" / P20 comment seed, and an EXACT Placeholder
      model.conf (anything the user/alayacore wrote since is kept)
      — presets AND old session config copies
- [x] Session config copies: copyDirExcluding of an existing preset is
      the file-producing path (tests updated to write a source file
      first, then assert the copy + settings.conf exclusion)
- [x] list_default_models / sync_default_models unaffected (probe-based;
      alayacore auto-creates model.conf → ModelSelector shows the
      working Ollama default instead of Placeholder)
- [x] Tests: Rust 41 / Go -race all pkgs / elm 156 / make e2e ALL PASS
- [ ] Optional follow-up: ModelSelector hint when the active model has
      no api_key (fail plan runs fast with a clear message) — v2

---

## P22 — Plan Session: role-lock prompt + no builtin tools (planner can't execute)

Bug report: the Plan Session "经常忘记自己的职责", executing the task
directly instead of emitting the plan JSON.

Root cause: alayacore sends TWO system messages — its default ("execute
the user's task with tools") FIRST, then our `--system` planner
instruction — and Plan Sessions spawned with ALL builtin tools, so the
model both heard "do the work" and physically could.

Fix (two layers):
- [x] Rewrite `planSystemPrompt` (App/Update.elm): role-locked
      ("规划器不是执行器"), explicit prohibitions (never execute, never
      use tools, only ONE ```json block), handles "直接做" requests by
      still planning, follow-ups answer plan questions only
- [x] Plan Sessions spawn with `builtinTools=""` → NO builtin tools:
      the planner physically cannot search/read/write/execute
- [x] Backend tri-state `builtin_tools` (P6-documented v2 semantics,
      now implemented): Rust `Option<&str>` (Some("") → `--builtin-tools=`,
      None → no flag) + Go `*string`; effective-setting "" still means
      "don't pass = all tools"; bridge.js preserves explicit "" (was
      `|| null`-ed to null)
- [x] fakecore echoes `builtin_tools` + `builtin_tools_set` in the boot
      frame; Go test asserts the three states; Rust spawn test asserts
      the flag for Some("")/Some(list)/None
- [x] Tests: elm 156 / Rust 42 / Go -race all pkgs / make e2e ALL PASS
      (e2e server log shows `with --builtin-tools=<none>` for the Plan
      Session, runner sessions unaffected)
- [x] Real-model validation: 用户用实际模型（Qwen+DeepSeek 组合）实测
      完整 run 跑通（t1/t2/t3 Succeeded，模型正常产出、work 目录落盘
      真实文件）；Plan Session 只吐 JSON 的行为用户实测可用；遗留：真
      模型下 Plan Session 的 JSON 输出质量未自动化（需要真实 API key，
      e2e 用 fakecore 覆盖协议层）

---

## P23 — Plan Stop closes the run's node session windows too

Question: "点击 Stop，是不是所有 session 都应该停止？" — design answer:
Stop stops every in-flight node session OWNED BY THIS plan's run (kill
the alayacore process AND close its window); it does NOT stop succeeded
nodes' sessions (keep them viewable), other plans' sessions, plain chat
sessions, or the Plan planner session.

Current state before P23: StopRun already marked nodes Canceled and
closeAndClear emitted CloseSessionFor (process kill, verified by the
existing runner test 'close:s1'), BUT the effect only sent
Ports.closeSession — the session WINDOWS stayed open as stale dead
windows, making Stop look like it didn't stop anything.

- [x] `applyEffectIn` `CloseSessionFor` now delegates to the full
      `update (CloseSession sid)` — kills the process AND removes the
      window (equivalent to the user closing it; history stays on disk
      and is restored on node click). Applies uniformly to runner-closed
      sessions (Stop / failure / cancel).
- [x] E2E step 8b: re-run (t3 hangs again after clearing the hang
      marker) → wait for t3's window → Stop → badge Stopped + t3 window
      gone; DOM clicks for Run/Stop (overlapping windows would
      intercept coordinate clicks)
- [x] Tests: elm 156 / Rust 42 / Go -race all pkgs / make e2e ALL PASS
- [ ] Manual GUI: Stop mid-run → all running node windows close, plan
      badge Stopped (docs/manual-acceptance.md)

---

## Known pitfalls

- Never edit `../alayacore` — tool set = spawn params only.
- JSON contract: snake_case returns, camelCase args, null keys must exist,
  error messages capitalized & identical across Rust/Go.
- `--builtin-tools` tri-state (P22): `null`/未指定 = preset 默认，"" 有效值
  = 不传 flag = alayacore 全开；**显式空串 = 无内置工具**（Plan Session 用
  这个让规划器无法执行）。创建会话参数 `builtinTools`: `null` | `"a,b"` |
  `""` 三种值语义不同，bridge.js 必须保真传空串（不能 `|| null`）。
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

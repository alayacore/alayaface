# TODO: Plan Mode 重构 (P39) — 会话血缘 + 级联状态机 + 画布内曲线

> 任务清单（gitignored 本地工作文件）。设计/决策见 `REFACTOR.md`。
> 中断恢复：读 `REFACTOR.md` → 读本文件 → 从第一个未勾选项继续。
> 全新会话：只读这两个文件即可接续开发；代码细节按需查阅下列模块。

## 代码审计修复（2026-08-11，独立于 P39 阶段，全绿基线之上）

> 全量回归：elm-test 348 / cargo test 69 / go test / e2e plan 23 + restart 7 全绿。

1. **后端对称漂移（Rust fork_session 缺 spawn-args 持久化）**：Go `fork_session` 写
   `session.spawn.json`（resume 时重放 capability envelope），Rust 漏了——Tauri 下 fork
   出的节点会话重启后失去 `--builtin-tools` 限制（"无工具"计划会话可能复活成全部工具）。
   已补 `dirs::write_spawn_args`（镜像 create_session + Go）+ 单测。
2. **resumed 节点会话事件路由 bug（同一类 3 处）**：runner 节点绑定的是"原会话 conversation id"，
   而 resumed 会话的帧/断连/关窗携带 **fresh live id**。`planEventFromFrame`（TaskDone/SessionError）、
   `StatusEvent` 断连注入、`CloseSession` 的 runnerFailCmd 三处原来只过 registry（或完全不解析），
   fresh id 找不到节点绑定 → 事件被丢 → 节点永远 Running（run 挂死）。新增
   `Plan.Update.resolveEventSessionId`（planResumedFrom → registry）并统一三处使用 + 单测。
3. **fork 失败残留级联状态**：`PlanCascadeForkResult {ok:false}` 原来只清 `planCascadeFork`，
   `planCascade` 仍武装——head level 还指向 live 源会话，之后该会话 TaskDone 会误触发
   `ResumeBranchFrom`（无截断重跑下游）。失败路径现在一并清 `planCascade` + open queue。
4. **`subPlansOfPlan` 哨兵值**：`Maybe.withDefault ""` 会产出 `""` 项，可能误匹配空 origin
   的 plan；改 filterMap（无绑定则跳过）+ 3 单测。

---

## 进度总览

| 阶段 | 内容 | 状态 |
|------|------|------|
| A | 曲线入 canvas + Z 有界（纯前端） | [x] 已提交（`refactor: curves into canvas + bounded z (P39-A)`）；**曲线已真机闭环**：`e2e/plan-e2e.mjs` headless Chrome 全绿（23 PASS，含曲线锚定/跟随/滚动）——修复了 rect 差值坐标 + 端口早于 patch 的 rAF 重试 |
| B | 会话血缘（身份层） | [x] **B1–B5 全部完成**：B1 血缘编解码+扫描重建（`refactor: session lineage codec + registry rebuild (P39-B1)`）；B2 绑定改 conversationId+注册表帧路由（`refactor: node bindings by conversation id (P39-B2)`）；B3 fork 交接——血缘注册+head 解析+绑定保持 conversation+嵌套血缘扫描（`refactor: fork handoff ... (P39-B3)`）；B4 删 P38 收养字段（`refactor: drop P38 parentSessionId ... (P39-B4)`）；**B5 重启一致性已闭环**——`e2e/fork-e2e.mjs`（fakecore fork 历史重放）：完整级联 fork 链路 + 刷新后血缘重建 + resume head 重放绑定，8 断言全过 |
| C | 级联状态机 | [x] **已提交**（`refactor: cascade state machine ... (P39-C)`）：`Plan/Cascade` 升级为纯状态机（Event/Effect/step + phase），gate 入机器，零顺序假设；散落逻辑（advanceCascade/cascadeAfterStep/resetDelegatedNode/adoptCascadeFork 等）删除；确认框文案更新；15 个机器单测 |
| D | 关闭语义简化 | [x] **已提交**（`refactor: ownership-graph close ... (P39-D)`）：所有权图单次遍历（collectCloseSetFromSession/Plan + closeSet 短路），消灭 `PlanClose ⇄ CloseSession` 互递归；e2e 关闭回归（8b/8d/8e）全过 |

---

## 当前状态快照（2025 起点，commit `53d2ef7`）

**已存在且保留**：
- `Plan/Runner.elm`：纯状态机（Event/Effect/step），P38 加了 `ResumeBranchFrom`（重置节点传递下游）
- `Plan/Cascade.elm`：纯助手——`impactScope`（沿 `meta.parentPlanId` 走祖先链）、
  `needsConfirm`、`buildCascadeState`、`findInsertionIndex`/`truncateMessagesAt`/`forkHistoryId`、
  `feedbackSummary`、`insertPrefix`、`transitiveSuccessors`、`bindingInRun`
- `Plan/Meta.elm`：`origin`（sessionId+planIndex）、`feedbacks`、`depth`、`name`、
  `lastStatus`、`parentPlanId`（**保留**）、`parentSessionId`+`parentSessionOf`（**P39 删除**）
- `fork_session` 后端扩展（Rust+Go 对称，可选参数：preset/builtinTools/toolConfirm/
  systemPrompt/workDir/planId/nodeId/originSessionId/clientId）——**保留**，血缘实例注册用它
- `App/Update.elm`：`PlanCascadeConfirm/Cancel`、`scopeCtx`、`planFocusAboveSession`（Ctrl+W 关闭最顶窗口）、`cascadeForkResultDecoder`
- `Plan/Update.elm`：`feedbackCompletedPlan`（含 gate/truncate/fork 分支）、`openNextOrStart`/`startCascadeNow`（祖先重开队列）、`cascadeAfterStep`、`forkRequestFor`/`forkLevelFor`/`adoptCascadeFork`（**P39 删除**）
- `chain.js`：当前是 body 级 SVG + rAF 循环（已加固）+ z 封顶 900000——**Phase A 整体重写为画布内 SVG**
- `style.css`：`.overlay` z=1000000、`.media-preview-overlay` z=1000001（保留）
- `transport.js`：`cascadeForkSession`（fork 成功先发 `onSessionCreated` 再发 `onCascadeForkResult`）——**P39 删除该处理器**

**已知问题（P39 要根治的）**：
1. 顶层会话在级联 fork 收养时被关闭；曾因漏发 `onSessionCreated` 导致 fork 窗口不出现（已修，但收养机制本身要删）
2. 曲线"点来点去"后不重绘（rAF 已加固，但 body 级方案本身脆弱）
3. 曲线/窗口 z 无上限可遮挡 overlay（已用 z 封顶 + overlay z=1000000 压住，属打补丁）
4. 关闭语义 P34/P35/P38 叠加，`PlanClose ⇄ CloseSession` 互递归，曾出现 Ctrl+W 关闭上层会话

**测试基线**：`elm-test` 324 全绿；`go test ./...` 绿；`cargo test --lib` 绿；
`node --check chain.js transport.js overlay.js` 绿。`make e2e` 需 GUI，未跑。

---

## Phase A — 曲线入 canvas + Z 有界（纯前端，独立）

> 目标：消灭 body 级 SVG、`canvasZBase()`、每帧 rAF、z 封顶；曲线随平移/缩放/滚动自动正确，永不遮挡 overlay。

- [x] **A1. Z 管理器**：`App/Windows.elm` 新增 `raiseWindow : Model -> String -> Model`
      （窗口列表序 + `nextZIndex` 超 500 全体 rebase）；替换 `nextZIndex + 1` 的所有裸增长点
      （`addPlanWindow`/`activateSessionModel`/`PlanActivate`/`SessionCreated`/`centeredSessionPos`…）
      —— 已实现：raiseWindow（列表序 + 有界 z + rebase），唯一裸增长点收敛到 raiseWindow 内；
      raiseChainWindows 也在内部 rebase
- [x] **A2. 画布内曲线层**：`chain.js` 重写
  - `.canvas` 内 `<svg class="connection-seg">`，画布坐标（窗口位置来自 Elm `chainPayload`；节点 =
    plan 窗口 + 节点在面板内 offset（offsetParent 链测量）− planScroll）
  - 新增 plan 画布 scroll 端口（`Ports.onPlanScroll` + `overlay.js` 监听回报 scrollTop/scrollLeft）
  - 重绘触发 = 离散事件（拖拽/缩放/滚动/链变化/缩放时 Elm 重发 `setConnectionChain`），**无 rAF**
  - stroke 宽度 = 3 / canvasScale（payload 携带 canvasScale）
- [x] **A3. 删除旧机制**：chain.js 的 body SVG/`canvasZBase`/`CHAIN_Z_CAP`/rAF 循环/visibilitychange
      全部删除；CSS `.node-connection-overlay`/`.plan-connection-overlay` → `.connection-seg`
      （画布内 absolute）；e2e 选择器同步更新
- [x] **A4. 验证**：`node --check chain.js/transport.js/overlay.js` 绿；`elm-test` 343 全绿；
      `go test ./...` / `cargo test --lib` 绿；**`e2e/plan-e2e.mjs` headless Chrome 全绿（23 PASS）**——
      平移/缩放/plan 画布滚动跟随、拖窗实时跟、overlay 不遮挡、按钮锚定、resume 后曲线恢复均闭环；
      已提交 `refactor: curves into canvas + bounded z (P39-A)` + 后续修复提交
      （曲线修复内容：坐标改 rect 差值（自动含滚动）、删 planScroll 端口（chain.js 自行监听滚动重绘）、
      端口早于 vdom patch 时一次性 rAF 重试；e2e 断言改 canvas 坐标 + 适配 P38 确认框）

## 曲线真机闭环（用户反馈后追加）

环境：headless Chrome（`/usr/bin/google-chrome`）+ Go 后端 + fakecore，`e2e/plan-e2e.mjs` 直接可跑（无需 GUI）。
诊断工具：`e2e/chain-diag.mjs`（复现并 dump 曲线/窗口/链状态，含缩放验证）。发现并修复的 bug：

1. **坐标算错（"没连到正确窗口"）**：原用 offsetParent 链测量窗口内点，未补偿 `.messages`/plan DAG
   的滚动 → 按钮/节点卡片 scrollIntoView 后曲线指向未滚动位置。改 `getBoundingClientRect` 差值
   （元素 rect − 窗口 rect + Elm 窗口 canvas 坐标），自动包含所有内部滚动。
2. **不显示（竞态）**：Elm 的 `setConnectionChain` 端口可先于 vdom patch 执行（新窗口面板尚未渲染）
   → 段几何失败被隐藏。加**一次性** rAF 重试（幂等、非循环）。
3. **缩放后乱（单位错位）**：rect 差值是屏幕像素（被 transform 缩放），直接加到 canvas 坐标
   （布局像素）→ 缩放越大偏得越多；且 payload.canvasScale 可能描述尚未 patch 的 transform。
   修复：差值除以**测量瞬间**的 transform scale（`getComputedStyle(.canvas)`，与 rect 同刻自洽），
   中心偏移用 offsetWidth/offsetHeight（布局单位）。
4. **删死代码**：planScroll 端口/字段/监听（chain.js 改为自行监听 DAG 滚动重绘，rect 差值已含滚动）。
5. **e2e 断言修正**：旧断言用屏幕坐标（body-SVG 时代），改为 canvas 坐标（svg left/top + path 点）；
   8b/8c/8d re-Run 需点 P38 impact-scope 确认框（既有行为，Phase C 会换机器）；7b2 新增缩放粘附回归。

当前 e2e：**ALL PASS（24 断言）**，elm-test 343，node --check，go test，cargo test --lib 全绿。

## Phase B — 会话血缘（身份层）

> 目标：conversation 稳定 id + 物理实例链；绑定永不更改；消灭 P38 收养补丁。

- [ ] **B1. session.meta.json**：新编解码（放 `Plan/Meta.elm` 或新 `Session/Meta.elm`）
      `{ conversation_id, parent_instance_id }`；现有 plan-meta 扫描扩展为也读 session.meta
      → 重建内存注册表 `instanceId → conversationId`（root 映射自身）
- [x] **B2. 绑定改 conversationId（部分完成，B3/B4 待续）**：
  - [x] `NodeRunState.sessionId` → `conversationId`（持久化 run.json 写 `conversation_id`；解码兼容旧 `session_id`）
  - [x] 帧路由：物理实例 id → 注册表（`SM.resolveConversation`）→ conversationId →
        `nodeBySessionId`（Runner 微调）；`findPlanIdBySession` 经 planResumedFrom **再**注册表；
        `planEventFromFrame`（TaskDone/SessionError）与 SessionDisconnected 注入同样解析
  - [x] `PlanBindSession` 解析 conversationId 并以 conversationId 为 planNodeSessions 标签键；
        `PlanOpenNodeSession` 读 conversation 绑定（root 会话 conversationId == 目录 id，resume 不变）
  - [ ] `meta.origin.sessionId` = conversationId 的**持久化侧**：创建时写 conversation id
        （root 下值相同，语义已成立；`parentSessionId`/`parentSessionOf` 删除随 B4）
  - [ ] 打开节点会话 = conversation → 实例链 head（最新存活）→ activate/resume
        （head 解析依赖 B3 fork 交接的链结构）
- [ ] **B3. fork 交接（机器雏形）**：确认后重跑 → 完成 → gate → `ForkInstance`（fork 当前
      head 实例，historyId = 插入点前一条）→ `InstanceReady(newId)`：写 session.meta + 注册表 →
      关旧 head 实例窗口（断连经解析不误判节点失败）→ 新实例发 `[Plan Result]` → `ResumeNode`
      —— **未开始**；与 B4 删除 P38 收养、Phase C 状态机耦合，建议一并推进
- [ ] **B4. 删除 P38 收养**：`adoptCascadeFork`/`forkRequestFor`/`forkLevelFor`/
      `rewriteParentSession`/`planCascadeFork` 字段/`PlanCascadeForkResult`/transport
      `cascadeForkSession`/fork replay 标记补丁/延迟 D11/收养关原会话/确认关子 plan —— **未开始**
- [ ] **B5. 测试 + 重启验证**：血缘编解码/重建/解析单测；重启后打开 head 实例正确；
      `elm-test`/`go test`/`cargo test --lib` 全绿；提交 `refactor: session lineage (P39-B)`

## Phase C — 级联状态机

> 目标：`Plan/Cascade.elm` 升级为纯状态机（仿 Runner），零顺序假设，可单测。

- [ ] **C1. 状态机**：`CascadeState`（rootPlanId/rootOldSummary/levels/phase）+
      `Event`（ReRunConfirmed/PlanCompleted/NodeSucceeded/LevelFailed/InstanceReady）+
      `Effect`（ForkInstance/InsertResult/ResumeNode/BranchRerun/OpenAncestor/PersistMeta）+
      `cascadeStep`；gate（summary 未变 → 静默结束）在机器内
- [ ] **C2. 接线**：App/Update + Plan/Update 只做事件分发与 Effect 执行；
      删除 `cascadeAfterStep`/`advanceCascade`/`resetDelegatedNode`/`forkLevelFor` 等散落逻辑
- [ ] **C3. 确认框**：`impactScope`/`needsConfirm`/`buildCascadeState` 保留；
      文案改为"重跑将截断父会话旧结果及其后续（含你的 N 条消息）"
- [ ] **C4. 测试**：状态机单测覆盖——各相位转换/InstanceReady 成功失败/LevelFailed 中止/
      gate 命中/多级传播顺序；`elm-test` 全绿；提交 `refactor: cascade state machine (P39-C)`

## Phase D — 关闭语义简化

> 目标：所有权图单次遍历，消灭 `PlanClose ⇄ CloseSession` 互递归。

- [ ] **D1. 所有权图**：血缘解析后 conversation → plans → 节点会话 → 子 plan；
      `CloseConversation`/`ClosePlan` 各自单次遍历（不再互相 dispatch）
- [ ] **D2. 回归**：P34/P35 场景（关会话级联关 plan、关 plan 级联关节点会话、关节点会话
      fail 节点重试）+ Ctrl+W 关闭最顶窗口（`planFocusAboveSession` 保留验证）
- [ ] **D3. e2e**：`plan-e2e.mjs` 更新/新增——级联 + fork 交接 + 曲线存在性 + 关闭回归
      （8b/8d/8e 对应）；有 GUI 时 `make e2e` 全绿；提交 `refactor: close semantics (P39-D)`

---

## 工作流提醒

- 每阶段：全测试 → commit（`refactor: ... (P39-X)`）→ push origin/gitee/org（main）。
- 设计变更先改 `REFACTOR.md`（决策表）再动手。
- 涉及后端的改动必须 Rust/Go 对称 + 各自测试。

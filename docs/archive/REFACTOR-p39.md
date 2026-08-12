# Plan Mode 重构 (P39): 会话血缘 + 级联状态机 + 画布内曲线

> **主重构文档。** 中断恢复：
> 1. 读本文件（设计 + 阶段流）→ 读 `TODO.md`（P39 任务清单）→ 从第一个未勾选项继续；
> 2. 每阶段完成 → 跑全套测试（`src-elm/elm-test` / `src-tauri/cargo test` / `src-go go test ./...` /
>    `node --check src-elm/{chain,transport,overlay}.js`）→ commit → push 三个远程
>    （origin / gitee / org，main 分支）；
> 3. 约束不变：**NEVER modify AlayaCore**；双后端对称；纯逻辑放 `Plan/*` 可单测。

---

## 0. 背景：为什么要重构

P34–P38 的补丁堆叠到了不可维护的程度，且已多次造成用户可见的故障（顶层会话消失、
关闭串门、曲线坏掉、overlay 被遮挡）。三个根因：

1. **跟后端对抗**：alayacore 的 `session.alaya` 原地追加式（C1 不能改），
   UI 想"截断历史"只能走 fork 命令，而 P38 选择 fork 到新文件——但 fork 造出新身份，P38 用一堆补丁
   （重绑 `node.sessionId`、搬 `planNodeSessions` 标签、改写 `meta.origin`、
   关原会话、replay 标记、焦点争夺）假装新身份是旧身份。结构性成本，不是实现问题。
2. **级联与截断混为一谈**：级联（A 重跑 → B 节点重答 → 下游失效重跑 → 向上传播）
   本来不依赖截断；P38 却把 fork 当级联的载体，引入整套异步交接。
3. **隐式状态机**：级联逻辑散落在 `feedbackCompletedPlan` / `runStepIn` /
   `adoptCascadeFork` / `SessionCreated` 四处，靠事件到达顺序（D11 vs fork 结果、
   SessionCreated vs 收养）隐式推进，无法单测、无法推理。

**结论（用户确认方向）**：截断 = fork 到新文件（保留模型上下文干净这一硬需求）；
但身份层重做为**会话血缘（lineage）**——conversation 稳定 id + 物理实例链，
绑定永不更改，fork 是血缘的追加操作而非身份替换。级联重做为纯状态机。

---

## 1. 约束（不可违背）

| # | 约束 |
|---|---|
| C1 | **NEVER modify AlayaCore**。`session.alaya` 原地追加式，无删除/改写命令；`fork` CI 命令（input `<historyId> <targetFile>`）是唯一能产出"截断历史文件"的通道——它把截断后的历史写到**任意目标文件**（技术上也可覆盖源会话自己的文件，即原地截断）；**本项目总是传新会话目录的文件**（见 D2），这是用法决策而非 alayacore 的能力限制 |
| C2 | 双后端对称（Rust `src-tauri` / Go `src-go`）：任何后端改动两边一致 + 各自测试 |
| C3 | 纯逻辑进 `Plan/*.elm`，纯函数 + 单测；App/Update 只做分发 |
| C4 | 前端 = Elm 0.19（无额外包依赖，elm/svg 不可用——曲线用原生 `<svg>` DOM，经 chain.js） |
| C5 | 新参数/新字段全部向后兼容（旧数据可解码，缺失给默认） |

---

## 2. 已确认决策（用户逐条批准，不要改）

| # | 决策 |
|---|---|
| D1 | **重跑 = replace 语义**：重跑成功且结果有变化时，父会话从新结果继续（截断旧的 + 插入新的） |
| D2 | **截断 = fork 到新文件**（不是 append+trim）：模型上下文干净是硬需求——旧结果及旧后续必须从模型可见历史中真正消失；历史文件有界 |
| D3 | **身份 = 会话血缘，一等公民 + 持久化**：conversation = 稳定 id（= 创建会话的 root id）+ 物理实例链（root → fork1 → fork2 …）。绑定（plan origin、节点会话）指向 conversation id，**永不更改**；物理实例 → conversation 经血缘表解析 |
| D4 | **级联 = 纯状态机**（`Plan/Cascade.elm` 升级为 Plan/Runner 同级）：Event/Effect/step，显式交接状态（WaitingFork / WaitingInstance / WaitingNode / BranchRunning），**零顺序假设** |
| D5 | **曲线画进 canvas 内部**：画布坐标 + transform 免费平移缩放；重绘只在离散事件（窗口拖拽/缩放、plan 画布滚动）；消灭 body 级 SVG、`canvasZBase()` 偏移、每帧 rAF、挡 overlay |
| D6 | **z 有界**：焦点 = 窗口列表序（DOM 末尾即最顶）+ 超阈值 rebase；消灭无上限 `nextZIndex`、z 封顶补丁 |
| D7 | **关闭 = 所有权图单次遍历**：会话 → 其创建的 plan → 其节点会话 → 子 plan；消灭 `PlanClose ⇄ CloseSession` 互相递归 |
| D8 | **保留**：`parentPlanId`（血缘查询/影响范围）、impactScope + 确认框（文案改为"旧结果将截断"）、祖先重开队列（级联需要祖先 run）、`ResumeBranchFrom`、summary gate、`Plan/Runner`、`fork_session` 后端扩展（Rust+Go，可选参数，手动 fork 与血缘实例都用它） |
| D9 | **删除 P38 收养机制**：UI 侧 `cascadeForkSession` 端口/transport 处理器、`adoptCascadeFork`、`planCascadeFork` 字段、`parentSessionId`/`parentSessionOf` 补丁、fork 的 replay 标记补丁、延迟 D11、收养时关原会话、确认时关子 plan、fork 焦点争夺——全部由血缘 + 状态机取代 |

---

## 3. 架构

### 3.1 会话血缘（身份层，Phase B）

**持久化**：每个会话目录新增 `sessions/<id>/session.meta.json`（UI 写，fs_write）：
```json
{ "conversation_id": "<root 会话 id，永不变化>",
  "parent_instance_id": "<父实例 id；root 为 null>" }
```
血缘链 = 沿 parent 指针回溯到 root。fork 时：新实例写 `{ conversation_id: 同 root, parent_instance_id: 当前 head }`。

**内存注册表**：`instanceId → conversationId`（root 映射到自身），由会话打开 / 现有 plan-meta 扫描扩展（读各 session.meta.json）重建。

**绑定语义（改动点）**：
- `meta.origin.sessionId` = conversationId（= 创建会话的 root id，**永不变化**；planIndex 不变）
- 节点绑定：`NodeRunState.sessionId` **重命名/改语义为 `conversationId`**（稳定，持久化进 run.json）；删除 `lastSessionId`/`attemptSessions` 里对物理 id 的依赖（改为 conversationId 或实例 id 均可——见 TODO B3 细节）
- 帧路由：物理实例 id → 注册表 → conversationId → `nodeBySessionId(conversationId)`（每个事件一次字典查找，O(1)）
- 打开/恢复节点会话：conversationId → 实例链 → **head（最新存活实例）** → activate / resume head

**fork 交接（状态机内，唯一允许的"状态切换"）**：
```
Fork(conversation) → 后端 fork_session(head 实例, historyId=插入点前一条) → InstanceReady(newId)
  → 注册血缘（写 session.meta.json + 内存表）
  → 关闭旧 head 实例窗口（断连经注册表解析后找不到该 conversation 的节点？——不会：
     节点绑定 conversationId，旧实例断连事件带物理 id → 解析到 conversation → 节点是
     WaitingForPlan（已由机器复位）→ 不误判失败；旧实例的窗口关闭仅清 UI）
  → 向新实例发 [Plan Result]（插入点之后）→ ResumeNode(conversationId)
```
**删除**：`parentSessionId`、`adoptCascadeFork`、`planCascadeFork`、replay 标记补丁、
fork 焦点争夺（新实例窗口 = 同一 conversation 的窗口，标题一致，无需"收养"）。

### 3.2 级联状态机（Phase C）

`Plan/Cascade.elm`（仿 Plan/Runner 的 Event/Effect/step 风格）：
```elm
type Event
    = ReRunConfirmed ImpactScope          -- 用户确认重跑
    | PlanCompleted String                -- planId（gate 在机器内判断）
    | NodeSucceeded String String         -- planId, nodeId（resumed 节点答完）
    | LevelFailed String String           -- planId, nodeId（失败/停止 → 级联中止）
    | InstanceReady String (Result String String)  -- fork 结果（新实例 id / 错误）

type Effect
    = ForkInstance ForkArgs               -- 后端 fork_session
    | InsertResult String String String   -- planId, instanceId, summary（发 [Plan Result]）
    | ResumeNode String String String     -- planId, nodeId, conversationId
    | BranchRerun String String           -- planId, nodeId（重置传递下游）
    | OpenAncestor String                 -- 重开祖先窗口（拿 run）
    | PersistMeta String                  -- 写 meta / session.meta.json

cascadeStep : Int -> Event -> CascadeState -> ( CascadeState, List Effect )

type alias CascadeState =
    { rootPlanId : String
    , rootOldSummary : String
    , levels : List CascadeLevel          -- 最近祖先在前
    , phase : CascadePhase }              -- WaitingFork | WaitingNode | BranchRunning | Done

type alias CascadeLevel =
    { planId : String, nodeId : String, conversationId : String, oldSummary : String }
```
- 异步边界全部是事件：`InstanceReady`（fork 结果）、窗口打开（OpenAncestor 的完成
  由 planReadTarget 流结束事件驱动，机器不关心，只等 PlanCompleted）。
- **gate**（summary 未变 → 整级静默跳过，级联结束）在机器内。
- 失败/停止：LevelFailed → 级联中止，状态回滚为"未开始"（无身份改动，天然无残留）。

### 3.3 画布内曲线（Phase A）

- `.canvas` 内一个 `<svg class="connection-layer">`，`position:absolute; left/top:0`，
  尺寸 = 参与窗口包围盒（链变化时重算）。
- **坐标 = 画布坐标**：窗口位置来自 `model.windowPositions`（Elm 已知）；节点坐标 =
  plan 窗口位置 + `Plan.Layout` 布局坐标 − plan 画布 `scrollTop`（DOM 状态，经
  scroll 端口回报）。
- **重绘触发（离散）**：窗口拖拽/缩放（Elm mousemove/resize 事件）、plan 画布滚动
  （scroll 端口）、链变化。**不做每帧 rAF 循环**。
- 层叠：曲线作为 canvas 子元素、按 z 排序渲染 → 无 body 层叠、无 `canvasZBase`、
  永远盖不住 overlay（overlay 在 canvas 外，z=1000000 保留）。
- stroke 宽度补偿：`stroke-width = 3 / canvasScale`。

### 3.4 Z 管理器（Phase A）

- 焦点 = 窗口列表序：`sessionOrder`/`planOrder` 里最后者最顶（DOM 顺序天然层叠）。
- 需要数值 z 的只有曲线（画布内排序）与窗口互叠时——统一走 `App/Windows.elm` 的
  `raiseWindow`：`nextZIndex` 超阈值（如 500）→ 全体 rebase（减常数）。
- 删除：`canvasZBase()`、chain.js 的 z 封顶（改为画布内排序）、`CHAIN_Z_CAP`。

### 3.5 关闭语义（Phase D）

- 所有权图（血缘解析后）：conversation → 其创建的 plans（meta.origin 匹配）→
  各 plan 的节点会话（conversationId 匹配）→ 递归。
- `CloseConversation` / `ClosePlan` 各自单次遍历，不再互相 `dispatch` 递归。
- `Ctrl+W` 关闭最顶窗口（已修复的 `planFocusAboveSession` 保留，归入本阶段验证）。

---

## 4. 模块地图（现状 → 目标）

| 文件 | 操作 | 说明 |
|---|---|---|
| `src-elm/src/Plan/Cascade.elm` | **改造** | 现为纯助手（impactScope/insertPrefix/transitiveSuccessors/findInsertionIndex/feedbackSummary…）：保留纯助手，新增 `CascadeState`/`Event`/`Effect`/`cascadeStep` 状态机 |
| `src-elm/src/Plan/Runner.elm` | 保留 + 微调 | `ResumeBranchFrom` 保留；`nodeBySessionId` 语义随 B3 改为 conversationId |
| `src-elm/src/Plan/Meta.elm` | **改** | 保留 `parentPlanId`；**删除** `parentSessionId`/`parentSessionOf`；新增 session.meta 编解码（或放新模块） |
| `src-elm/src/Plan/Update.elm` | **大改** | 删除 `adoptCascadeFork`/`forkRequestFor`/`forkLevelFor`/`rewriteParentSession`/`resetDelegatedNode`/`advanceCascade`/`cascadeAfterStep`（并入机器）；`feedbackCompletedPlan` 只做：gate → 结果插入（fork 交接由机器驱动）；`openNextOrStart`/`startCascadeNow` 保留改造 |
| `src-elm/src/App/Update.elm` | **改** | 删除 `PlanCascadeForkResult`；`PlanCascadeConfirm` 简化（不再关子 plan）；`scopeCtx` 保留；`planFocusAboveSession` 保留 |
| `src-elm/src/App/Types.elm` | **改** | 删除 `planCascadeFork`；`planCascade`/`planCascadePreview`/`planCascadeOpenQueue`/`planSuppressFeedback` 按机器需要重组（suppressFeedback 若无关闭子 plan 可删） |
| `src-elm/src/App/Windows.elm` | **改** | `raiseWindow` + rebase（D6）；`chainCtx.planOrigins` 用 `meta.origin.sessionId`（血缘后无需 parentSessionOf） |
| `src-elm/src/App/View.elm` | **改** | 确认框文案；折叠区 UI 不需要（走 fork 无 trim）；曲线相关不动（canvas 层在 chain.js） |
| `src-elm/chain.js` | **重写（Phase A）** | body SVG → canvas 内 SVG；画布坐标；离散重绘；删 rAF 循环/z 封顶/canvasZBase |
| `src-elm/transport.js` | **删** | `cascadeForkSession` 处理器（fork 结果改走通用 `onSessionCreated` + 事件到机器） |
| `src-elm/Ports.elm` | **删/改** | 删 `cascadeForkSession`/`onCascadeForkResult`；新增 plan 画布 scroll 端口（Phase A） |
| `src-elm/style.css` | **改** | `.connection-layer` 画布内样式；`.overlay` z=1000000 保留；`.media-preview-overlay` z=1000001 保留 |
| `src-tauri/.../sessions.rs` + `src-go/.../sessions.go` | **保留** | `fork_session` 扩展（可选参数）不动，血缘实例注册靠 UI 写 session.meta.json |
| `src-elm/tests/PlanCascadeTest.elm` | **扩** | 状态机 step 单测（各事件/各相位/失败/gate） |
| `e2e/plan-e2e.mjs` | 后期补 | 级联 + fork 交接 + 曲线存在性断言 |

---

## 5. 阶段流

> 每阶段独立可验证、可提交。A 与 B/C/D 正交。

- **Phase A — 曲线入 canvas + Z 有界**（纯前端，见效最快）
  1. `raiseWindow` + rebase；删 `nextZIndex` 无上限增长
  2. canvas 内 `connection-layer` SVG；画布坐标绘制；scroll 端口；离散重绘
  3. 删 chain.js body SVG 机制；验证：平移/缩放/滚动跟随、overlay 永不遮挡、拖窗实时跟
- **Phase B — 会话血缘（身份层）**
  1. `session.meta.json` 编解码 + 扫描重建注册表
  2. 节点绑定改 conversationId；帧路由经注册表；head 实例解析
  3. fork 交接（机器雏形：注册 → 关旧 → 发结果 → resume）；删 P38 收养补丁
  4. 重启一致性验证（fork 后重启 → 血缘重建 → 打开 head 正确）
- **Phase C — 级联状态机**
  1. `Plan/Cascade` 状态机（Event/Effect/step）+ 单测
  2. 接线（PlanCompleted/NodeSucceeded/InstanceReady/LevelFailed）
  3. 删除散落逻辑；确认框/impactScope 保留文案调整
- **Phase D — 关闭语义**
  1. 所有权图单次遍历；删互递归
  2. Ctrl+W/✕/级联关闭回归（e2e 8b/8d/8e 对应更新）

---

## 6. 验证与工作流

- 测试：`src-elm/elm-test`（现有 324+）、`src-go go test ./...`、`src-tauri cargo test --lib`、
  `node --check src-elm/{chain,transport,overlay}.js`、`make e2e`（有 GUI 时）。
- 每阶段：全测试 → commit → push origin/gitee/org（main）。
- 提交信息风格：`refactor: ... (P39-A/B/C/D)`。

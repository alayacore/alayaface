# Plan Mode 设计文档（AlayaFace）

> 状态：**已实现（P0–P11 完成；含多轮评审修复）**。开发进度见根目录 `TODO.md`（必须先读）。
> 本文档是 Plan Mode 功能的唯一权威设计依据；任务中断后，先读本文 + `TODO.md` 再继续。
> 实现与设计的偏差已标注（如 NodeStatus 增加 `Waiting`、会话创建串行化）。

---

## 1. 概述

为 AlayaFace 增加 **Plan Mode**：在会话中让模型把大任务拆解成 **DAG（有向无环图）**，
以 JSON 形式产出；AlayaFace 负责：

1. **生成正确的 JSON**：从模型输出中捕获计划 → 解码 → 校验（依赖存在、无环、id 唯一）→ 归一化 → **可写入文件**；
2. **可视化**：以 SVG DAG 展示给用户；**每个任务节点可点击，打开对应的会话窗口查看详情**；
3. **执行**：DAG Runner（**纯 Elm 状态机**）解析 JSON、识别可并行任务、创建/驱动对应 session；
4. **失败重试**：记录失败原因与**第几次运行失败**，自动重试至上限，支持手动重试。

---

## 2. 项目约束（红线，必须遵守）

| # | 约束 | 说明 |
|---|------|------|
| C1 | **永远不修改 AlayaCore** | AlayaCore 是独立仓库（`~/playground/alayacore`）。即使需要改，也不是在本项目里改。所有能力差异通过 **spawn 参数**（`--tool-confirm` / `--builtin-tools` / `--config-path` / `--model` 等）与 **preset 配置**（model.conf / mcp.conf / settings.conf）实现 |
| C2 | **双后端同步** | 新增命令必须在 Rust(Tauri) + Go(HTTP/WS) 同时实现，JSON 契约严格一致（返回值 snake_case、参数 camelCase、null 键不能省略、错误消息首字母大写且文案一致）。参考 `docs/go-backend.md` 与 `src-elm/src/Session/Protocol.elm` |
| C3 | **Elm 纯逻辑** | 调度/校验/布局/状态机全部为纯函数模块（`Plan/*`），可 elm-test 全覆盖；副作用只经 `Ports.elm` ↔ `bridge.js` |
| C4 | **向后兼容** | 所有新增参数可选（缺省 = 现有行为）；settings.conf 新增字段缺省 = 全开 |
| C5 | 不重复造轮子 | 会话创建/发送 prompt/事件流全部复用现有 `createSession` / `sendPrompt` / `onFrame` / `onStatus` 端口 |

---

## 3. 现状与设计依据（已核实的事实）

- **会话模型**：每个 session = 一个 `alayacore --rawio` 子进程；TLV 帧流式通信；会话窗口可拖动/缩放/点击激活。
- **任务状态**：SM 消息 `{"type":"task","data":{in_progress, current_step, max_steps, task_error, context_tokens}}` 已驱动 `taskRunning` / 步骤计数（`Session/Handlers.elm handleSystemTask`）。
- **失败信号**：SM `task_error=true`、SM `type=error`、`core-status` 断连（`connected=false`）。
- **工具来源**：
  - 内置工具（`read_file`/`edit_file`/`write_file`/`execute_command`/`search_content`）由 alayacore `--builtin-tools` flag 控制（**未指定 = 全开**、逗号列表 = 子集、显式空串 = 无内置工具）；
  - **AlayaFace 目前 spawn 不传该 flag** → 所有会话默认全开（需要新增传参，见 §9）；
  - 外部工具来自 MCP（preset 的 mcp.conf）。
- **preset 结构**（`~/.alayaface/presets/<name>/`）—— **空壳种子**：
  `model.conf`、`runtime.conf`、`themes/` **都不预创建**，由 alayacore
  首次使用时自动生成（已验证：空配置目录零报错，alayacore 自建一个可用的
  本地 Ollama 默认模型 + runtime.conf）；"拷贝已有 preset"（clone / 建会话
  复制 config）才是产生文件的有意义路径；
  - `model.conf` — 模型列表（能力来源）；缺失 = alayacore 自动建默认；
  - `mcp.conf` — MCP 服务器（外部工具来源）；有才复制；
  - `runtime.conf` — 仅 active_model/active_theme（alayacore 管理，勿当配置用）。
    **注意：alayacore 按 `key: value` 行格式解析，不是 JSON**；
  - `settings.conf` — **AlayaFace-owned，按 preset 存储**，`{"tool_confirm": "id1,id2"}`；不复制进会话目录；`get_global_settings(preset)` / `sync_global_settings(config, preset)` 已支持按 preset 读写；仅 Safe 种子携带；
  - `themes/` — alayacore 缺失时自动创建默认主题。
  - **遗留种子自愈**：`dirs::ensure` 启动时删除仍持有旧空种子的文件
    （runtime.conf 的 `{}` / 注释、Placeholder model.conf），presets 与旧
    会话 config 拷贝都扫——alayacore 会重建，删除无损；内容与种子不同的
    真实文件（用户配的模型、alayacore 写的 active_model）绝不动；
- **create_session 命令**：已支持 `configPath`（非空 = 直接用指定目录当会话配置）；`toolConfirm` 缺省 = active preset settings.conf 的 tool_confirm；**新建会话目录时把 active preset 复制进 `session_dir/config`**（`dirs::create_session_dir`，排除 settings.conf）。
- **resume_session 依赖 `session_dir/config`** → 若直接传 preset 路径当 configPath 会破坏 resume；必须走「按 preset 名复制模板」的路径。
- **alayacore 工具集不可在 UI 侧扩展** → 计划 JSON 只能经「fenced ```json 输出」或「write_file 写文件」捕获。
- `TODO.md` / `REFACTOR.md` 原被 .gitignore 忽略 → 已取消 `TODO.md` 忽略，纳入版本控制（中断恢复依赖它）。

---

## 4. 总体架构与数据流

```
[Planner Session] 模型生成 DAG JSON        ← 推荐入口：⚙ 菜单 → New Plan Session
        │  (a) AT 消息里输出 ```json 代码块（主路径）   （普通会话也可，需用户自述格式）
        │  (b) write_file 写入 ~/.alayaface/plans/*.json（Plans 管理器列出）
        ▼
Plan.Detect 提取 → 助手消息下方出现 "Create Plan" 按钮
        ▼
Plan.Types.decode + normalize + validate（id 唯一/依赖存在/无环）
        ▼
保存到 ~/.alayaface/plans/<planId>.json     ← 需求：JSON 可写文件
        ▼
打开 Plan 窗口（SVG DAG；节点可点击）
        ▼
用户点 Run ──► Plan.Runner（纯 Elm 状态机）
        │   ├─ Effect: createSession {preset?, builtinTools?, toolConfirm="allow"}
        │   ├─ Effect: sendPrompt（节点 prompt）
        │   ├─ 事件: SM task / SM error / core-status → step()
        │   ├─ 失败 → FailureRecord{attempt, reason, at} → 自动重试 ≤ maxAttempts
        │   └─ 运行状态实时写回 <planId>.run.json
        ▼
节点成功 → 解锁下游 → 并行调度（≤ concurrency 上限）
```

### Plan Session（P6 + P22）

用户不需要知道任何实现细节（schema / fenced JSON / preset）：

1. ⚙ 菜单 → **New Plan Session** → 创建普通会话，但 spawn 时通过
   `--system` 注入内置的**规划器指令**（`planSystemPrompt`，App/Update.elm
   常量：角色锁死"规划器不是执行器" + 禁止工具/执行 + 一次性输出 ```json
   计划块 + schema + 质量规则 + 后续只答计划追问）；
2. **同时以 `builtinTools=""` spawn（显式空串 = alayacore 无内置工具）**
   ——规划器**物理上无法执行任务**（搜不了/写不了/跑不了），只能输出计划；
   runner 节点会话不受影响（不传 flag = 全开）；
3. 用户只用自然语言描述目标；
4. 模型输出计划块 → 现有 Create Plan 流程接管（检测/校验/保存/Run 零改动）；
5. 会话窗口标题带 `[Plan]` 前缀（`planSessionIds : Set String`）。

链路：`create_session {systemPrompt, builtinTools:""}` → `spawn --system=<text>
--builtin-tools=`（alayacore 默认 system prompt 之后追加；显式空 flag = 无
工具）。resume/fork 会话不传。

> **P22 背景**：模型"忘记职责直接干活"的根因 = 默认 system prompt 在前
> （"执行任务"），我们的规划指令在后 + 工具全开。修复：提示词角色锁死 +
> 工具禁用双保险。后端 `builtin_tools` 参数现支持三态：`null`（preset 默认/
> 全开）、`"a,b"`（子集）、`""`（**无工具**，P6 遗留的 v2 语义落地）。

---

## 5. DAG JSON Schema（v1）

```json
{
  "type": "alayaface-plan",
  "schema_version": 1,
  "name": "月度销售报告",
  "goal": "生成6月销售分析报告",
  "concurrency": 2,
  "default_max_attempts": 3,
  "tasks": [
    {
      "id": "t1",
      "title": "收集数据",
      "prompt": "从 sales.db 收集6月销售数据，整理后写入 data/raw.json",
      "depends_on": [],
      "preset": "Data",
      "tools": "read_file,write_file,search_content",
      "max_attempts": 2
    },
    {
      "id": "t2",
      "title": "数据分析",
      "prompt": "读取 data/raw.json，做同比环比分析，结论写入 data/analysis.md",
      "depends_on": ["t1"]
    },
    {
      "id": "t3",
      "title": "撰写报告",
      "prompt": "基于 data/analysis.md 撰写最终报告 report.md",
      "depends_on": ["t2"]
    }
  ]
}
```

### 字段说明

| 字段 | 必填 | 说明 |
|------|------|------|
| `type` | 是 | 顶层标识 `"alayaface-plan"`（P26，**必填**，无向后兼容）：缺失 → 校验错误 `Missing top-level "type": ...`；值错误 → `Not an AlayaFace plan: ...`；保存/导出总是写入 |
| `schema_version` | 是 | 固定 1 |
| `name` | 是 | 计划名（用于文件命名 slug） |
| `goal` | 否 | 总体目标，DAG 视图头部展示 |
| `concurrency` | 否 | 并行上限，默认 2（范围 1–8） |
| `default_max_attempts` | 否 | 节点默认重试上限，默认 3 |
| `default_timeout_seconds` | 否 | 节点默认超时（秒）；缺省 = 无超时（v1 行为）；节点可经 `timeout_seconds` 覆盖 |
| `tasks[].id` | 是 | 全局唯一、非空 |
| `tasks[].title` | 是 | 节点标题 |
| `tasks[].prompt` | 是 | 发给该节点会话的完整 prompt；可用 `{{<taskId>.output}}` 引用上游任务输出（P24：运行时替换为该任务完成时的最终回答；只能引用 `depends_on` 已声明的任务） |
| `tasks[].depends_on` | 否 | 依赖 id 列表，默认 `[]`；引用必须存在、不允许自依赖、整体无环 |
| `tasks[].preset` | 否 | 运行该节点的 preset 名；缺省 = active preset |
| `tasks[].tools` | 否 | 节点级内置工具集覆盖（逗号列表）；缺省 = preset settings.conf 的 builtin_tools（再缺省 = 全开） |
| `tasks[].max_attempts` | 否 | 节点级重试上限；缺省 = default_max_attempts |
| `tasks[].timeout_seconds` | 否 | 节点级超时（秒）；缺省 = default_timeout_seconds（再缺省 = 无超时） |

### 校验规则（纯 Elm，decode 后归一化）

- id 唯一非空；title/prompt 非空；
- depends_on 引用存在、无自依赖；**Kahn 拓扑排序检测环**；
- timeout 值（default_timeout_seconds / timeout_seconds）若给出必须 ≥ 1；
- 归一化：补默认值、`schema_version` 固定为 1、输出**归一化后的 JSON**（保存到文件的就是它）；
- 校验失败 → DAG 视图顶部列出可读错误（如 `t2 依赖不存在的节点 x`、`检测到循环依赖: t1→t2→t1`）。

---

## 6. Elm 模块设计（全部纯逻辑，可单测）

```
src/Plan/
├── Types.elm    — Plan / TaskNode / NodeStatus / RunState / FailureRecord + JSON codec + validate/normalize
├── Layout.elm   — DAG → 分层（Kahn 最长路径）→ 每层坐标 (x,y) 供 SVG 渲染
├── Runner.elm   — 执行状态机：step : Event -> RunState -> (RunState, List Effect)
├── View.elm     — SVG DAG 画布 + 节点详情面板 + Plans 管理器 overlay
└── Detect.elm   — 从助手消息文本提取 ```json 代码块
```

### 6.1 节点状态机

```
Pending → Starting → Running → Succeeded
              ↓          ↓
           (会话创建失败) Failed（attempts < maxAttempts → Waiting 自动重试 → Pending；否则 Failed 终态）
Blocked   ← 任一依赖 Failed 终态（继承显示"被 xx 阻塞"）
Canceled  ← 用户 Stop / Pause 时未完成的节点
```

> 实现偏差：自动重试退避期间引入 `Waiting` 状态（已加入 NodeStatus），
> `ScheduleRetry`（默认 2000ms）结束后 `RetryNode` 事件把节点送回 `Pending`。
> `TaskDone`/`SessionError` 只对 `Running` 节点生效（Starting 期间的空闲
> SM task 帧会被忽略，避免误判任务完成）。

### 6.2 运行时数据结构

```elm
type alias NodeRunState =
    { nodeId : String
    , status : NodeStatus
    , attempts : Int                    -- 已尝试次数（第几次运行）
    , maxAttempts : Int
    , sessionId : Maybe String          -- 关联的会话窗口
    , failures : List FailureRecord     -- 按时间倒序，累计保留
    , startedAt : Maybe Int
    , finishedAt : Maybe Int
    }

type alias FailureRecord =
    { attempt : Int      -- 第几次运行失败（1-based）
    , reason : String    -- 失败原因（SM error 文本 / task_error / 断连原因）
    , at : Int           -- 时间戳（ms）
    }

type Effect
    = CreateSessionFor String            -- 节点 id（携带节点 preset/tools/toolConfirm）
    | SendPrompt String String           -- sessionId, promptText（runner 绑定会话时从 plan 解析，随 effect 携带）
    | CloseSessionFor String String      -- sessionId, nodeId
    | ScheduleRetry String Int           -- nodeId, delayMs（默认退避 2000ms）
    | PersistRunState                    -- 写 <planId>.run.json
    | Notify String
```

### 6.3 调度规则

- `runnable` = `status == Pending && 所有依赖都 Succeeded`；
- 每步最多启动 `concurrency - 当前 Running 数` 个 → **天然实现并行任务识别**；
- 节点成功 → 重新计算 runnable → 启动下游。

### 6.4 事件（喂给 step()）

- `SessionCreatedFor nodeId sessionId` → 绑定会话 → `SendPrompt`
- `TaskDone sessionId result`（SM task `in_progress:false`；`task_error` 判定成败）
- `SessionError sessionId text`（SM error）
- `SessionDisconnected sessionId reason`（core-status connected=false；未收到 done 前视为失败）
- 人工事件：`Stop` / `Pause` / `Resume` / `RetryNode nodeId`（手动重试，attempts 清零重来）

**boot 帧门控（R5 真机修复）**：alayacore 会话启动时先发一条
`SM task in_progress:false`（context 0，早于任何 prompt）——没有门控时它
与真实 TaskDone 无法区分，Runner 会把刚绑定的节点标为 Succeeded（output
空）→ `closeAndClear` 立刻 `CloseSessionFor`（cancel-first 关闭）→ 节点
"第一条 prompt 后立马 Canceled"、run 毫秒级"完成"（真机必现；fakecore 旧
boot 帧无 in_progress 字段 → 前端默认 true → E2E 永不触发）。门控：
`Model.planTaskStarted : Set String` 只对**见过 `in_progress:true`** 的
会话派发 TaskDone（真实任务必先发 true）；boot 帧被忽略。fakecore 已对齐
帧序列（boot 带 `in_progress:false` + 回复前发 `in_progress:true`），E2E
实际覆盖该路径。

### 6.5 失败与重试（需求③）

- 失败 → 追加 `FailureRecord{attempt, reason, at}`，`attempts += 1`；
- `attempts < maxAttempts` → `CloseSessionFor` 关旧会话 → 回到 `Pending` → `ScheduleRetry`（默认退避 2s）→ 重新创建会话（**新进程，干净重跑**）；
- `attempts >= maxAttempts` → `Failed` 终态 → 直接/间接下游 → `Blocked`；
- 运行中节点可手动 Retry（节点详情面板按钮）；
- 节点卡片显示重试角标（如 `x2`）；失败原因悬停可见；详情面板列出全部失败历史（第几次/原因/时间）。

### 6.6 布局（Plan/Layout.elm）

- Kahn 最长路径分层 → 层 = 列，同层纵向堆叠 → 每节点 `(x,y)`；
- 边用 SVG 三次贝塞尔曲线；
- 纯函数，测试样例：菱形图 / 链式图 / 独立并联图。

### 6.7 捕获（Plan/Detect.elm）

- `extractPlanJson : String -> Maybe String`：提取第一个 ```json … ``` 块（还原转义、去围栏）；
- `hasPlanTypeMarker : String -> Bool`：块内容顶层 `"type"` 是否 == `"alayaface-plan"`（P26）；
- 在 AT 帧完成时对最新助手消息调用：**先 extractPlanJson，再要求
  hasPlanTypeMarker == True** 才命中（普通 ```json 代码示例——无标志——
  不再触发按钮）→ `Model.pendingPlanOffers` 记 `messageId → rawJson` →
  消息下方渲染 **Create Plan** 按钮；
- 点击 → decode/validate（`type` **必填**：缺失或值错误都拒绝，无向后
  兼容）→ 归一化 → 生成 planId → `fs_write_file_text` 写
  `~/.alayaface/plans/<planId>.json` → 打开 Plan 窗口。

---

## 7. UI 设计

### 7.1 Plan 窗口（独立窗口，类似会话窗口）
- 每个打开的 plan 是一个**独立可拖动/缩放的窗口**（复用会话窗口的
  panel/拖拽/缩放/z-order 机制），不是 overlay；可同时打开多个 plan；
- 窗口标题栏：`Plan — <名称>` + 关闭按钮；窗口内：计划名 + goal + 运行
  状态徽章 + **Run / Pause / Stop / Retry** + **Load run** + **Export JSON**；
- **系统菜单（⚙）列出所有打开的 plan 窗口**（名称 + 运行状态），点击即
  置顶激活；Plans 管理器（overlay）用于浏览/打开/删除/导入
  `~/.alayaface/plans/*.json`；
- 画布：HTML/CSS DAG；节点圆角矩形卡片，颜色区分状态（灰=待执行、蓝=运行、
  绿=成功、红=失败、橙=重试中、虚=阻塞/取消）；
- 节点卡片：`title`、状态图标、重试角标 `xN`、preset 徽标、失败悬停显示最近原因；
- **点击节点（节点 ↔ 会话绑定）**：
  - 节点有 sessionId（成功节点保留绑定；run.json 持久化 `session_id`）：
    - 会话窗口仍存活 → `ActivateSession` 置顶聚焦；
    - 会话已关闭/重启后 → **自动 `resume_session` 从磁盘恢复该会话**（历史
      完整回来，标题显示 `[Plan · planId/nodeId]` 绑定标记），恢复失败在
      plan 窗口顶部报错；
  - 节点无 sessionId 但有 `lastSessionId`（Failed/Blocked/Canceled：
    会话曾被 runner 关闭）→ **同样自动 `resume_session` 恢复**——失败/停止
    节点的会话不再丢失，历史可随时回看；
  - 两者都无 → 右侧节点详情面板（prompt 全文、依赖、失败历史、Retry）；
  - **resume 的 id 语义（P18 修复）**：`resume_session` 每次发**新 UUID**
    但**沿用原 on-disk 目录**；节点**始终绑定原始 id（目录名）**，
    `planResumedFrom`（live id → 原 id）记录本次运行内的映射：
    - 会话存活时点击节点 → `findResumedLive` 找到 live 窗口直接聚焦；
    - 关闭窗口后再点击 → 重新 `resume_session` 原始 id（目录仍在磁盘），
      可反复开关，不会出现 "Session directory not found"；
    - run.json 持久化的始终是原始 id → 应用重启后同样可恢复；
    - `CloseSession` / `findPlanIdBySession` 通过 `planResumedFrom` 把
      关闭的 live 窗口归属回对应 plan 节点（断连 → 节点失败重试不变）；
- **打开 plan 窗口自动恢复绑定**：打开/导入 plan 文件时静默读取
  `<plan>.run.json`（best-effort），恢复各节点状态与 sessionId —— 之后
  点击任意已运行节点即可重新打开其会话；**Load run** 则在恢复后继续执行
  未完成任务；
- **节点 ↔ 会话连接曲线（P19）**：聚焦某个属于 plan 节点的会话时——
  - 该 plan 窗口自动提到**第二层**（session z = plan z + 1）；
  - bridge.js 在 `<body>` 上绘制一条**贝塞尔曲线**（rAF 每帧量 DOM
    `getBoundingClientRect`，拖动/缩放/滚动自动跟随），从会话窗口最靠近
    节点的那条边中点连到节点卡片中心，z-index 取 plan 窗口值（同值 +
    后插入 body → 在 plan 之上、session 之下）；
  - 纯逻辑在 `App/NodeConnection.elm`（`planNodeSessions` 标签 + P18 的
    `planResumedFrom` 解析 resume 出的 live id；node id 可含 `/`）；
  - 消失时机：聚焦非节点会话 / plan 窗口、关闭或删除该会话或 plan 窗口；
    节点被滚出画布可视区时 JS 自动隐藏；
- 底部：运行日志流（每节点启动/成功/失败/重试事件）；
- **Stop 语义（P23）**：点击 Stop = 停止**本 plan 运行拥有的全部进行中节点
  会话**——runner 把运行中/启动中的节点标 Canceled，`closeAndClear` 对每个
  有绑定会话的节点发 `CloseSessionFor` → **同时杀掉 alayacore 进程并关闭
  对应会话窗口**（历史留在磁盘，点节点可恢复）。**不停止**：已成功节点的
  会话（保留可查看）、其他 plan 的会话、普通会话、Plan 规划会话；
- 关闭 plan 窗口不会停止正在运行的节点会话（run.json 持续落盘，可 Load run
  恢复）；手动关闭某节点会话窗口会向 runner 注入断连事件 → 该节点按失败重试。

### 7.2 Plans 管理器（overlay，仿 Session Manager）
- 两个 tab：
  - **Saved**：列出 `~/.alayaface/plans/*.json`（过滤 `*.run.json`），带模糊
    过滤输入框（`Fuzzy.fuzzyMatch`）；操作：Open（渲染 DAG）、Delete；
  - **Browse**：文件浏览器，**复用多模态文件选择器**（`Overlay.FilePicker.view`
    + `Session.FilePicker` 纯逻辑 + `Fuzzy.elm`）：目录导航（fs_resolve_path /
    fs_list_dir）、模糊匹配过滤、点击目录进入、点击/回车 plan JSON 导入
    （走 `PlanReadTarget` + fs_read_file_text 流程，任意位置均可）；
- 入口：全局菜单新增 **Plans** 项（现有 `showGlobalMenu` 体系）。

### 7.3 Runner 会话
- 即普通会话窗口（可点击查看），标题加 `[Plan]` 前缀标识；
- 创建参数：`toolConfirm="allow"`（自动放行工具，避免卡确认弹窗）、`preset`、`builtinTools`（节点级覆盖）。

---

## 8. 后端与端口改动清单（最小化，双后端同步）

### 8.1 文件读写命令（P1）

| 新增命令 | Rust | Go | bridge.js | Ports.elm |
|---|---|---|---|---|
| `fs_write_file_text {path, content, createParents}` | `commands/fs.rs` | `handlers/fs.go` | 新 port | `fsWriteFileText` + `onFsWriteResult` |
| `fs_read_file_text {path}` | `commands/fs.rs` | `handlers/fs.go` | 新 port | `fsReadFileText` + `onFsReadResult` |

- 错误消息：`Cannot write file: ...` / `Cannot read file: ...`（对齐现有风格）；
- `createParents=true` 自动建父目录（首次保存 plans 目录）；
- 路径策略沿用现有 fs 命令（不限制绝对路径；导出经 FilePicker）；
- Tauri capabilities 无需改动（自定义 command 不走权限系统）；
- 注册进 `generate_handler!` / RPC dispatcher；`docs/go-backend.md` 命令映射表同步。

### 8.2 内置工具集 = 第二个 tool_confirm（对称设计，约束 C1/C4）

| 层 | 改动 |
|---|---|
| `src-tauri/src/alayacore.rs` `spawn()` | 增加 `builtin_tools: &str` 参数；非空时追加 `--builtin-tools=<list>`（与 `--tool-confirm` 并列；**空 = 不传 = alayacore 默认全开**） |
| `src-go/internal/core/core.go` `Spawn` | 同上 |
| `commands/settings.rs` + `handlers/settings.go` | `GlobalSettings` 加 `builtin_tools` 字段；get/sync 支持读写；归一化复用 `normalize_tool_confirm`（trim/去重/拒空格） |
| `commands/sessions.rs` + `handlers/sessions.go` | `create_session` 加可选 `builtinTools` 参数（显式覆盖；缺省 = active preset settings.conf 的 builtin_tools）—— 与现有 `toolConfirm` 逻辑完全对称 |
| `commands/sessions.rs` + `handlers/sessions.go` | `create_session` 加可选 `preset` 参数：内部把**指定 preset** 复制进 `session_dir/config`（复用 `dirs::copy_dir_excluding`，排除 settings.conf），缺省 = active preset（现有行为）。**不能直接传 preset 路径当 configPath**（会破坏 resume_session） |
| `bridge.js` + `Ports.elm` | `createSession` port 带 `toolConfirm` / `preset` / `builtinTools` 字段 |
| `Overlay/Settings.elm` | 加 "Built-in tools" 输入框（与 Tool confirm 并列），可逐 preset 配置 |
| 测试 | Rust 单测 + Go 单测 + 错误消息 parity 断言 |

**flag 语义注意**：alayacore `--builtin-tools` 未指定 = 全开；显式空串 = 无内置工具（MCP-only）。v1 只支持两态：**空 = 全开、非空列表 = 子集**；MCP-only 属边角场景，需要时用 `"none"` 特殊值再议。

### 8.3 优雅关闭（close_session，P12 演进 → P25 cancel-first）

**问题**：原 `close_session` 直接 SIGKILL 子进程。alayacore 只在
`handleTaskDone`（任务结束）和 `:save` 命令时把完整会话写入
`session.alaya`，且 rawio 适配器**没有** SIGINT 处理器——因此关闭窗口 =
丢弃进行中那一轮对话（app 被杀同理）。C1 不允许改 alayacore，只能在
**我们发送什么 / 等多久**上做文章（只读核实过 alayacore 的退出路径）。

**alayacore 已核实事实**：
- `save` CI 命令空参数 = 保存到 `--session` 文件（`session.alaya`）；
- `cancel` CI 命令 = 取消当前任务（`activeTask.cancel()` 经 per-task
  context）→ 任务走 `taskResultCh` → `handleTaskDone` **自动保存**到取消
  点；无任务时返回 `NOTHING_TO_CANCEL`；
- stdin EOF + 有活动任务 → `drainUntilTaskDone()`：把任务跑完（
  `handleTaskDone` 自动保存）再退出；EOF + 无活动任务 → 直接退出（不保存）；
- rawio 无 SIGINT 处理（plainio/terseio 才有），EOF 是唯一优雅退出信号。

**AlayaFace 侧实现（双后端对称，P25：cancel-first，不做向后兼容）**：

```
close_session:
  1. 发 CI "cancel"（best-effort，fire-and-forget：取消当前任务 →
     alayacore 保存到取消点；无任务/子进程已死则错误忽略）
  2. 发 CI "save"（best-effort，落盘兜底）
  3. 关闭 stdin → EOF（任务已被取消 → 立即退出，不再 drain 跑完）
  4. 等 ≤ 5s 自然退出（GRACEFUL_CLOSE_TIMEOUT）
  5. 仍活着 → SIGKILL 兜底
```

- **为什么 cancel-first**：Stop / 关闭会话窗口的语义是"立刻停"，不是
  "等任务跑完"。P12 的 drain 语义（EOF 后跑完当前任务）会让 Stop 后
  Running 节点继续执行最多到任务结束（用户实测：Stop 无法停掉所有
  节点）。cancel 命令由 alayacore 原生支持（C1 安全）：任务被取消 →
  `handleTaskDone` 自动保存 → 历史保留到取消点（比 SIGKILL 丢得少，
  比 drain 等得短）。所有 close_session 一律 cancel-first，不设兼容
  参数（用户明确要求"不要向后兼容"）；
- `kill_child` / `KillChild`（Drop / 断连路径）保持**先 EOF 宽限 3s
  再杀**：该路径只有子进程句柄（无 stdin 管道），无法发 CI cancel；
  stdout 断连时子进程通常已退出，立即返回；
- Rust 侧 `SessionHandle.stdin` 改为 `Arc<tokio::sync::Mutex<Option<ChildStdin>>>`：
  优雅关闭时把槽位置 `None` 即关闭管道（不依赖 Arc 引用计数），写方（
  send_prompt / send_raw）对 `None` 返回 "Session is disconnected"；
  同步上下文用 `try_lock`（spawn_blocking / Drop）；
- Go 侧 `closeGracefully` **不自己调 `cmd.Wait()`**——收割统一由 reader
  断连路径的 `killOnce → KillChild` 负责（`os/exec` 禁止并发 Wait，
  race 检测器实测告警），只轮询 `Connected()` 等到 stdout EOF（= 子进程
  自然退出）或超时后 `kill()`；
- fakecore 挂起模式：hang-once 不再 `sleep` 阻塞主循环——挂起期间仍
  读 stdin、吞掉 UE、响应 CI `cancel`（回 task-done 帧 + CO），模拟
  alayacore"任务卡住但命令循环活着"（真实 alayacore 的 cancel 走
  cancelReqCh，不依赖输入管道）；
- 测试：Rust（cancel 帧先于 save 帧到达子进程 stdin / 倔强子进程超时
  被杀 / kill_child 宽限 / 已死子进程不 panic）；Go 集成（fakecore
  `save` 写 session.alaya 标记 → close 后文件含 saved 标记；新增
  `TestIntegrationCloseCancelsHungTask`：挂起任务 close 后 <3s 退出，
  证明 cancel 中断挂起而非等宽限 SIGKILL）；E2E（Stop 后 t3 挂起会话
  立即关闭）。

**已知限制**：cancel 后若任务取消本身卡住（极端），仍由 5s 宽限 +
SIGKILL 兜底——但 `save` 帧已先行落盘，至少保留任务开始前的全部内容；
「杀不死的断点续跑」仍是 v2（resume 子进程）。

### 8.4 目录隔离（per-plan 工作目录，P16）

**问题**：所有 alayacore 子进程 cwd = 后端进程启动目录（共享）。并行
节点写文件互相踩、plan 之间互相污染、后端 cwd 被写乱。

**方案**：**per-plan 工作目录** `~/.alayaface/plans/<planId>/work/`——
一个 plan 的所有节点会话共享该目录（文件传递模式照常工作：t1 写文件
t4 能读），plan 之间互不可见，且不再污染后端 cwd。普通会话 / fork /
probe 不传（保持后端 cwd，向后兼容）。

- `create_session` / `resume_session` 加可选 `workDir`：非空 → 后端
  `MkdirAll` + spawn 设子进程 cwd（Rust `Command::current_dir` /
  Go `cmd.Dir`——**纯 AlayaFace 侧改动，C1 安全**，alayacore 无感知）；
- Plan Mode 节点会话由 Elm 侧派生 `planWorkDir planId model` 传入
  （homeDir 已知时），创建与 resume 都带；
- 测试：Go 集成（create/resume 带 workDir → fakecore 启动帧上报
  `cwd` 断言匹配；不带 → 后端 cwd）+ Rust 机制级（current_dir 生效）+
  E2E（Run 后断言 `plans/<planId>/work` 存在）。

### 8.5 任务超时（P16）

**问题**：Runner 事件驱动、无心跳——真实模型 API 挂起 / 工具卡死 /
MCP 卡住时节点永远 Running、run 永远挂起。

**方案**：`default_timeout_seconds`（计划级）+ `timeout_seconds`（节点级，
覆盖），缺省无超时（v1 兼容）。app 订阅 `Time.every 1000ms` →
`PlanTick` → 对每个 InProgress 的 plan 窗口喂 `Tick now` → runner 检查
`Starting/Running` 节点：`now - startedAt >= timeout*1000` → `failNode
"Timeout after Ns"`（复用失败路径：关会话 + 自动重试 / 耗尽 → Failed +
下游 Blocked）。计时从节点进入 Starting（schedule 设 startedAt）——
**覆盖 create_session 挂起**（迟到返回的会话被孤儿清理关闭）。

- 单 tick 服务所有并行 plan（无 run 时 no-op）；
- 测试：Elm runner 5 例（超时→Waiting+close+retry effects / 未到超时
  no-op / 无超时永不 / 节点覆盖计划默认 / 超时→重试→成功闭环）+ schema
  3 例（decode/roundtrip/非法值）+ E2E（fakecore `hang-once` 挂起 →
  5s 超时 → 自动重试成功，runLog 断言 t3 waiting）。

### 8.6 输出注入（`{{tX.output}}`，P24）

**问题**：下游任务常需要上游任务的产出（如"基于 t1 的调研结果写报告"）。
v1 prompt 自包含 → 下游模型只能重搜或瞎编（真模型 run 实测：t4 需要
t1/t2/t3 结果但拿不到）。

**方案**：`tasks[].prompt` 支持模板 `{{<taskId>.output}}`，运行时替换为
该任务**完成时的最终回答**（会话最后一条非空 assistant 文本）：

- **记录**：TaskDone（SM task 结束帧）时，Update 层从该会话消息历史
  提取最后一条 assistant 文本（帧有序：AT 先于 SM task-done 到达）→
  `R.TaskDone sid isError output` 携带 → runner 在成功时写入
  `NodeRunState.output`；失败/重试不记录；
- **注入时机**：节点只在所有依赖 Succeeded 后才调度（Starting），
  bindSession 生成 `SendPrompt` 时解析模板 —— 上游输出必然已存在；
  模板替换是纯函数 `Plan.Inject.injectOutputs`（`{{` 后找 `.output}}`，
  精确匹配无空格；未知 id / 无输出 → 替换为中文占位提示，**绝不把
  原始模板泄漏给模型**；无 `.output}}` 的 `{{` 原样保留）；
- **持久化**：`output` 写入 run.json（§10）→ 重启/静默恢复后下游节点
  启动时仍能注入（上游 Succeeded 不重跑，输出必须跨重启保留）；
  重新 Run（StartRun）清空全部 output（全新一轮）；
- **UI**：节点详情面板显示 Output（无记录显示占位）；
- **规划器教学**：Plan Session 的 `planSystemPrompt` 告知模型：下游需要
  上游产出时用 `{{t1.output}}` 引用（仅限已声明依赖的任务）；
- 测试：`PlanInjectTest`（10 例替换/缺失/未知/原样保留）+ runner
  （成功记录、失败不记录、下游 SendPrompt 注入、缺失→占位、重 Run
  清空）+ codec roundtrip + E2E（fixture t2 prompt 引用 `{{t1.output}}`，
  fakecore 回复回显收到的 prompt → 断言 t2 会话里含 t1 输出文本且无
  原始模板）。

---

## 9. preset 与种子 preset

- 节点 `preset` 缺省 = active preset（与现有行为一致）；
- 种子 preset（仓库内置，首次运行播种，仿 Default 机制 `create_preset_defaults`）：

| preset | 定位 | model.conf | builtin_tools（settings.conf） |
|---|---|---|---|
| `Default` | 通用 | 默认占位模型 | （空 = 全开） |
| `Fast` | 快速子任务（廉价模型） | 轻量模型占位 | （空 = 全开） |
| `Deep` | 复杂分析/规划 | 强模型占位 | （空 = 全开） |
| `Data` | 数据类任务 | 默认 | （空 = 全开） |
| `Safe` | 安全子任务 | 默认 | `read_file,write_file,edit_file,search_content`（**禁 execute_command**） |

- 种子 preset 只是结构模板（模型/MCP 占位），api_key/连接串由用户填；preset 管理器已支持复制/重命名，可基于种子自定义；
- v1 阶段：P0–P4 全部节点可用 active preset（preset 字段可选），preset 支持并入 P4.5。

---

## 10. 持久化

```
~/.alayaface/plans/
├── <planId>.json        ← 归一化后的计划（用户可导出/编辑）
└── <planId>.run.json    ← 运行状态（节点状态/attempts/失败记录/sessionId 映射/时间戳）
```

- planId = name slug + 时间戳（如 `monthly-report-1722864000000`）；
- 每次状态迁移落盘：终态迁移必写，中间迁移节流；
- 节点绑定多字段持久化：`session_id`（当前活跃绑定）、`last_session_id`
  （最近一次运行该节点的会话，即使已被关闭/失败，仍可 `resume_session`
  回看）、`attempt_session_ids`（**全部**绑定过该节点的会话 id 历史，
  去重、跨重试/跨 run 保留）、`output`（该节点成功完成的最终回答，
  供下游 `{{tX.output}}` 注入）→ 节点 ↔ 会话绑定跨重启保留，旧尝试的会话
  不再因重试替换绑定而丢失（节点详情面板「历史会话」列表可直接打开）；
  打开 plan 窗口时自动静默恢复，点击节点可重新打开对应会话；
- **Resume（v1）**：重开 app → 打开计划 → 从 run.json 恢复，未完成/失败/阻塞节点**从头重新执行**（新建会话，不尝试恢复子进程；真断点续跑为 v2）；
- **会话关闭即持久化（cancel-first 关闭，§8.3）**：close_session 先发
  CI `cancel`（取消当前任务 → alayacore 经 handleTaskDone **自动保存到
  取消点**），再发 `save`、关 stdin（EOF → 任务已取消，立即退出）→ 等
  ≤5s 自然退出 → SIGKILL 兜底；Drop/断连路径经 kill_child 先 EOF 宽限
  3s。取消点之前的内容完整保留（比 SIGKILL 丢得少，比 drain 等得短）。

---

## 11. 测试计划

| 层 | 内容 |
|---|---|
| Elm 单测 | `Plan/Types`：decode 成功/失败、环检测、未知依赖、重复 id、归一化、roundtrip；`Plan/Layout`：菱形/链式/并联分层坐标；`Plan/Runner`：并发上限、依赖门控、重试计数与 FailureRecord 追加、Stop/Pause/手动重试、断连与 task_error 判定；`Plan/Detect`：fenced 提取边界 |
| Rust 单测 | fs_write/read roundtrip、createParents、错误消息；settings builtin_tools 归一化；create_session preset/builtinTools 参数 |
| Go 单测 | 同上 + 与 Rust 错误消息 parity 断言 |
| 集成 | fakecore 扩展：模拟 task_error → runner 重试 → 第二次成功；端到端：Create Plan → 保存 → Run → 并行窗口 → 点节点打开窗口 |

---

## 12. 分阶段实施计划（进度以 TODO.md 为准）

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | `Plan/Types` + `Plan/Detect` + 全部单测 | ✅ 完成 |
| P1 | `fs_write_file_text` / `fs_read_file_text`（Rust+Go+bridge+Ports）+ 单测 | ✅ 完成 |
| P2 | "Create Plan" 按钮 + 自动保存 plans 目录 + Plans 管理器（列出/打开/删除/导入） | ✅ 完成 |
| P3 | `Plan/Layout` + DAG 视图（HTML/CSS，非 SVG）+ 节点详情面板 | ✅ 完成 |
| P4 | `Plan/Runner` 状态机 + Run/Pause/Stop/Retry + 失败重试与原因记录 + run.json 持久化 + Resume | ✅ 完成 |
| P4.5 | `create_session` 加 `preset`/`builtinTools` 参数 + settings.conf `builtin_tools` + 种子 preset 播种 | ✅ 完成 |
| P5 | 打磨（运行日志/文档/README 等） | ✅ 完成 |
| P6 | Plan Session（菜单入口 + `--system` 规划器指令 + `[Plan]` 标题） | ✅ 完成 |
| P17–P23 | Plans 管理器 Browse 导入 / 节点会话 resume 目录 id / 节点↔会话连接曲线 / config 空壳 / Plan Session 角色锁+无工具 / Stop 关节点窗口（详见 TODO.md） | ✅ 完成 |
| P24 | 输出注入 `{{tX.output}}`（§8.6：TaskDone 记录 output → run.json 持久化 → 下游 SendPrompt 替换 → 详情面板展示） | ✅ 完成 |
| P25 | close_session cancel-first（§8.3：Stop/关窗口立即取消任务，历史保存到取消点） | ✅ 完成 |
| P26 | plan JSON 顶层 `"type": "alayaface-plan"` 标志（§5/§6.7：按钮只认显式标志；**必填无兼容**——缺失/错误值直接报错） | ✅ 完成 |

> 实现偏差：DAG 渲染用纯 HTML/CSS（div 绝对定位 + 正交连线），因为
> elm/svg 不在离线包缓存中；效果与 SVG 等价。会话创建采用**串行化**
> （一次一个 in-flight create，`planCreating`/`planCreateQueue` 全局
> 记录 `(planId, nodeId)`），`SessionCreated` 经 `PlanBindSession` 绑定
> 到节点。**Plan 窗口是多实例的**（`planWindows : Dict String PlanWindow`，
> 每个窗口自带 run 状态/日志/选中节点/创建队列），通过 ⚙ 系统菜单切换，
> 而不是单一 overlay；`SendPrompt` 在会话绑定（Starting→Running）时由
> runner **解析出节点 prompt 文本并随 effect 携带**（`SendPrompt sid promptText`），
> Update 层不再查表重解析——早期两处缺陷（① runner 从未生成 SendPrompt；
> ② 生成后 Update 层用 step 前的旧 run 状态查 prompt 返回空串被丢弃）都曾导致
> 节点会话打开但无任何消息。

---

## 13. 决策记录

### 已确认（用户明确指示）
- **不改 AlayaCore**（约束 C1）；
- 内置工具集与工具确认一样**通过 spawn 参数指定**（`--builtin-tools`），配置放 settings.conf（per-preset，对称 tool_confirm）；
- 设计写入本文档 + 用 TODO.md 管理后续开发（中断后先读本文 + TODO.md）；
- **Plan Session 入口**：用户只需描述需求，不应知道 schema/格式细节；菜单创建带规划器 system prompt 的会话（`--system`），标题带 `[Plan]` 前缀。
- **plan JSON 顶层加 `"type": "alayaface-plan"` 标志（P26，用户指示）**：
  Create Plan 按钮只对**显式带标志**的 ```json 块出现（普通代码示例不误触发）；
  保存/导出总是写入；**必填、无向后兼容**——缺失或值错误直接报错
  （`Missing top-level "type": "alayaface-plan" marker` /
  `Not an AlayaFace plan: ...`）。

### 默认值（未显式确认，实现时按此执行，可在评审时调整）
- `concurrency` 默认 2（1–8 可调）；
- `default_max_attempts` 默认 3，重试退避 2s；
- 失败判定：SM task_error / SM error / 会话断连 / **任务超时**
  （`default_timeout_seconds` / `timeout_seconds`，缺省无超时；P16 已实现）；
- 下游上下文：prompt 支持 `{{<taskId>.output}}` 上游输出注入（P24 已
  实现；§8.6）；未引用的下游 prompt 保持自包含；
- Runner 会话 `toolConfirm="allow"`；
- 文件位置 `~/.alayaface/plans/<planId>.json`；Resume v1 = 重跑未完成节点；
- Plan 只读展示（节点编辑 v2）；
- 种子 preset：Default / Fast / Deep / Data / Safe；
- 优雅关闭（§8.3）：close_session = **cancel → save → EOF → 5s 宽限 →
  SIGKILL**（P25 cancel-first：取消任务并保存到取消点，不等任务跑完）；
  kill_child/KillChild = EOF → 3s 宽限 → SIGKILL；
- Plan 头部可覆盖并发度（1–8，留空 = plan JSON 的 concurrency；P14 已实现）；
- **per-plan 工作目录**（§8.4）：节点会话 cwd = `plans/<planId>/work/`；
  普通会话保持后端 cwd（P16 已实现）。

### 待定（v2，不阻塞）
- 节点 `outputs` 字段（产出物描述，先存不用）；
- 真断点续跑（resume 子进程）；
- MCP-only 模式（`builtin_tools: "none"`）。

---

## 14. 参考

- `docs/go-backend.md` — Go 后端契约（字段命名/错误消息/命令映射）
- `docs/manual-acceptance.md` — 无 GUI 环境下的手工验收清单（GUI 可用时照此执行）
- `src-elm/src/Session/Protocol.elm` — 事件解码契约
- `src-elm/src/Session/Handlers.elm` — 任务状态/tool call 现有处理
- `src-tauri/src/dirs.rs` / `src-go/internal/dirs/dirs.go` — preset/session 目录结构
- `src-tauri/src/commands/settings.rs` — settings.conf 现有实现（builtin_tools 对称参考）
- 旧 Go backend 工作笔记归档：`docs/go-backend-todo.md`

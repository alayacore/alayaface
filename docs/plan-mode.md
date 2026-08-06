# Plan Mode 设计文档（AlayaFace）

> 状态：**已实现（P0–P7 完成；含评审反馈：Plan 独立窗口 + SendPrompt 修复）**。开发进度见根目录 `TODO.md`（必须先读）。
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
- **preset 结构**（`~/.alayaface/presets/<name>/`）：
  - `model.conf` — 模型列表（能力来源）；
  - `mcp.conf` — MCP 服务器（外部工具来源）；
  - `runtime.conf` — 仅 active_model/active_theme（alayacore 管理，勿当配置用）；
  - `settings.conf` — **AlayaFace-owned，按 preset 存储**，`{"tool_confirm": "id1,id2"}`；不复制进会话目录；`get_global_settings(preset)` / `sync_global_settings(config, preset)` 已支持按 preset 读写；
  - `themes/`。
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

### Plan Session（P6）

用户不需要知道任何实现细节（schema / fenced JSON / preset）：

1. ⚙ 菜单 → **New Plan Session** → 创建普通会话，但 spawn 时通过
   `--system` 注入内置的**规划器指令**（`planSystemPrompt`，App/Update.elm
   常量：身份 + 一次性输出 ```json 计划块 + schema + 质量规则 + "之后正常回答"）；
2. 用户只用自然语言描述目标；
3. 模型输出计划块 → 现有 Create Plan 流程接管（检测/校验/保存/Run 零改动）；
4. 会话窗口标题带 `[Plan]` 前缀（`planSessionIds : Set String`）。

链路：`create_session {systemPrompt}` → `spawn --system=<text>`（alayacore
默认 system prompt 之后追加）。resume/fork 会话不传。

---

## 5. DAG JSON Schema（v1）

```json
{
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
| `schema_version` | 是 | 固定 1 |
| `name` | 是 | 计划名（用于文件命名 slug） |
| `goal` | 否 | 总体目标，DAG 视图头部展示 |
| `concurrency` | 否 | 并行上限，默认 2（范围 1–8） |
| `default_max_attempts` | 否 | 节点默认重试上限，默认 3 |
| `tasks[].id` | 是 | 全局唯一、非空 |
| `tasks[].title` | 是 | 节点标题 |
| `tasks[].prompt` | 是 | 发给该节点会话的完整 prompt（**v1 自包含**，不做上游输出注入） |
| `tasks[].depends_on` | 否 | 依赖 id 列表，默认 `[]`；引用必须存在、不允许自依赖、整体无环 |
| `tasks[].preset` | 否 | 运行该节点的 preset 名；缺省 = active preset |
| `tasks[].tools` | 否 | 节点级内置工具集覆盖（逗号列表）；缺省 = preset settings.conf 的 builtin_tools（再缺省 = 全开） |
| `tasks[].max_attempts` | 否 | 节点级重试上限；缺省 = default_max_attempts |

### 校验规则（纯 Elm，decode 后归一化）

- id 唯一非空；title/prompt 非空；
- depends_on 引用存在、无自依赖；**Kahn 拓扑排序检测环**；
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
    | SendPrompt String String           -- sessionId, nodeId
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
- 在 AT 帧完成时对最新助手消息调用；命中 → `Model.pendingPlanOffers` 记 `messageId → rawJson` → 消息下方渲染 **Create Plan** 按钮；
- 点击 → decode/validate → 归一化 → 生成 planId → `fs_write_file_text` 写 `~/.alayaface/plans/<planId>.json` → 打开 Plan 窗口。

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
- **点击节点**：
  - 有 sessionId → `ActivateSession` 置顶聚焦对应会话窗口（查看完整详情）；
  - 无会话 → 右侧节点详情面板（prompt 全文、依赖、失败历史、Retry / Run node 按钮）；
- 底部：运行日志流（每节点启动/成功/失败/重试事件）；
- 关闭 plan 窗口不会停止正在运行的节点会话（run.json 持续落盘，可 Load run
  恢复）；手动关闭某节点会话窗口会向 runner 注入断连事件 → 该节点按失败重试。

### 7.2 Plans 管理器（overlay，仿 Session Manager）
- 列出 `~/.alayaface/plans/*.json`：名称、文件、创建时间、最近运行状态；
- 操作：Open（渲染 DAG）、Resume last run、Delete、Import from file；
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
- **Resume（v1）**：重开 app → 打开计划 → 从 run.json 恢复，未完成/失败/阻塞节点**从头重新执行**（新建会话，不尝试恢复子进程；真断点续跑为 v2）。

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

> 实现偏差：DAG 渲染用纯 HTML/CSS（div 绝对定位 + 正交连线），因为
> elm/svg 不在离线包缓存中；效果与 SVG 等价。会话创建采用**串行化**
> （一次一个 in-flight create，`planCreating`/`planCreateQueue` 全局
> 记录 `(planId, nodeId)`），`SessionCreated` 经 `PlanBindSession` 绑定
> 到节点。**Plan 窗口是多实例的**（`planWindows : Dict String PlanWindow`，
> 每个窗口自带 run 状态/日志/选中节点/创建队列），通过 ⚙ 系统菜单切换，
> 而不是单一 overlay；`SendPrompt` 在会话绑定（Starting→Running）时由
> runner 恰好发出一次（早期版本遗漏导致节点会话打开但无消息）。

---

## 13. 决策记录

### 已确认（用户明确指示）
- **不改 AlayaCore**（约束 C1）；
- 内置工具集与工具确认一样**通过 spawn 参数指定**（`--builtin-tools`），配置放 settings.conf（per-preset，对称 tool_confirm）；
- 设计写入本文档 + 用 TODO.md 管理后续开发（中断后先读本文 + TODO.md）；
- **Plan Session 入口**：用户只需描述需求，不应知道 schema/格式细节；菜单创建带规划器 system prompt 的会话（`--system`），标题带 `[Plan]` 前缀。

### 默认值（未显式确认，实现时按此执行，可在评审时调整）
- `concurrency` 默认 2（1–8 可调）；
- `default_max_attempts` 默认 3，重试退避 2s；
- 失败判定：SM task_error / SM error / 会话断连；**超时默认关闭**（v2）；
- 下游上下文：v1 prompt 自包含，**不做**上游输出注入（v2 可加 `{{t1.output}}` 模板）；
- Runner 会话 `toolConfirm="allow"`；
- 文件位置 `~/.alayaface/plans/<planId>.json`；Resume v1 = 重跑未完成节点；
- Plan 只读展示（节点编辑 v2）；
- 种子 preset：Default / Fast / Deep / Data / Safe。

### 待定（v2，不阻塞）
- 节点 `outputs` 字段（产出物描述，先存不用）；
- 真断点续跑（resume 子进程）；
- MCP-only 模式（`builtin_tools: "none"`）；
- 任务超时。

---

## 14. 参考

- `docs/go-backend.md` — Go 后端契约（字段命名/错误消息/命令映射）
- `src-elm/src/Session/Protocol.elm` — 事件解码契约
- `src-elm/src/Session/Handlers.elm` — 任务状态/tool call 现有处理
- `src-tauri/src/dirs.rs` / `src-go/internal/dirs/dirs.go` — preset/session 目录结构
- `src-tauri/src/commands/settings.rs` — settings.conf 现有实现（builtin_tools 对称参考）
- 旧 Go backend 工作笔记归档：`docs/go-backend-todo.md`

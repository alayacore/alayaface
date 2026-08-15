# AlayaFace

[![CI](https://github.com/wallacegibbon/alayaface/actions/workflows/ci.yml/badge.svg)](https://github.com/wallacegibbon/alayaface/actions/workflows/ci.yml)

[English](README.md) · **中文**

[AlayaCore](https://github.com/alayacore/alayacore) 的 Tauri 图形界面前端。
前端使用 **Elm**，后端使用 **Rust**（Tauri）。

## 架构

代码库由三棵并行的源码树组成：**src-elm/** —— 纯 Elm 前端（无 npm、无打包器），按领域组织模块（App、Plan、Session、Overlay），通过一个轻量 JS 桥（`transport.js`）抽象后端传输方式（Tauri IPC 或 HTTP/WebSocket）；**src-tauri/** —— Rust Tauri 后端（IPC 命令、会话生命周期、TLV 协议）；**src-go/** —— Go 后端（HTTP + WebSocket），托管同一套 Elm 客户端，是 Rust 后端的移植版，因此两个后端都可以运行本应用。两个后端都通过 stdin/stdout 上的 TLV 线协议与 AlayaCore 子进程通信；Elm 核心不依赖 Tauri，与平台无关。

### 数据流

```
AlayaCore (subprocess)
    │  stdout: TLV frames
    ▼
backend reader (reader.rs / internal/session/reader.go)
    │  app.emit("tlv-frame") 或 hub.Broadcast("tlv-frame")
    ▼
transport.js → listen("tlv-frame")   ← Tauri event 或 WS /ws 推送
    │
    ▼  Elm port
Main.elm → subscriptions → Ports.onFrame → FrameEvent raw
    │
    ▼  Decode + handle
Handlers.elm → handleFrameEvent → update SessionState
    │
    ▼  Render
Main.elm → view → HTML
```

## 环境要求

- [Elm](https://elm-lang.org/) 0.19.2（`elm` 需在 PATH 中）
- 运行 Elm 测试套件需要 [elm-test](https://elm-test.readthedocs.io/)
- [Rust](https://www.rust-lang.org/)（含 Cargo）
- [AlayaCore](https://github.com/alayacore/alayacore) 二进制（`alayacore` 在 PATH 中，或通过 `ALAYACORE_BIN` 环境变量指定）
- Linux：`libwebkit2gtk-4.1-dev`、`libgtk-3-dev` 等（参见 [Tauri 前置条件](https://v2.tauri.app/start/prerequisites/)）
- [Go](https://go.dev/) 1.22+（仅 Go 后端需要）

## 快速开始

```bash
make run     # Tauri 桌面应用
make run-go  # Go 后端（浏览器：http://127.0.0.1:8765，绑定 0.0.0.0）
```

### 常用命令

```bash
make elm      # 只编译 Elm 前端（src-elm/ → elm.js）
make run      # 编译 Elm + 启动 Tauri
make dev      # run 的别名
make build    # 发布构建
make test     # 运行 Rust 单元测试 + Elm 测试
make clean    # 清理构建产物
make run-go   # Go 后端：托管 Elm 客户端 + RPC/WS API
make build-go # 构建 Go 后端二进制
make test-go  # 运行 Go 单元测试
make clean-go # 清理 Go 构建产物
```

### 手动构建

```bash
cd src-elm && elm make src/Main.elm --output=elm.js
cd ../src-tauri && cargo run
```

## Go 后端（浏览器 / HTTP）

同一套 Elm 客户端也可以运行在 Go 后端（`src-go/`）上：它托管前端，并以 HTTP API 的形式实现了与 Tauri 命令等价的功能。`bridge.js` 会自动检测运行环境：存在 `window.__TAURI__` 时使用 Tauri IPC，否则使用 `fetch` + WebSocket。

```bash
make run-go
# 打开 http://127.0.0.1:8765/（本机）或 http://<host>:8765/（局域网）
```

服务端绑定 `0.0.0.0:8765`（所有网卡），因此可以通过 SSH 端口转发访问（`ssh -L 8765:localhost:8765 <host>` 然后打开 `http://127.0.0.1:8765/`），或直接在局域网内访问——方便开发/调试。

参数：

```
alayaface-server --addr 0.0.0.0:8765 --static ../src-elm [--token <token>]
```

> ⚠️ 使用 `0.0.0.0` 且不带 `--token` 时，任何能访问该端口的人都可以通过 API 创建会话、读取文件。当端口暴露在 localhost/SSH 之外时，请加上 `--token <t>`。令牌会被注入到所托管的页面中（`<meta name="alayaface-token">`），`bridge.js` 会自动附带它（RPC 用 `Authorization: Bearer`，WS 用 `?token=`），因此浏览器客户端无需改动；但任何能获取页面本身的人也会拿到令牌（页面本身就是凭证）。

- 命令：`POST /rpc/{command}`，JSON 参数（对应 Tauri 的 `invoke`）。
- 事件：WebSocket `GET /ws` 推送 `{type, payload}` 消息（`tlv-delta`、`tlv-frame`、`core-status`）。
- 完整的 API 映射与设计见 `docs/go-backend.md`（历史阶段记录：`docs/archive/TODO.md`）。

## Plan 模式（DAG 任务规划与执行）

Plan 模式把一个大任务变成依赖图，由 AlayaFace 替你执行：

1. **规划（Plan）**：在任意会话中，让模型把任务拆解并输出一个围栏 ```json 代码块（schema 见 `docs/plan-mode.md` §5）。只有当代码块顶层显式带有 `"type": "alayaface-plan"` 标记时计划才会自动创建，因此普通的 ```json 代码示例永远不会触发它。
2. **保存（Save）**：计划会经过校验（id 唯一、依赖存在、无环）、规范化，并写入 `~/.alayaface/sessions/<originSessionId>/plans/<planId>/<planId>.json`（每个计划都保存在创建它的会话内部）。
3. **运行（Run）**：每个计划都在自己的**窗口**中打开（与会话窗口一样——可拖拽 / 调整大小 / 关闭，⚙ 菜单会列出所有已打开的计划）。窗口中显示 DAG；点击 **Run** 会为每个任务启动独立的会话窗口——**顶层计划等待你点击 Run；子计划自动运行**。**点击节点会打开它的会话**（聚焦它；如果已关闭或重启后，会自动从磁盘恢复——绑定关系持久化在 `<plan>.run.json` 中），并遵循依赖与并行度（`concurrency`，默认 8）。任务使用节点级的 `preset` / `tools` 运行（见下文），工具确认自动放行。
4. **重试（Retry）**：失败的任务会记录失败原因和尝试次数（显示在节点和详情面板上），自动重试至多 `max_attempts` 次（默认 3 次，2s 退避），之后把依赖它的节点标记为 **Blocked**（阻塞）。失败/取消的节点可以手动重试。运行状态持久化到 `<plan>.run.json`——**Load run**（加载运行）可在重启后恢复未完成的任务。

### 预设与工具集

- `~/.alayaface/presets/<name>/` 打包了模型列表（`model.conf`）、MCP 服务器（`mcp.conf`）和 AlayaFace 自有的 `settings.conf`（`tool_confirm`、`builtin_tools`、`reasoning_level` 0|1|2、`system_prompt`）——通过 **预设管理器（Preset Manager）** → 编辑 → 设置修改。
- `~/.alayaface/preset_order.conf` 记录预设列表的**显示顺序**（JSON 名称数组）——在 **预设管理器** 中按住 ⠿ 手柄拖动即可排序；文件里没有的预设会按字母序追加，因此永远不会被隐藏。
- `~/.alayaface/global.conf` 是**跨预设的全局配置覆盖层**（对每个预设生效）：目前只有 `recursion_limit`（默认 8）——通过 ⚙ → **全局配置（Global config）** 编辑。Plan 模式的递归受它约束：计划节点的会话深度（顶层 = 1，每层子计划 +1，持久化在计划的 `meta.json` 中）超过该限制时，节点会话**不再获得 plan 系统提示**，模型因此停止创建子计划。
- 内置工具通过 `--builtin-tools=id1,id2,...` 在会话启动时传给 AlayaCore（空 = 全部工具）。可按预设（设置编辑器）或按计划节点（`tools` 字段）配置。
- 首次运行会创建种子预设：`Default`、`Fast`、`Deep`、`Data` 和 `Safe`（无 `execute_command`）。可在预设管理器中复制/重命名；计划节点通过 `"preset": "Name"` 选择预设。

**计划递归是模型自治的**：只有**顶层计划**需要你点击 Run；每个**子计划**（节点模型输出的另一份计划 JSON）都会自动创建**并自动运行**——节点会话以工具自动放行的方式执行，因此顶层 Run 点击是整个委派子树的唯一人工闸门。

**AlayaCore 永远不会被修改**——所有能力差异都通过启动参数和预设配置文件来表达。

**计划节点会话相互隔离**：计划中每个节点都以 `sessions/<originSessionId>/plans/<planId>/work/` 作为工作目录运行（后端在启动时创建），任务在计划内交换文件，同时计划之间、计划与后端目录之间互不干扰。**任务没有超时**（R 系列重构中移除）：挂起的节点会一直保持 Running，直到你停止它或会话断开。

**输出注入（Output injection）**：下游节点提示词可以用 `{{<taskId>.output}}`（例如 `{{t1.output}}`）引用上游任务的结果；下游节点启动时，模板会被替换为上游任务的最终回答（成功时记录，持久化在 `<plan>.run.json` 中，重启后仍然有效）。节点详情面板显示每个节点记录的输出。

**关闭会话以取消优先（cancel-first）**：`close_session` 现在先发送 CI `cancel`（AlayaCore 中止正在运行的任务并自动保存到取消点的对话），再 `save`，然后关闭 stdin——子进程立即退出，而不是把一个长任务耗尽。这正是 **Stop** 能真正停止每个运行中节点的原因：运行中的任务被中止（保留到取消点的历史），而不是被允许跑完。只有过了 5 秒宽限期后才会 SIGKILL。（AlayaCore 本身未被改动；`cancel` 和 `save` 是它自己的命令。）

## 自动化 E2E（无头浏览器，无真实模型）

`make e2e` 运行完整的 Plan 模式浏览器测试——无需 GUI，无需真实模型：

- 构建 `fakecore`（可脚本化的 alayacore 替身）+ Go 后端，通过 `puppeteer-core` 启动系统 Chrome 无头模式（安装一次：`cd e2e && npm install`）
- 走真实 UI 流程：新建会话 → 输入提示词 → fakecore 返回围栏 plan JSON → Plan 窗口**自动创建**（R2，无需按钮）→ Plan 窗口 DAG → 修改并发度 → **Run** → 节点成功（t2 通过标记失败一次，然后自动重试）→ 运行完成 → 状态栏显示 Completed → 点击节点激活它的会话并显示助手回复；Stop / resume / 浏览导入 / 标记拒绝路径也都覆盖了
- 通过 DOM 选择器断言，截图保存到临时产物目录（退出时删除；`ALAYAFACE_KEEP_ARTIFACTS=1` 可保留用于调试），并清理服务/Chrome/临时目录——Ctrl-C 也会杀掉后端子进程，不会留下孤儿服务

它已经抓到过单元测试漏掉的真实 bug（见 `docs/archive/TODO.md` P15）。
它**不**覆盖真实模型行为——那仍然需要 OpenAI 兼容的 API key（或本地 `.gguf`），见 `manual-acceptance.md`。

## CI（GitHub Actions）

`.github/workflows/ci.yml` 在推送到 `main` 和 pull request 时运行：**Go**（`go vet` + `go test -race`）、**Elm**（`elm make` + `elm-test`）、**Tauri/Rust**（`cargo test` + `cargo build`——完整应用编译），以及完整的 **E2E** 任务（Go 后端 + fakecore + 无头 Chrome，同时运行 `plan-e2e.mjs` 和 `restart-e2e.mjs`）。状态徽章在本文件顶部。

## TLV 协议

AlayaFace 通过 stdin/stdout 上的 TLV（Tag-Length-Value，标签-长度-值）帧与 AlayaCore 通信。完整协议规范见[适配器指南](../alayacore/adapter-guide/README.md)。

关键标签：

| Tag | 方向 | 说明 |
|-----|------|------|
| UT  | stdin  | 用户文本输入 |
| UI  | stdin  | 用户图片（data URI 或 URL） |
| UE  | stdin  | 用户消息结束（flush） |
| At  | stdout | 助手文本流式增量 |
| Ar  | stdout | 助手推理流式增量 |
| Af  | stdout | 工具参数流式增量 |
| Uf  | stdout | 工具结果预览快照（临时、仅显示；UF 会覆盖） |
| AT  | stdout | 助手文本完成 |
| AR  | stdout | 助手推理完成 |
| AF  | stdout | 工具调用生命周期 |
| UF  | stdout | 工具结果 |
| SM  | stdout | 系统消息（JSON） |

所有 stdout 帧都以 `\x00<history_id>\x00` 为前缀，用于流式关联。

## 调试

TLV 帧日志会以 `[tlv]` 前缀打印到 stderr：

```
[tlv] << abc-123 AT 0b
[tlv] >> abc-123 UT 15b :cancel
[tlv] << abc-123 SM 80b {"type":"task",...}
```

运行 `cargo run` 时这些日志会出现在终端中。

## 移植到 Web / VS Code

Elm 核心与平台无关（`Session/` 模块没有 Tauri 依赖），`bridge.js` 已经抽象了后端传输：

- 有 `window.__TAURI__` → Tauri IPC（`tauriTransport`）
- 没有 → `fetch POST /rpc/{command}` + WebSocket `/ws`（`httpTransport`，Go 后端使用）

要移植到其他目标（例如 VS Code postMessage），只需在 `bridge.js` 顶部增加一个传输实现；Elm ports 和 `Session/` 模块保持不变。

# AlayaFace Plan Mode — 手工验收清单（GUI 环境）

> 用途：无 GUI 环境下无法执行的人工验收步骤。有桌面环境时按本清单逐项
> 冒烟，勾选后回写 TODO.md。后端已由 fakecore E2E 覆盖、runner 已由
> 128 个 Elm 单测覆盖；本清单验证的是**真实 alayacore + 浏览器/Tauri 的
> 集成表现**。
>
> 前置：`alayacore` 可执行（`which alayacore` 或 `ALAYACORE_BIN`），
> 模型 API key 已配置（Default preset 的 model.conf），MCP 当前为
> 禁用状态（`~/.alayaface/presets/Default/mcp.conf` 全部注释，恢复 =
> 取消注释）。

## 启动

- [ ] Tauri：`make run`；或浏览器：`make run-go` → http://127.0.0.1:8765/
- [ ] ⚙ 菜单出现：New Session / **New Plan Session** / Plans / Presets / Settings / Sessions

## 1. Plan Session + 创建计划（P2/P6）

- [ ] ⚙ → **New Plan Session** → 会话窗口标题带 `[Plan]` 前缀
- [ ] 用自然语言描述任务（如「写一份月度报告：先列大纲，再写三节正文」）
- [ ] 模型回复中出现 fenced ```json 计划块 → 消息下方出现 **Create Plan** 按钮
- [ ] 点击 Create Plan → 打开 Plan 窗口（独立窗口，非 overlay），显示
      DAG（节点 + 依赖边）、目标、元信息
- [ ] `~/.alayaface/plans/<name>-<ts>.json` 已保存（归一化后版本）
- [ ] ⚙ → Plans 管理器列出该计划，可 Open / Delete / Import

## 2. Run + 节点会话内容（P4/P7 修复点）

- [ ] Plan 窗口点 **Run** → 无依赖节点先启动（并行 ≤ concurrency），
      依赖满足后逐层启动
- [ ] **每个节点会话打开后必须显示 prompt 和模型回复**（P7 修复：
      SendPrompt 携带文本，不再空窗口）
- [ ] 标题带 `[Plan · planId/nodeId]` 绑定标记
- [ ] 会话窗口可拖动/缩放/关闭；多个 plan 窗口互不干扰，⚙ 菜单可切换置顶

## 3. 节点点击 ↔ 会话绑定（P8/P9）

- [ ] 点**存活**节点 → 聚焦其会话窗口
- [ ] 关闭某节点会话窗口 → 点该节点 → 自动 `resume_session` 从磁盘恢复，
      内容完整（UT/AT/AF/UF/AR 全历史渲染）
- [ ] 失败/取消的节点 → 点节点 → 经 `last_session_id` 恢复旧会话可回看
- [ ] 重开 app → 打开计划 → 自动静默恢复 run.json → 点已运行节点能重新
      打开会话
- [ ] **Load run** → 恢复并继续执行未完成任务

## 4. 失败与重试（P4/P10/P11）

- [ ] 节点 preset 设为不存在的名字 → 创建失败不再卡死（P11：失败显示在
      节点上，可 Retry；整个 run 不悬挂）
- [ ] 自动重试：失败 → 节点变 Waiting（x2 徽章）→ 2s 后自动重试
- [ ] 退避期间点 **Stop** → 保持停止，迟到的自动重试不复活节点（P10）
- [ ] 手动 Retry：失败/取消节点 → 节点详情面板 Retry 按钮 → 复活重跑
- [ ] 达到 max_attempts → Failed，下游 Blocked（fixpoint 传播），run 状态
      FailedRun
- [ ] 运行中创建普通会话（New Session）→ 排队，不误绑到 runner 节点
      （P11 统一创建队列）

## 5. 优雅关闭（v2 本轮新增）

- [ ] 关闭一个进行中的节点会话窗口 → 等它把当前轮跑完（≤5s）→ 进程退出
- [ ] 关闭后 `~/.alayaface/sessions/<id>/session.alaya` 存在且**包含当前
      对话**（非空、含最近一轮；此前 SIGKILL 会丢进行中内容）
- [ ] 关闭空闲会话（无任务）→ session.alaya 同样已保存（CI `save` 生效）
- [ ] 连续快速关闭多个会话 → 无残留 alayacore 进程（`pgrep -f alayacore`）

## 6. Presets / 工具集（P4.5）

- [ ] Presets 管理器显示 5 个种子 preset（Default/Fast/Deep/Data/Safe）
- [ ] Safe preset 的节点运行时不出现 execute_command（settings.conf
      builtin_tools 生效）
- [ ] 节点 `tools` 字段覆盖生效

## 回归（非 Plan 功能不受影响）

- [ ] 普通 New Session 对话正常（无 [Plan] 前缀、无 planner system prompt）
- [ ] Session 管理器 / 删除会话 / 恢复会话正常
- [ ] 文件选择器、Settings 编辑器（tool_confirm / builtin_tools）正常

## 已知限制（验收时确认「符合预期」即可）

- app 在任务进行中被杀 → 丢进行中那一轮（alayacore 只在任务结束保存，
  C1 不改 alayacore）
- 5s 宽限内未跑完的长任务仍会被 SIGKILL（save 帧已先行落盘）
- 两个 plan 在 ~50ms 内同时打开可能干扰自动恢复链（planReadTarget 单槽）

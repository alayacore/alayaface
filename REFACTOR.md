# Plan Mode 重构（R 系列）：模型自主子流程 + 递归

> **重构总纲**。中断恢复流程：
> 1. 读本文件（设计 + 阶段流程）→ 读 `TODO.md`（R 系列任务清单）→ 从第一个未完成的
>    checkbox 继续；
> 2. 每个阶段完成 → 跑全量测试（`src-elm/elm-test` / `src-tauri/cargo test` /
>    `src-go go test -race ./...` / `make e2e`）→ 提交 → push **三个 remote**
>    （origin / gitee / org，分支 main，`git ls-remote` 验证一致）；
> 3. 约束不变：**NEVER modify AlayaCore**；双后端 parity（本重构基本纯前端 Elm，
>    Rust/Go 后端零新增命令）；Elm 纯逻辑在 `Plan/*`；所有新参数可选/向后兼容。

## 0. 目标

把 Plan Mode 从「用户手动触发的独立工具」升级为「**模型自主的子流程 / 异步工具**」：

- 检测到 plan JSON → **自动创建** Plan 窗口（不弹按钮），等用户点 Run；
- 任意会话（普通 / 节点）模型都可输出 plan → **递归**（节点委托子 plan）；
- Plan 完成 → **回填**结果到发起会话 → **自动继续**；
- 节点/Plan 窗口按规则自动关闭；plan 持久化，消息可点击回看。

## 1. 已确认决策（用户逐条拍板，勿改）

| # | 决策 |
|---|---|
| D1 | 检测到 ```` ```json + type: alayaface-plan ```` → **自动创建** Plan 窗口（不弹按钮），**等用户点 Run** |
| D2 | 提示词**去掉角色锁**（P22 的"规划器不是执行器/禁用工具"作废）；**固定 plan 模式**（全局开关忽略）：所有 session 创建注入建议性 plan 提示词 |
| D3 | 节点模型回复完成（SM task done）时检查**最后一条 assistant 消息**：含 plan JSON → 节点**不完成**，进入「等待子 plan」；不含 → Succeeded |
| D4 | **判据可靠性**：成功必经回填 → 回填后最后消息不再是 plan JSON。故"最后消息是 plan JSON" ⇔ 仍在等待 |
| D5 | 等待子 plan 的节点：**窗口保持打开**（显示等待）；**父 run 保持 InProgress**；用户手动关窗口 → 回填时自动 resume |
| D6 | Plan/子 plan **Completed → 回填**发起会话：节点结果汇总 + `[Plan: <planId>]` 标记作为新 prompt → **自动继续**（不等用户） |
| D7 | 回填目标会话已关 → **自动 resume**（弹窗）+ 继续 |
| D8 | **Failed / Stopped → 零回填**（用户看到状态条失败 + [重新执行]） |
| D9 | **重跑 = 跳过成功节点**（不是全量重置 StartRun），只处理未完成节点：普通失败/取消/阻塞 → 重跑节点（新建会话）；**等待子 plan → 重跑其子 plan**（planId 不变，不重跑节点，无需 origin 重绑）；级联递归（无限下钻） |
| D10 | **窗口关闭规则**：仅 plan 打开的**节点会话**在 **Succeeded** 时关闭（绑定保留可回看）；普通会话永不自动关闭；等待子 plan 的节点会话不关 |
| D11 | **Plan 窗口**：全部节点完成后（Completed）→ 先回填再自动关闭；Failed/Stopped 保留窗口（可查看/重试）；关闭后从 Plans 管理器 / 状态条 / `[Plan: xxx]` 链接重开 |
| D12 | **状态条**（替代 Create Plan 按钮）：消息下方 plan 绑定组件（名称 + 状态 + [打开] + [重新执行]）；持久化 + 重启恢复 |
| D13 | **超时机制整体移除**（P16 的 timeout）：schema 字段、validate、runner Tick、app 心跳全删；将来递归稳定后重新设计引入。保留 startedAt（仅记录）、工作目录隔离 |
| D14 | **递归无深度限制**（体验期）；自动创建无确认（体验期）；多 plan 回填顺序执行（体验期） |
| D15 | **Plan Session 入口删除**（P6/P22 的菜单、planSessionPending/planSessionIds、[Plan] 标题、builtinTools=""） |

## 2. 运行时元数据存储（新决定）

- `plans/<planId>.json`：**纯 plan 文档**（type/schema/tasks，用户可导出/编辑，不含运行时噪音）；
- `plans/<planId>.run.json`：run 状态（节点状态含 `WaitingForPlan`、output、startedAt、会话绑定）；
- **`plans/<planId>.meta.json`（新增）**：运行时元数据
  ```json
  {
    "origin": { "sessionId": "...", "messageId": "hist-..." },
    "feedbacks": [ { "at": 172..., "status": "completed|failed|stopped", "text": "...", "planId": "..." } ],
    "created_at": 172...
  }
  ```
- 节点 ↔ 子 plan 关联：经**子 plan 的 meta.json origin** 反查（origin.sessionId = 父节点会话 id）；
- 重启恢复：打开会话时扫描 plans 目录构建 `messageId → planId` 索引（复用 fs_list_dir）；
  **重放历史消息跳过 plan 检测**（防重复自动创建）。

## 3. 核心机制

### 3.1 节点生命周期（递归基石）

```
Running → 模型回复完成（SM task done）
   └─ 最后一条 assistant 消息含 plan JSON？
        ├─ 否 → Succeeded → 关闭节点窗口（绑定保留，点击 resume 回看）
        └─ 是 → WaitingForPlan（新状态）
                · 子 plan 已在检测时自动创建（origin = 本节点会话）
                · 窗口保持打开（"等待子 plan <id>"）
                · 父 run 保持 InProgress
                · 超时：已移除（D13）
  子 plan Completed → 回填本节点会话 → 自动继续（发 prompt）
        → 模型再回复 → 再判最后消息（可再委托 / 完成）
  子 plan Failed/Stopped → 零回填 → 节点停在 WaitingForPlan
        → 用户对子 plan 状态条 [重新执行] → 子 plan 完成 → 回填 → 节点继续
```

### 3.2 回填（自动继续）

- 触发：plan 状态 → **Completed**（含子 plan）；
- 内容：所有 Succeeded 节点 output 汇总（P24 已有）+ `[Plan: <planId>]` 标记；
- 角色：user 消息（alayacore 只有 user 流触发回复），**前缀 `[Plan 结果]`**，UI 渲染为
  system 样式（区别于真实用户消息）；
- 发送：Ports.sendPrompt（现成）；目标会话已关 → resume_session 恢复再发；
- 结果写入 feedbacks（meta.json）→ 重启后恢复展示；
- 回复又含 plan JSON → 再委托（递归，D14）。

### 3.3 重跑（重新执行 / 级联）

```
[重新执行]（状态条或 Plan 窗口）：
  ① Succeeded 节点（含已完成回填的子 plan）→ 跳过，全不动
  ② 未完成节点：
     - 普通 Failed/Canceled/Blocked → 重跑节点（新会话，干净重来）
       （Blocked 重置为 Pending，依赖成功后自动调度）
     - WaitingForPlan → 不重跑节点！重跑其子 plan（planId 不变）
       → 子 plan 完成 → 回填该节点 → 节点继续 → 完成
  ③ 级联递归：子 plan 重跑时其未完成节点按 ② 处理（无限下钻）
```

### 3.4 状态条（消息下方 plan 绑定）

```
[Plan: e2e-demo-1234]  名称  ● Running   [打开]
  Created  → [打开]
  Running  → ● + [打开]
  Completed→ ✅ + [打开]（回填已自动继续）
  Failed   → ⛔ 失败原因 + [打开] [重新执行]
```

- 绑定：meta.json origin（messageId ↔ planId）；
- 状态：从 run.json 读；重启后扫描 plans 目录重建索引恢复；
- 回填消息里 `[Plan: xxx]` 渲染为链接（第二入口，点击 openPlanFile）。

## 4. 边界情况（已排查）

1. **重放防重**：历史消息重放不触发自动创建（重放路径跳过检测；已绑定消息只恢复状态条）；
2. **等待中用户手动发消息** → 节点按正常完成处理（放弃等待）；
3. **等待中窗口被手动关** → 回填时自动 resume（D7）；
4. **多层递归无深度限制**（D14）；父 run 因子 plan 失败永停 InProgress → 用户 Stop 父 run
   （WaitingForPlan 节点 → Canceled）；
5. **并发回填**：多 plan 完成顺序到达同一会话 → 逐个发 prompt，顺序执行；
6. **P24 输出注入独立**：子 plan 内部节点仍可用 `{{tX.output}}`；
7. **解析失败**（检测到 marker 但 JSON 无效）→ 错误内联到原消息下方，不建窗口；
8. **旧 plan 文件**（带 timeout 字段）：decode 忽略未知字段，照常打开（D13 兼容）。

## 5. 删除 / 保留 / 新增

**删除**：Plan Session 菜单 + planSessionPending/planSessionIds + `[Plan]` 标题 +
builtinTools=""（P22 角色锁）；Create Plan 按钮 UI；StartRun 全量重置语义；P16 超时
（schema 字段 / validate / runner Tick / app 心跳 / fakecore fixture timeout）；
P23"保留 succeeded 节点窗口"语义（反转）。

**保留**：P26 type marker；P9/P13 历史会话（lastSessionId/attemptSessions）；P19 连接曲线；
P25 cancel-first；P16 工作目录隔离（startedAt 保留）；P24 输出注入；Plans 管理器；
Load run；Export；pendingPlanOffers（改造为自动创建缓冲）；planCreateQueue（会话创建串行）。

**新增**：`WaitingForPlan` 节点状态；`meta.json`（origin/feedbacks）；状态条组件；
回填自动继续；重跑级联；重放防重；回填消息 system 样式渲染 + `[Plan: xxx]` 链接；
plan 完成自动关窗（先回填）。

## 6. 重构阶段（每阶段：实现 → 全量测试 → 提交 → push 三 remote）

### R1 基础：schema 与纯逻辑
- [x] `Plan/Types.elm`：删 `defaultTimeoutSeconds`/`timeoutSeconds` 字段与 validate 校验
      （decode 忽略未知字段 → 旧文件兼容）；`NodeStatus` 新增 `WaitingForPlan`
      （nodeStatusToString/FromString "waiting_for_plan"）；codec 兼容
- [x] `Plan/Runner.elm`：删 `Tick`/`checkTimeouts`/`timeoutNode`；TaskDone 判委托
      （事件带 `delegated : Bool`——由 Update 层按最后消息判定传入）；WaitingForPlan 状态
      迁移（TaskDone+delegated → WaitingForPlan；回填继续事件 `ResumeDelegatedNode` →
      Running；等待中 Stop → Canceled；等待中手动 TaskDone(非委托) → Succeeded；
      等待中 TaskDone error → 忽略保持等待）
- [x] 测试：删超时 5 例 + schema 3 例；加 WaitingForPlan 迁移 7 例 + codec roundtrip 1 例；
      Elm 180 全绿；Rust 42 / Go -race 8 包不受影响

### R2 检测与自动创建
- [ ] `App/Update.elm`：pendingPlanOffers 改造为**自动创建**（检测即 PlanSaveReady 流程，
      不弹按钮）；重放路径跳过检测（重放 flag 或已绑定判定）；解析失败错误内联到原消息
- [ ] `planSystemPrompt` 重写（去角色锁，建议性："复杂任务先输出 plan JSON，输出后停止等待"）
      + 所有 session 创建注入（普通会话 create_session 传 systemPrompt；节点会话同样注入
      = 递归入口）
- [ ] 删除 Plan Session：菜单入口、`CreatePlanSession` Msg、`planSessionPending`、
      `planSessionIds`、`[Plan]` 标题、Plan Session 的 builtinTools=""
- [ ] 测试 + E2E 改造：Create Plan offer 断言 → 自动创建断言

### R3 回填 + 状态条 + 持久化
- [ ] `meta.json` codec（origin/feedbacks）+ 自动创建时写 origin
- [ ] 状态条组件（View）：消息下 plan 绑定（名称/状态/打开/重新执行）+ CSS
- [ ] 回填：plan Completed 事件 → 构造汇总 prompt（节点 output 汇总 + `[Plan: xxx]`）→
      发 origin 会话（已关则 resume）→ 自动继续；Failed/Stopped 零回填；
      回填写 feedbacks
- [ ] `[Plan: xxx]` 链接渲染（消息文本扫描 → clickable → openPlanFile）
- [ ] 重启恢复：扫描 plans 目录重建 messageId → planId 索引（打开会话时）；
      重放消息渲染状态条
- [ ] 测试 + E2E（回填/状态条/链接）

### R4 关闭规则 + 重跑级联
- [ ] `closeAndClear`：Succeeded 也关节点窗口（保留绑定）；WaitingForPlan 不关
- [ ] Plan Completed → 先回填 → 自动关 Plan 窗口；Failed/Stopped 保留
- [ ] 重跑：新 Msg（PlanRunRestart）＝跳过 Succeeded + 未完成节点分类（普通重跑 /
      等待子 plan → 重跑子 plan，planId 不变）；Blocked 重置可调度
- [ ] E2E：8/8b 重写（成功节点窗口已关 → 点击 resume；Stop 场景保留）

### R5 清理 + E2E 重写 + 文档
- [ ] 死代码清理（P22 残余、按钮 CSS）；`Time.every` 订阅删除
- [ ] E2E 全量重写：fixture（t3 保留 hang-once 供 Stop；E2E 开头**预置 t3 hang marker**
      使第一次 run 秒成功）；新增递归（节点输出 plan → 子 plan → 回填 → 节点继续）、
      状态条、重跑级联步骤
- [ ] 文档：docs/plan-mode.md（§5/§6.7/§7/§8.5 移除超时/§13）、README、
      docs/manual-acceptance.md；TODO.md 勾选
- [ ] 全量验证：Elm / Rust / Go -race / make e2e 全绿 → 提交 → push 三 remote

## 7. 验证命令

```bash
cd src-elm && elm-test && elm make src/Main.elm --output=/tmp/r.js
cd src-tauri && cargo test
cd src-go && go vet ./... && go test -race ./...
cd /home/wallace/playground/alayaface && make e2e
git push origin HEAD:main && git push gitee HEAD:main && git push org HEAD:main
```

## 8. 体验期接受项（用户明确）

- 递归无深度限制（模型链式 plan 可能不收敛——观察）；
- 自动创建无确认（模型输出 plan 即建窗口，即使用户不想要）；
- 父 run 可能因子 plan 失败长期 InProgress（用户 Stop / 重跑子 plan）；
- 超时移除后挂起节点永远 Running（只能 Stop / cancel-first 关闭）。

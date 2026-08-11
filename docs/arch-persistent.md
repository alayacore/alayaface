# C 架构：不可变值模型（Persistent Structure）——会话 / plan / run 的持久化语义重构

> **定位**：这是 P39 血缘架构的**替代方案**（用户 2026-08 决策：放弃临时 fix，直接做正确架构）。
> 目标心智模型：函数式语言持久化数据结构——**天然递归、天然共享、天然隔离**。
> 本文档是设计蓝本，实施前先与用户逐条确认"已确认决策"（§9）。

---

## 0. 一句话

把"会话 / plan / run"从**可变物理实体 + 共享身份**（现状：一个 plan 目录 + 血缘 registry +
一个全局 run 状态）改为**不可变值 + 结构共享**（更新产生新值，旧值保留，未变部分共享，
plan 状态是追加式不可变 run 日志 + 会话版本内的视图指针）。

---

## 1. 现状的不可救根因（为什么必须重做，而不是再打补丁）

| # | 根因 | 症状（用户可感知） |
|---|---|---|
| R1 | **plan 状态是 plan 级全局可变对象**：`meta.json.last_status` / `run.json` 唯一一份，被所有绑定它的会话共享；`persistRunStatus` 写它 | 老会话里未执行的 plan A，重跑后状态栏变成"已执行"；点开 plan 窗口看到的是别的会话的 run |
| R2 | **fork = 物理身份复制 + 血缘共享**：新目录 + `session.meta.json { conversation_id, parent_instance_id }`，绑定按 conversation 解析 | 顶层会话之间共享身份；链接跨会话指向；需要 head/血缘表，重启重建，处处补丁 |
| R3 | **部分拷贝**：重跑 fork 只重放截断历史（`truncateHistory` 到 plan JSON） | 不是"拷贝整个会话"，无法表达"老会话是重跑前世界" |

三个根因同源：**用"可变共享"实现共享，用"身份复制"实现隔离**。
正确做法恰好相反：**用"不可变值"实现隔离，用"结构共享"实现共享**。

---

## 2. 核心抽象（函数式映射）

| 想要的性质 | 实现机制 | 含义 |
|---|---|---|
| 天然隔离 | **不可变性**：任何"更新"产生**新值**，旧值原封不动 | 老会话永远看到自己的版本；plan 完成/重跑不影响历史版本 |
| 天然共享 | **结构共享**：新值引用未变部分（消息前缀、plan 定义、run 对象），零拷贝 | 不膨胀；plan 只有一份定义，runs 是追加日志 |
| 天然递归 | **结构递归**：plan → 节点会话（引用会话值）→ 子 plan（引用），类型定义自身递归 | 子 plan/节点会话是值引用，不是拷贝展开 |
| 链接本地 | **引用即结构内指针**：链接 = (会话值内的 plan 消息 → plan 值)，状态 = 该会话版本的视图指针 | 链接永远指向"自己下面"（自己版本看到的 run） |

---

## 3. 数据模型（概念层，Elm/Go/Rust 通用）

### 3.1 不可变对象（内容寻址，引用 = 对象 hash）

```
PlanDef   — plan 静态定义（不可变）：planId / name / tasks DAG / meta
Run       — 一次运行的快照（不可变）：runId / status / nodes / startedAt / finishedAt / summary
Version   — 会话的一个版本（不可变）：
            { messages : Seq MsgRef        -- 持久化消息序列（前缀共享）
            , planViews : Map PlanKey RunRef  -- 本版本看到的每个 plan 的 run
                                               --（Nothing = 该版本下未执行）
            , parent : Maybe VersionRef    -- 派生来源（版本树边）
            }
```

### 3.2 引用层（可变，轻量）

```
Plan    = { def : PlanDefRef, runs : Vec RunRef }        -- runs 追加（不可变对象列表）
Session = { id : String                                  -- 稳定身份（= 创建 id，永不改变）
          , head : VersionRef                            -- 当前版本
          , versions : Vec VersionRef                    -- 版本历史/树
          }
```

### 3.3 关键不变式

- **I1**：`PlanDef`/`Run`/`Version` 一经创建不可变（内容寻址，写后不更）
- **I2**：`plan.runs` 只追加；`Run` 之间无修改关系（重跑 = 新 Run，旧 Run 保留）
- **I3**：会话的"状态"完全由 `head` 版本决定；旧版本是历史（只读）
- **I4**：plan 的"显示状态" = `Version.planViews[plan]`（**不是** plan 的全局字段）——同一 plan 在不同版本里状态不同，天然隔离
- **I5**：`Session.id` 稳定，**没有** conversation/instance 之分（身份层消灭血缘）

---

## 4. 更新语义（每种操作 = 一次不可变更新）

### 4.1 plan 运行（工作区 → 固化）

- 运行中是**工作区**（可变，UI 交互：节点状态、输出流）
- 完成/停止/失败时**固化**一个不可变 `Run` 快照 → `plan.runs` 追加
- 固化点：完成、失败、停止、重跑起点（旧 run 不删）

### 4.2 plan 完成回写（核心：结果插回 parent）

```
旧版本 V₀：messages = P ++ [PlanMsg A] ++ R      （P=前缀, R=plan 后内容）
新版本 V₁：messages = P ++ [PlanMsg A] ++ [Feedback A]   （前缀 P 结构共享）
           planViews = V₀.planViews ⊕ { A → newRun }
           parent    = V₀
head := V₁
```

- 前缀 P 与 V₀ **共享**（一个不可变消息块，不拷贝）
- R（被替换部分）只存在于 V₀ → 旧版本天然保留被截断内容（撤销/历史免费）
- **不需要 fork、不需要新会话目录**：同一 `Session` 的 head 从 V₀ 切到 V₁

### 4.3 重跑 plan A（分支语义，老会话保持）

用户从某版本重跑 A → 派生**新分支**：

```
V₁  = 从当前 head V₀ 派生：messages = 锚点前缀 ++ [新结果]，planViews ⊕ { A → newRun }
head := V₁    （当前会话的 head 更新）
V₀  保留      （= "老会话"：A 未执行，状态栏 NotStarted）
```

- **与现状的关键差异**：重跑**就是**把当前会话的 head 更新为新版本；老版本 V₀ 是同一个 `Session` 的历史（会话管理器可查看/回退）
- 若用户希望"重跑后另开新窗口、老窗口不动"：`Session` 分身 = **另一个 head 指针指向 V₀**（零拷贝，两个引用），而不是复制数据——窗口只是"查看某版本的视图"

### 4.4 递归（子 plan / 节点会话）

```
Plan 的 Run.nodes[nodeId].session = 节点会话的 VersionRef（引用）
节点会话里创建子 plan → 子 plan 是值引用（PlanRef）
子 plan 完成 → 父 plan 节点 run 固化新快照 → 父会话版本更新（递归同一机制）
```

- 递归在**值层面**，不在物理目录层面——没有"递归拷贝"问题（这是用户否定的拷贝方案的根本缺陷）

### 4.5 级联重跑

- 级联 = 沿版本树向上传播的**一连串版本更新**（父 plan 节点重答 → 新 Run → 父会话新版本 → 祖父…）
- 语义与 P39 状态机一致，但载体从"fork 交接"变成"版本派生"——无物理交接、无顺序假设

### 4.6 撤销 / 历史

- `Session.versions` 就是版本树：任何版本可查看（只读）；恢复 = 把 head 切回旧版本（指针操作，零数据操作）
- 若需"基于旧版本继续编辑"（checkout 语义）→ 物化能力（§6.3，开放项）

---

## 5. UI 模型

| 组件 | 现状 | C |
|---|---|---|
| 会话窗口 | 绑定物理实例（血缘解析 head） | 绑定 `(Session.id, versionRef)`；当前 head 可编辑，旧版本只读视图 |
| 状态栏（plan） | `planMetaForMessage → planId → 全局 run 状态` | `Version.planViews[plan]` → run 状态（**版本隔离，核心修复点**） |
| plan 链接 | (conversation, planIndex) → planId | (session 值内 plan 消息) → PlanDef ref；打开窗口显示该版本看到的 run |
| plan 窗口 | 全局唯一窗口（按 planId） | 窗口 = (plan, versionRef) 视图；可显示全部 runs 历史 + 高亮当前版本指针 |
| 重跑结果 | fork 出新窗口 + 血缘 | 当前会话 head 更新（或分身视图）；无窗口跳变 |
| 会话管理器 | 列物理实例 | 列 `Session`（稳定 id）+ 版本数/当前版本标记 |

---

## 6. 存储与后端边界

### 6.1 对象存储（内容寻址，git 式 loose objects）

```
~/.alayaface/objects/<sha>/          # hash → 不可变对象（version / run / plandef / msgblock）
~/.alayaface/sessions/<id>/          # 会话目录（保留给 alayacore 的工作副本）
    session.alaya                    # alayacore 持有 = 当前 head 的工作副本
    session.refs.json                # 前端：id / head 指针 / versions 列表（引用 objects/）
    plans/<planId>/                  # plan 目录
        plan.json                    # PlanDef（不可变，写完不动）
        runs/run-<runId>.json        # Run 快照（不可变，追加）
        index.json                   # runs 列表 + meta（引用）
```

- hash = 内容哈希（sha256），由**后端**计算（Go/Rust 对称，见 C2）
- 前端只持有引用（hash），对象读写走 fs RPC（`object_put` / `object_get`，后端实现，双后端对称）

### 6.2 与 alayacore 的边界（NEVER modify AlayaCore）

- `session.alaya` 仍是 alayacore 的**工作副本**（当前 head 的可变物化）
- 版本边界（plan 完成/重跑/手动存档）：前端把当前工作副本的**消息内容**固化进不可变 `Version`（对象存储）——前端已有完整消息列表（内存），只需在后端落盘
- 查看旧版本：**渲染对象存储里的快照**（只读），不触碰 alayacore
- 继续在当前 head 编辑：alayacore 工作副本照常（消息更新沿用现有 sendPrompt/截断通道，但**截断**改为：物化新版本后，alayacore 侧仍需要真的删消息 → 保留 fork 命令作为"工作副本物化通道"（D2 现状），但**身份层不再需要血缘**——fork 出的文件只是 head 版本的工作副本，不是新身份）

### 6.3 物化（开放项）

"基于旧版本继续编辑"（checkout）需要把旧版本的不可变消息**物化成 session.alaya**：
- 我们的后端可以生成 alayacore 格式（fakecore 已证明格式可读写；真实格式需验证）
- 方案：后端 `materialize_session { versionRef → sessionFile }` 命令（Go/Rust 对称）
- **C 第一版可不做**（旧版本只读即可满足隔离/共享/递归目标）；物化作为 C4 独立组件

---

## 7. 迁移（现有数据）

1. 现有每个会话：把当前 session.alaya + 各 plan 的 meta/run **固化为首个 Version**（planViews 取当时状态）→ `session.refs.json` 初始化
2. 现有血缘（session.meta.json）：**废弃**（不再读写；旧文件可留作存档）
3. fork/head/resolveConversation/lineage 相关代码：**删除**
4. 迁移后所有更新走新模型（版本派生）
5. 验证：现有 e2e（plan/restart/fork/two-plans）改写为版本语义断言

---

## 8. 实施阶段（每阶段可独立验证、可提交）

> 阶段间顺序依赖；每阶段跑全套验证（elm-test / go / cargo / parity / e2e）。

- **C1 — 值类型 + 对象存储** ✅ 已完成
  - `PlanDef`/`Run`/`Version` 类型（Elm）+ 后端 `object_put/get`（Go/Rust 对称 + 测试）
  - `session.refs.json` 编解码；版本固化（plan 完成时把工作副本固化为 Version）
- **C2 — 版本化 plan 状态（本 bug 的核心修复）** ✅ 已完成（C2a）
  - `Version.planViews` + 状态栏/窗口按版本解析
  - 重跑 = 版本派生（老版本保留，老会话显示旧状态）
  - **验证**：用户 bug 场景 e2e（老会话 A 保持未执行）
- **C3 — 递归与级联在值模型下**
  - 节点会话/子 plan 引用版本值；级联 = 版本链传播
  - 删除级联 fork 交接（保留状态机语义，改版本载体）
- **C4 — UI 与历史**
  - 版本浏览（会话管理器显示版本/历史/回退）
  - 物化能力（可选，开放项 §6.3）
- **C5 — 清理**
  - 删血缘 registry / headInstanceFor / resolveConversation / fork 收养
  - 删 P39 相关的兼容补丁；REFACTOR.md 归档到 docs/archive/

---

## 9. 已确认决策（待用户逐条批准，批准后不要改）

| # | 决策 | 状态 |
|---|---|---|
| D1 | **身份稳定**：`Session.id` 稳定（= 创建 id），消灭 conversation/instance 之分与血缘 registry | ✅ 已确认 |
| D2 | **版本即历史**：plan 完成/重跑 = 当前会话 head 更新为新版本；旧版本保留在 `Session.versions`（会话管理器可查看/回退） | ✅ 已确认 |
| D3 | **重跑 = 分支派生 + 同会话另一视图**：从当前 head 派生新版本（结构共享）；"新窗口"= **同一个 Session 的另一个 head 视图**（零拷贝），不创建物理新会话 | ✅ 已确认 |
| D4 | **plan 状态 = 版本内视图**：`Version.planViews[plan]`，同一 plan 在不同版本状态不同（老会话天然显示旧状态） | ✅ 已确认 |
| D5 | **run 不可变追加**：`plan.runs` 只追加；重跑不删旧 run | ✅ 已确认 |
| D6 | **对象存储**：内容寻址（后端 hash），objects/ + refs.json | ✅ 已确认 |
| D7 | **alayacore 边界**：工作副本仍是 alayacore 会话；截断仍走 fork 命令物化工作副本，但**无身份语义**（新文件只是 head 的工作副本，不注册血缘） | ✅ 已确认 |
| D8 | **旧版本只读**：C 第一版不做物化（checkout）；旧版本只读查看 | ✅ 已确认 |
| D9 | **删除**：血缘 registry / headInstanceFor / resolveConversation / fork 收养 / planCascadeFork / replay 标记 / P39 兼容补丁 | ✅ 已确认 |

---

## 10. 开放问题（需用户拍板或后续调研）

1. **窗口模型**：重跑后"老窗口"与"新窗口"如何呈现——同一 Session 的两个 head 视图？还是重跑就在原窗口更新（老版本仅从会话管理器访问）？（影响 D3 的 UX 细节）
2. **版本粒度**：plan 完成才固化版本，还是运行中每个关键点也固化（更大历史/撤销能力，更多存储）？
3. **对象存储压缩**：git 式 pack/GC（长期）；第一版 loose objects 即可
4. **物化格式验证**：真实 alayacore session.alaya 格式是否能由后端生成（C4 前置调研，用真实 binary 验证）

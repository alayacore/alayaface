# Qwen 与 DeepSeek 开源模型在 Mac（Apple Silicon）上的本地部署方案

> 适用对象：Mac 用户（M1 / M2 / M3 / M4 系列芯片）
> 适用范围：在本地运行 Qwen3、Qwen2.5、QwQ、DeepSeek-R1-Distill、DeepSeek-V3/R1 等开源模型

---

## 目录

1. [硬件特性分析](#一硬件特性分析)
2. [工具链对比与选型](#二工具链对比与选型)
3. [按内存分级推荐组合](#三按内存分级推荐组合)
4. [Qwen vs DeepSeek 部署建议差异](#四qwen-vs-deepseek-部署建议差异)
5. [安装与启动关键命令](#五安装与启动关键命令)
6. [Intel Mac 说明](#六intel-mac-说明)
7. [总结与推荐结论](#七总结与推荐结论)

---

## 一、硬件特性分析

### 1.1 统一内存架构（Unified Memory）

Apple Silicon（M 系列芯片）采用 **统一内存架构（UMA）**：CPU、GPU、NPU（神经网络引擎）共享同一物理内存池，无需像传统 PC 那样通过 PCIe 总线在"显存 ↔ 内存"之间拷贝数据。

对本地大模型部署的意义：

| 特性 | 传统 x86 PC（独立显卡） | Apple Silicon（M 系列） |
|---|---|---|
| 显存/内存 | 物理分离（如 8GB 显存 + 32GB 内存） | 完全共享（如 64GB 统一内存） |
| 数据搬运 | 需 PCIe 总线拷贝，有延迟与带宽瓶颈 | 零拷贝，CPU/GPU 直接读写同一块内存 |
| 模型上限 | 受**显存容量**限制（消费级显卡通常 ≤24GB） | 受**整机内存**限制（最高可选 192GB） |
| 能效 | 功耗高（显卡功耗 100–450W） | 极低（整机 30–80W） |

> **结论：在 Mac 上，"内存有多大，模型就能跑多大"。** 没有显存/内存之分，只要模型量化后的体积 + 运行时开销（KV Cache、激活值）不超过内存容量，即可本地运行——这正是 Mac 被 AI 开发者青睐的核心原因。

### 1.2 内存带宽对推理速度的决定性影响

大模型推理属于**内存带宽密集型任务**（每生成一个 token 都要把全部权重读一遍），因此：

```
理论极限速度（token/s） ≈ 内存带宽（GB/s） ÷ 模型权重体积（GB）
```

- 内存带宽越高 → 每秒能读入的权重越多 → 生成速度越快；
- 量化（Q4/Q8）本质上是**减小权重体积**，从而间接提升吞吐；
- 计算（算力 TFLOPS）通常不是瓶颈，**带宽才是决定性因素**。

各代芯片内存带宽一览（官方数据）：

| 芯片 | 内存带宽 | 内存上限 | 备注 |
|---|---|---|---|
| M1 | 68.25 GB/s | 16GB | LPDDR4X |
| M1 Pro | 200 GB/s | 32GB | |
| M1 Max | 400 GB/s | 64GB | |
| M1 Ultra | 800 GB/s | 128GB | 两颗 M1 Max 拼接 |
| M2 | 100 GB/s | 24GB | LPDDR5 |
| M2 Pro | 200 GB/s | 32GB | |
| M2 Max | 400 GB/s | 96GB | |
| M2 Ultra | 800 GB/s | 192GB | 两颗 M2 Max 拼接 |
| M3 | 100 GB/s | 24GB | |
| M3 Pro | 150 GB/s | 36GB | 注意：带宽不升反降（相对 M2 Pro） |
| M3 Max | 300 / 400 GB/s | 128GB | 14 核 GPU 版 300，16 核版 400 |
| M3 Ultra | 800 GB/s | 192GB | |
| M4 | 120 GB/s | 32GB | |
| M4 Pro | 273 GB/s | 48GB | |
| M4 Max | 546 GB/s | 128GB | |

**速度量级参考**（Q4 量化、MLX 引擎，实测典型值）：

| 芯片/带宽 | 7–8B 模型（Q4 ≈ 5GB） | 14B（Q4 ≈ 9GB） | 32B（Q4 ≈ 20GB） |
|---|---|---|---|
| M1（68 GB/s） | 10–15 tok/s | 6–8 tok/s | 不推荐 |
| M2/M3（100 GB/s） | 15–25 tok/s | 9–12 tok/s | 4–5 tok/s |
| M2 Pro/M3 Pro（150–200 GB/s） | 25–35 tok/s | 14–20 tok/s | 7–9 tok/s |
| M1 Max/M2 Max（400 GB/s） | 40–60 tok/s | 25–35 tok/s | 14–18 tok/s |
| M2 Ultra/M4 Max（546–800 GB/s） | 60–90 tok/s | 35–50 tok/s | 20–30 tok/s |

> **结论：Mac 的推理速度上限 = 内存带宽。** 选机器时"带宽 ≥ 容量"同样重要——M3 Pro 容量到 36GB 但带宽仅 150 GB/s，跑大模型的速度反而不如带宽 400 GB/s 的 M1 Max。

### 1.3 为什么"内存容量决定能跑多大模型"

模型运行时的内存占用 ≈ **权重体积 + KV Cache + 激活值 + 系统/应用开销**：

```
权重体积（GB） ≈ 参数量（B）× 每参数比特数 ÷ 8
```

| 模型 | 参数量 | FP16 | Q8 | Q4 |
|---|---|---|---|---|
| Qwen3-4B | 4B | ~8GB | ~4GB | ~2.5GB |
| Qwen3-8B / R1-Distill-7B | 7–8B | ~16GB | ~8GB | ~5GB |
| Qwen3-14B / R1-Distill-14B | 14B | ~28GB | ~14GB | ~9GB |
| Qwen3-32B / QwQ-32B | 32B | ~64GB | ~32GB | ~20GB |
| R1-Distill-70B | 70B | ~140GB | ~70GB | ~40GB |
| Qwen3-235B-A22B（MoE） | 235B | ~470GB | ~235GB | ~130GB |
| DeepSeek-V3/R1 | 671B | ~1.3TB | ~670GB | ~400GB |

量化精度（bits）与质量/体积的权衡：

- **FP16**：质量最高，体积翻倍；
- **Q8（8-bit）**：几乎无损，体积减半；
- **Q4（4-bit）**：轻微损失，体积约 1/4，**本地部署最常用的甜点**；
- **Q3/Q2**：体积更小但质量明显下降，仅在内存紧张时使用。

> **结论：先看内存容量，再定模型与量化档位。** 16GB 与 128GB 机器能跑的模型上限相差近 10 倍（约 8B vs 235B-A22B）。

---

## 二、工具链对比与选型

| 工具 | 底层引擎 | 格式 | 界面 | Apple Silicon 加速 | 适合人群 |
|---|---|---|---|---|---|
| **MLX / mlx-lm** | Apple 官方 MLX 框架 | MLX | 命令行 | ⭐⭐⭐ 最优（CPU+GPU+ANE 协同） | 开发者、追求极致速度 |
| **Ollama** | llama.cpp（Metal） | GGUF | 命令行 + API | ⭐⭐⭐ 优秀 | 绝大多数用户，最省心 |
| **llama.cpp** | 自研 C/C++（Metal） | GGUF | 命令行 | ⭐⭐⭐ 优秀 | 进阶玩家、服务端部署 |
| **LM Studio** | llama.cpp（Metal） | GGUF | 图形界面 | ⭐⭐ 优秀 | 非技术用户、GUI 偏好者 |

### 2.1 MLX / mlx-lm（Apple 官方推荐）

- **优点**：
  - Apple 官方开源框架，专为 Apple Silicon 统一内存设计，CPU/GPU/NPU 协同调度，**实测吞吐通常比 llama.cpp 高 10%–30%**；
  - 支持 LoRA 微调（`mlx_lm.lora`）；
  - Qwen 官方直接发布 MLX 格式权重（Qwen3-MLX 系列），**开箱即用**；
  - 内存占用优化好，同样的模型可跑更大上下文。
- **缺点**：
  - **仅支持 Apple Silicon**（Intel Mac 完全无法使用）；
  - 主要支持 MLX 格式，GGUF 需转换（`mlx_convert`）；
  - 纯命令行，需要 Python 环境，对新手门槛略高。

### 2.2 Ollama（最省心的一站式方案）

- **优点**：
  - `brew install ollama` + `ollama pull` 两步即可运行，模型库丰富（官方自动提供各量化档位）；
  - 底层 llama.cpp + Metal，速度优秀；
  - 自带 OpenAI 兼容 REST API，方便接入各类前端/开发工具；
  - 一条命令启动后台服务（`ollama serve`）。
- **缺点**：
  - 对量化档位、采样参数的控制能力弱于原生 llama.cpp；
  - 内置模型版本更新可能滞后于最新发布；
  - 大模型首次拉取依赖网络，国内需代理或镜像。

### 2.3 llama.cpp（最灵活的开源引擎）

- **优点**：
  - 纯 C/C++，跨平台，GGUF 生态最丰富（HuggingFace 上 GGUF 模型最多）；
  - 支持 `llama-server` 提供 OpenAI 兼容 API、多用户并发；
  - 可精细控制量化（`llama-quantize`）、上下文长度、GPU 层数（`-ngl`）；
  - **Intel Mac 也能运行**（退化为 CPU 推理，速度很慢）。
- **缺点**：
  - 命令行操作，需手动下载 GGUF 文件、配置参数；
  - 需要自己挑选合适的量化版本，踩坑成本略高。

### 2.4 LM Studio（图形界面，新手友好）

- **优点**：
  - 图形界面搜索、下载、运行模型，内置聊天窗口与 OpenAI 兼容服务；
  - 底层同样是 llama.cpp + Metal，无需手写命令；
  - 支持 GGUF 与部分 MLX 模型。
- **缺点**：
  - 闭源（核心引擎开源但产品闭源），高级定制能力受限；
  - 同样依赖 llama.cpp，速度上限与 Ollama 相当。

> **选型结论：**
> - 想**最快最省心** → **Ollama**；
> - 追求**极限速度 + 跑 Qwen 官方 MLX 模型 + 微调** → **mlx-lm**；
> - 需要**精细控制/服务化部署** → **llama.cpp（llama-server）**；
> - **纯小白/偏好图形界面** → **LM Studio**。

---

## 三、按内存分级推荐组合

> 说明：速度为 Q4 量化、MLX 引擎下的**预期量级**（tok/s），实际受芯片带宽、量化档位、上下文长度影响。Q4 体积按实际量化值估算（含少量 KV Cache 余量）。

### 3.1 16GB（M1 / M2 / M3 基础款，带宽 68–100 GB/s）

> 定位：**轻量级本地推理**，适合日常问答、代码补全、翻译。单任务模型 + 系统内存需预留，不适合开超大上下文。

| 推荐模型 | 参数量 | 量化 | 体积约 | 预期速度 | 推荐工具 |
|---|---|---|---|---|---|
| **Qwen3-4B** | 4B | Q4 | ~2.5GB | 30–50 tok/s | Ollama / mlx-lm |
| **DeepSeek-R1-Distill-Qwen-7B** | 7B | Q4 | ~5GB | 12–20 tok/s | Ollama / mlx-lm |
| **Qwen3-8B** | 8B | Q4 | ~5.5GB | 10–18 tok/s | Ollama / mlx-lm |
| DeepSeek-R1-Distill-Qwen-1.5B | 1.5B | Q4 | ~1GB | 60–100 tok/s | Ollama（应急/极速场景） |

> **推荐结论：16GB 首选 `Qwen3-8B（Q4）` 或 `DeepSeek-R1-Distill-Qwen-7B（Q4）`，兼顾质量与速度；若需更快的实时响应（如 Agent/工具调用），用 `Qwen3-4B`。**

### 3.2 32GB（M2/M3 Pro、M2 Max 低配，带宽 150–400 GB/s）

> 定位：**主力日常部署**，可跑 14B 高质量模型，32B 需 Q4 且严格控制上下文。

| 推荐模型 | 参数量 | 量化 | 体积约 | 预期速度 | 推荐工具 |
|---|---|---|---|---|---|
| **Qwen3-14B** | 14B | Q4 | ~9GB | 12–30 tok/s | mlx-lm / Ollama |
| **DeepSeek-R1-Distill-Qwen-14B** | 14B | Q4 | ~9GB | 12–30 tok/s | mlx-lm / Ollama |
| **Qwen3-30B-A3B（MoE）** | 30B（3B 激活） | Q4 | ~18GB | 25–50 tok/s | mlx-lm（MoE 推荐） |
| Qwen3-32B | 32B | Q4 | ~20GB | 6–12 tok/s | mlx-lm（内存偏紧） |
| DeepSeek-R1-Distill-Qwen-32B | 32B | Q4 | ~20GB | 6–12 tok/s | mlx-lm（内存偏紧） |

> **推荐结论：32GB 首选 `Qwen3-14B（Q4）` 与 `R1-Distill-Qwen-14B（Q4）`；追求"大模型 + 快速度"的组合，强烈推荐 MoE 架构的 `Qwen3-30B-A3B（Q4）`（仅 3B 激活，带宽友好，速度快且质量接近 30B 稠密模型）。32B 在 32GB 上内存吃紧，建议上下文 ≤8K。**

### 3.3 64GB（M1/M2/M3 Max，带宽 400 GB/s）

> 定位：**重载工作站**，可跑 32B 高精度、70B 蒸馏模型，兼顾质量与速度。

| 推荐模型 | 参数量 | 量化 | 体积约 | 预期速度 | 推荐工具 |
|---|---|---|---|---|---|
| **Qwen3-32B** | 32B | Q8 | ~32GB | 10–15 tok/s | mlx-lm（带宽 400 时） |
| **Qwen3-32B** | 32B | Q4 | ~20GB | 15–22 tok/s | mlx-lm / Ollama |
| **QwQ-32B（推理模型）** | 32B | Q4 | ~20GB | 15–22 tok/s | mlx-lm / Ollama |
| **DeepSeek-R1-Distill-Qwen-32B** | 32B | Q4 | ~20GB | 15–22 tok/s | mlx-lm / Ollama |
| **DeepSeek-R1-Distill-Llama-70B** | 70B | Q4 | ~42GB | 7–10 tok/s | mlx-lm / Ollama |
| Qwen3-30B-A3B（MoE） | 30B | Q8 | ~30GB | 30–60 tok/s | mlx-lm |

> **推荐结论：64GB 首选 `Qwen3-32B（Q8）`（带宽 400 GB/s 时可流畅运行接近无损精度）；若要更强的推理能力选 `QwQ-32B` 或 `R1-Distill-Qwen-32B`；内存余量充足时可用 `R1-Distill-Llama-70B（Q4）` 挑战更大模型。**

### 3.4 128GB+（M2 Ultra / M4 Max 顶配、M3 Ultra，带宽 546–800 GB/s）

> 定位：**本地大模型极限部署**，可跑 235B MoE 旗舰与 70B 全精度档位。

| 推荐模型 | 参数量 | 量化 | 体积约 | 预期速度 | 推荐工具 |
|---|---|---|---|---|---|
| **Qwen3-235B-A22B（MoE）** | 235B（22B 激活） | Q4 | ~130GB | 25–45 tok/s | mlx-lm（官方 MLX） |
| **Qwen3-235B-A22B（MoE）** | 235B | Q3 | ~95GB | 25–45 tok/s | mlx-lm（128GB 机型更稳） |
| **DeepSeek-R1-Distill-Llama-70B** | 70B | Q5/Q6 | ~48–58GB | 12–20 tok/s | mlx-lm / Ollama |
| Qwen3-32B | 32B | FP16 | ~64GB | 8–12 tok/s | mlx-lm（全精度体验） |
| DeepSeek-V3 / R1（671B） | 671B | Q4 | ~400GB+ | 不现实 | 见下方说明 |

> **推荐结论：128GB+ 机型的终极选择是 `Qwen3-235B-A22B（Q4）`——22B 激活 + 800 GB/s 带宽，可在本地获得接近 API 级质量的推理体验（25–45 tok/s）。**
>
> ⚠️ **关于 DeepSeek-V3/R1（671B）的诚实说明**：其 Q4 量化体积约 400GB，128GB Mac 无法承载（即便 Q2 也需 ~250GB）。在 Mac 上运行 DeepSeek-V3/R1 原版**不现实**，实际可用的"DeepSeek 大模型"是 **R1-Distill 蒸馏系列**（7B/14B/32B/70B）。若必须使用原版 V3/R1，建议：
> - 通过官方 API / 云端 GPU 服务；
> - 或等待未来 256GB+ 统一内存机型 + 激进量化（仍有较大质量损失）。

---

## 四、Qwen vs DeepSeek 部署建议差异

### 4.1 MLX 生态支持度：Qwen 明显更优

- **Qwen 是 MLX 生态的一等公民**：阿里官方在 HuggingFace 发布 `Qwen3-* -MLX` 系列（4B / 8B / 14B / 30B-A3B / 32B / 235B-A22B / Coder 系列），与 Apple MLX 团队保持同步，**格式、量化、LoRA 微调均开箱即用**。
- **DeepSeek 主要依赖社区转换**：R1-Distill 系列由 `mlx-community` 等第三方提供 MLX 4-bit 版本（质量可靠但非官方）；原版 V3/R1 的 MLX 转换体积过大，无实用价值。
- **结论：跑 Qwen 首选 mlx-lm + 官方 MLX 权重；跑 DeepSeek 蒸馏模型，Ollama/llama.cpp（GGUF）生态更成熟、选择更多。**

### 4.2 模型特性带来的部署差异

| 维度 | Qwen 系列（Qwen3/QwQ） | DeepSeek 系列（R1-Distill） |
|---|---|---|
| 官方 MLX 权重 | ✅ 官方提供 | ❌ 仅社区转换 |
| 最佳运行格式 | MLX（mlx-lm） | GGUF（Ollama/llama.cpp） |
| 架构特点 | 含 MoE 版本（30B-A3B、235B-A22B），**内存友好、速度快** | 全部稠密架构（除原版 671B），同参数下内存占用更高 |
| 推理风格 | Qwen3 支持 thinking 模式开关，适合 Agent/工具调用 | R1 系为推理模型，思考链长，**KV Cache 占用大**，需更大上下文预算 |
| 多模态 | Qwen2.5-VL / Qwen3-VL 可本地跑 | DeepSeek 无多模态 |
| 微调 | mlx-lm LoRA 支持完善 | 社区 LoRA 方案存在，但资料较少 |

### 4.3 针对性部署建议

- **Qwen3 MoE 系列（30B-A3B / 235B-A22B）在 Mac 上优势巨大**：激活参数少 → 实际带宽需求低 → 同带宽下吞吐远高于同体积稠密模型，**是 Mac 本地部署的"最优性价比"选择**。
- **DeepSeek R1 系建议开大一点上下文**：思维链（CoT）输出长，建议预留 `上下文 ≥ 16K`，KV Cache 内存按 `2GB / 8K` 量级估算。
- **混合搭配建议**：
  - 日常快答 / 工具调用 → `Qwen3-8B` 或 `Qwen3-30B-A3B`；
  - 深度推理 / 数学 / 逻辑 → `R1-Distill-Qwen-14B/32B` 或 `QwQ-32B`；
  - 中文写作 / 结构化输出 → `Qwen3-14B/32B`。

---

## 五、安装与启动关键命令

### 5.1 安装 Homebrew（如未安装）

```bash
# 在终端执行（需 Rosetta/系统权限，中国区建议使用国内镜像源）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 5.2 Ollama（最推荐，最简单）

```bash
# 1. 安装
brew install ollama

# 2. 启动服务（也可用 ollama app 图形版）
ollama serve

# 3. 拉取模型（Qwen 与 DeepSeek 示例）
ollama pull qwen3:8b              # Qwen3-8B（默认 Q4）
ollama pull qwen3:14b             # Qwen3-14B
ollama pull deepseek-r1:7b        # DeepSeek-R1-Distill-Qwen-7B
ollama pull deepseek-r1:14b       # R1-Distill-Qwen-14B
ollama pull deepseek-r1:32b       # R1-Distill-Qwen-32B
ollama pull qwq:32b               # QwQ-32B

# 4. 运行（交互式对话）
ollama run qwen3:8b

# 5. API 调用（OpenAI 兼容，端口 11434）
curl http://localhost:11434/api/chat -d '{"model":"qwen3:8b","messages":[{"role":"user","content":"你好"}]}'

# 常用管理命令
ollama list          # 查看已安装模型
ollama rm qwen3:8b   # 删除模型
```

### 5.3 mlx-lm（Apple 官方 MLX，追求极致速度）

```bash
# 1. 创建 Python 虚拟环境并安装
python3 -m venv .venv && source .venv/bin/activate
pip install -U mlx-lm

# 2. 命令行生成（Qwen 官方 MLX 权重，首次运行自动下载）
mlx_lm.generate \
  --model Qwen/Qwen3-8B-MLX \
  --prompt "用中文介绍 Mac 本地部署大模型" \
  --max-tokens 512

# 3. 交互式聊天
mlx_lm.generate --model Qwen/Qwen3-8B-MLX --prompt "你好" --interactive

# 4. DeepSeek 蒸馏模型（社区 4-bit MLX 版）
mlx_lm.generate \
  --model mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit \
  --prompt "9.11 和 9.9 哪个大？" --max-tokens 1024

# 5. 指定量化档位拉取（Qwen3 官方 MLX 含 4bit/8bit 版本）
mlx_lm.generate --model Qwen/Qwen3-14B-MLX-4bit --prompt "你好"

# 6. 启动 OpenAI 兼容 API 服务
mlx_lm.server --model Qwen/Qwen3-14B-MLX-4bit --port 8080

# 7. LoRA 微调（进阶）
mlx_lm.lora --model Qwen/Qwen3-8B-MLX --train --data ./train.jsonl
```

> 国内网络下载 HuggingFace 模型较慢，可设置镜像：`export HF_ENDPOINT=https://hf-mirror.com`

### 5.4 llama.cpp（进阶 / 服务端部署）

```bash
# 1. 安装
brew install llama.cpp

# 2. 手动下载 GGUF 模型（以 Qwen3-8B 为例，从 HuggingFace 获取 .gguf 文件）
#    常用仓库：bartowski、Qwen 官方 GGUF、unsloth 等
wget https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/qwen3-8b-q4_k_m.gguf

# 3. 命令行推理（-ngl 999 = 全部层交给 GPU/Metal）
llama-cli -m qwen3-8b-q4_k_m.gguf \
  -p "介绍一下你自己" \
  -n 256 \
  -ngl 999 \
  -t 8

# 4. 启动 OpenAI 兼容服务（推荐）
llama-server -m qwen3-8b-q4_k_m.gguf \
  -ngl 999 \
  --port 8080 \
  --ctx-size 8192

# 5. 验证 API
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3","messages":[{"role":"user","content":"你好"}]}'
```

### 5.5 LM Studio

1. 官网下载安装包（https://lmstudio.ai）或 `brew install --cask lm-studio`；
2. 在图形界面搜索模型并下载（内置 HF 搜索）；
3. 点击加载模型，选择量化档位，直接在聊天窗口使用；
4. "Developer" 页签可开启 OpenAI 兼容本地服务。

### 5.6 常见问题

```bash
# Q: 内存不足 / 被系统 kill
# A: 换更低量化（Q3/Q2）、缩短上下文（-c 4096）、关闭其他大内存应用

# Q: Ollama 下载慢
# A: 设置代理：export HTTPS_PROXY=http://127.0.0.1:7890

# Q: 查看 Metal 是否生效
# A: 运行模型时观察 CPU 占用显著降低、GPU（活动监视器）升高即为 Metal 加速正常
```

---

## 六、Intel Mac 说明

| 工具 | Intel Mac 支持情况 |
|---|---|
| **MLX / mlx-lm** | ❌ **完全不支持**（仅 Apple Silicon，安装即报错） |
| **Ollama** | ⚠️ 可安装，但退化为 **CPU 推理**（无 Metal 加速），速度极慢（7B Q4 约 2–5 tok/s） |
| **llama.cpp** | ⚠️ 可编译运行，同样仅 CPU（Intel 核显/AMD 独显 Metal 支持缺失），仅适合跑 1–4B 小模型 |
| **LM Studio** | ⚠️ 可运行，GPU 加速基本不可用 |

> **结论：Intel Mac 仅建议运行 ≤4B 的小模型做体验，正式使用请升级 Apple Silicon。** 若手头只有 Intel Mac 且必须本地推理，可用 llama.cpp 跑 1.5B–4B 量化模型。

---

## 七、总结与推荐结论

| 内存 | 预算机型 | **首选组合（加粗=推荐）** | 预期速度 |
|---|---|---|---|
| 16GB | M1/M2/M3 基础款 | **Qwen3-8B（Q4）+ Ollama**；R1-Distill-Qwen-7B（Q4） | 10–20 tok/s |
| 32GB | M2/M3 Pro | **Qwen3-14B（Q4）+ mlx-lm**；Qwen3-30B-A3B（Q4） | 12–30 tok/s |
| 64GB | M1/M2/M3 Max | **Qwen3-32B（Q8）+ mlx-lm**；QwQ-32B / R1-Distill-32B（Q4） | 10–22 tok/s |
| 128GB+ | M2 Ultra / M4 Max | **Qwen3-235B-A22B（Q4）+ mlx-lm**；R1-Distill-70B（Q5） | 25–45 tok/s |

**最终推荐结论：**

1. **模型选择**：Mac 本地部署**首选 Qwen 系列**（官方 MLX 权重 + MoE 架构内存友好），DeepSeek 建议使用 **R1-Distill 蒸馏版**（原版 671B 在 Mac 上不现实）。
2. **工具选择**：绝大多数用户直接用 **Ollama**；追求极限速度/微调用 **mlx-lm**；服务化部署用 **llama.cpp（llama-server）**；新手用 **LM Studio**。
3. **量化选择**：默认 **Q4**（体积/质量甜点），内存富余（64GB+）可升级 Q8，128GB+ 可尝试 Qwen3-235B-A22B。
4. **硬件选择**：内存容量决定上限，**内存带宽决定速度**——预算有限时优先保证带宽（Max 系列 > Pro > 基础款）。

---

*文档版本：v1.0　|　适用范围：macOS 14+，Apple Silicon（M1–M4）　|　数据来源：Apple 官方规格、HuggingFace 模型仓库、社区实测*

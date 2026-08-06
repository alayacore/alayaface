# NVIDIA GPU 本地部署 Qwen 与 DeepSeek 开源模型方案指南

> 适用对象：拥有 NVIDIA 显卡（RTX 30/40/50 系列、A 系列/A6000 等）的开发者与个人用户，
> 希望在本地部署 Qwen3 / QwQ / DeepSeek-R1（含 Distill 蒸馏版）等开源模型。
>
> **重要声明**：本文所有显存占用、速度为经验估算值，实际以你的显卡型号、驱动版本、CUDA 版本、
> 上下文长度、量化精度为准。**安装前请务必自行确认驱动 / CUDA 版本与所选框架的兼容性**
> （见第 7 节"环境检查"），驱动过旧会导致 CUDA 运行时错误或性能回退。

---

## 目录

1. [方案总览与快速选型](#1-方案总览与快速选型)
2. [推理工具链对比与选型](#2-推理工具链对比与选型)
3. [量化方案对比](#3-量化方案对比)
4. [显存需求估算速查](#4-显存需求估算速查)
5. [按显存分级的推荐组合](#5-按显存分级的推荐组合)
6. [Qwen vs DeepSeek 在 NVIDIA 平台上的部署差异](#6-qwen-vs-deepseek-在-nvidia-平台上的部署差异)
7. [安装与启动关键命令](#7-安装与启动关键命令)
8. [常见问题与调优建议](#8-常见问题与调优建议)
9. [参考链接](#9-参考链接)

---

## 1. 方案总览与快速选型

一张图式决策逻辑：

| 你的诉求 | 推荐工具 | 推荐模型/量化 |
|---|---|---|
| 开箱即用、不想折腾 | **Ollama** | Qwen3-8B / Qwen3-14B（GGUF Q4_K_M） |
| 轻量单文件、CPU+GPU 混跑、极致可控 | **llama.cpp** | Qwen3 或 R1-Distill 的 GGUF（Q4_K_M / Q5_K_M） |
| 多用户并发、OpenAI 兼容服务、高吞吐 | **vLLM** | Qwen3 / DeepSeek（AWQ 4bit 或 FP8） |
| NVIDIA 官方极致性能（生产级） | **TensorRT-LLM** | Qwen3 / DeepSeek（FP8 / INT4） |
| 复杂推理链、长上下文、Agent 服务 | **SGLang** | Qwen3 / DeepSeek（含 MLA 优化） |

> 一句话结论：**个人单卡日用 → Ollama 或 llama.cpp + GGUF 量化；生产服务 / 多卡 → vLLM 或 SGLang；**
> **追求极限吞吐且愿意折腾编译 → TensorRT-LLM。**

---

## 2. 推理工具链对比与选型

| 工具 | 易用性 | 性能定位 | 显存友好度 | 适用场景 |
|---|---|---|---|---|
| **Ollama** | ★★★★★ 一键安装/拉模型 | 中（内置 llama.cpp 内核） | 高（自动分层加载） | 个人日常对话、快速体验、OpenAI 兼容 API |
| **llama.cpp** | ★★★★ 编译稍费事，运行简单 | 中高（GGUF + CUDA 优化） | 高（支持 CPU/GPU 混合 offload） | 轻量部署、嵌入式、消费级显卡（8~24GB） |
| **vLLM** | ★★★ pip 安装即用，参数多 | 高（PagedAttention + 连续批处理） | 中（专为服务设计，个人单卡偏重） | 多用户并发、高吞吐 API 服务、多卡 TP |
| **TensorRT-LLM** | ★★ 需构建引擎，模型适配慢 | **极高**（NVIDIA 官方极致优化，FP8/INT4） | 中（引擎定制化） | 生产环境、追求极致延迟/吞吐、推理固定模型 |
| **SGLang** | ★★★ pip 安装即用 | 高（RadixAttention，前缀缓存极强） | 中高 | 多轮对话、长上下文、Agent/工具调用、DeepSeek MLA |

**选型建议（加粗为推荐结论）：**

- **8~16GB 消费级单卡、个人使用：首选 Ollama（零配置）；需要精细控制 offload、量化、日志时用 llama.cpp。**
- **24GB+ 单卡且要多用户/服务化：vLLM（生态最全，Qwen/DeepSeek 官方支持）或 SGLang（长上下文/前缀复用更强）。**
- **多卡（2~8 卡）：vLLM / SGLang 的张量并行（tensor parallel）最省心；llama.cpp 也能多卡切层但通信效率一般。**
- **对吞吐/延迟要求苛刻的生产推理：TensorRT-LLM（代价是每次换模型都要重新构建引擎）。**
- 补充：RTX 30/40/50 系无 NVLink 或 NVLink 被砍（4090/5090 均无），多卡跨卡走 PCIe，MoE 类模型要特别注意通信开销（见第 6 节）。

---

## 3. 量化方案对比

| 量化方案 | 每参数字节 | 代表模型体积(8B) | 精度损失 | 速度 | 显存 | 硬件/框架要求 |
|---|---|---|---|---|---|---|
| **GGUF Q4_K_M** | ~0.61 B/参 | ~4.9 GB | 中（日常可用） | 快 | 低 | llama.cpp / Ollama 全系 |
| **GGUF Q5_K_M** | ~0.68 B/参 | ~5.4 GB | 较低 | 较快 | 中低 | llama.cpp / Ollama 全系 |
| **GGUF Q8_0** | ~1.07 B/参 | ~8.5 GB | 很低（接近 FP16） | 中 | 中 | llama.cpp / Ollama 全系 |
| **AWQ**（4bit） | ~0.55 B/参 | ~5.0 GB | 低（激活感知校准） | 高（服务端吞吐优） | 低 | vLLM / SGLang / TensorRT-LLM |
| **GPTQ**（4bit） | ~0.55 B/参 | ~5.0 GB | 低 | 高 | 低 | vLLM / ExLlama / TRT-LLM |
| **FP8 (E4M3)** | 1 B/参 | ~8.0 GB | 极低（近 BF16） | **极高**（硬件加速） | 中 | **仅 RTX 40/50（Ada/Blackwell）及以上有原生支持；RTX 30（Ampere）无 FP8 硬件加速，会回退/变慢** |

**权衡要点（加粗为推荐结论）：**

- **Q4_K_M 是"精度/速度/显存"的黄金平衡点，个人单卡日用无脑选它。**
- **Q8_0 精度接近全精度但体积翻倍，适合显存有富余（如 16GB 跑 14B、24GB 跑 14B/32B）时追求质量。**
- **AWQ / GPTQ 是服务化（vLLM）场景的标准选择：4bit 体积 + 批量吞吐优化。**
- **FP8 只在 RTX 40/50（或 H/A 系列）上才有硬件加速收益，RTX 30 用户请用 AWQ/Q4 而非 FP8。**
- KV Cache 也可量化（Q8/Q4），可显著省显存、换取更长上下文，对质量影响通常可接受（llama.cpp 用 `-ctk q8_0 -ctv q8_0`，vLLM 用 `--kv-cache-dtype fp8`）。

---

## 4. 显存需求估算速查

估算公式：`模型权重 ≈ 参数量 × 每参数字节`，另加 **KV Cache（随上下文长度增长，约 0.5~2 GB@8K）+ 运行时开销（1~2 GB）**。

| 模型 | 参数量 | Q4_K_M | Q5_K_M | Q8_0 | FP8 | BF16/FP16 |
|---|---|---|---|---|---|---|
| Qwen3-4B | 4B | ~2.5 GB | ~2.8 GB | ~4.3 GB | ~4 GB | ~8 GB |
| Qwen3-8B | 8B | ~4.9 GB | ~5.4 GB | ~8.5 GB | ~8 GB | ~16 GB |
| R1-Distill-Qwen-7B | 7B | ~4.3 GB | ~4.8 GB | ~7.5 GB | ~7 GB | ~14 GB |
| Qwen3-14B / R1-Distill-14B | 14B | ~8.6 GB | ~9.5 GB | ~15 GB | ~14 GB | ~28 GB |
| Qwen3-30B-A3B（MoE） | 30B | ~18 GB | ~20 GB | ~32 GB | ~30 GB | ~60 GB |
| Qwen3-32B / QwQ-32B / R1-Distill-32B | 32B | ~19 GB | ~22 GB | ~34 GB | ~32 GB | ~64 GB |
| R1-Distill-Llama-70B | 70B | ~42 GB | ~47 GB | ~75 GB | ~70 GB | ~140 GB |
| Qwen3-235B-A22B（MoE） | 235B | ~141 GB | ~157 GB | ~250 GB | ~235 GB | ~470 GB |
| DeepSeek-R1 / V3 | 671B（MoE，37B 激活） | ~400 GB | ~455 GB | ~718 GB | ~671 GB | ~1342 GB |

> 常见误区纠正：**32B 全精度（BF16）约需 64GB，不是 24GB 单卡能跑的；R1-Distill-70B 的 Q4 约 42GB，24GB 单卡也装不下，需要 48GB 单卡或 2×24GB 双卡。**

---

## 5. 按显存分级的推荐组合

### 5.1 8GB 显存（RTX 4060 / 3060 / 4060 Ti 8G）

| 推荐模型 | 推理工具 | 量化 | 显存占用 | 预期解码速度 |
|---|---|---|---|---|
| Qwen3-4B | Ollama / llama.cpp | Q4_K_M | ~3 GB | 60~100 tok/s |
| **Qwen3-8B** | Ollama / llama.cpp | Q4_K_M | ~5 GB | 30~50 tok/s |
| **DeepSeek-R1-Distill-Qwen-7B** | Ollama / llama.cpp | Q4_K_M | ~4.5 GB | 25~40 tok/s |
| Qwen3-1.7B | Ollama | Q8_0 | ~2 GB | 100+ tok/s（秒回） |

**推荐结论：8GB 首选 Qwen3-8B（Q4_K_M）做日常对话/编程助手；追求极致响应速度用 Qwen3-4B（Q4_K_M）；需要强推理/数学能力选 DeepSeek-R1-Distill-Qwen-7B（Q4_K_M）。上下文建议 ≤8K，避免 KV Cache 挤爆显存。**

### 5.2 12GB 显存（RTX 4070 / 3060 12G / 4060 Ti 16G 亦可参考）

| 推荐模型 | 推理工具 | 量化 | 显存占用 | 预期解码速度 |
|---|---|---|---|---|
| Qwen3-8B | Ollama / llama.cpp | Q5_K_M / Q8_0 | ~5.5~8.5 GB | 40~60 tok/s |
| **Qwen3-14B** | Ollama / llama.cpp | Q4_K_M | ~9 GB | 20~35 tok/s |
| **DeepSeek-R1-Distill-Qwen-14B** | Ollama / llama.cpp | Q4_K_M | ~9 GB | 18~30 tok/s |
| Qwen3-4B | Ollama | FP16 | ~8 GB | 60~90 tok/s |

**推荐结论：12GB 首选 Qwen3-14B（Q4_K_M），容量与质量兼顾，可留出 3GB 给 KV Cache；追求响应速度退回 Qwen3-8B（Q8_0，质量接近全精度）；推理/深度思考场景用 DeepSeek-R1-Distill-Qwen-14B（Q4_K_M）。上下文 ≤16K 舒适。**

### 5.3 16GB 显存（RTX 4080 / 4070 Ti Super / 5080）

| 推荐模型 | 推理工具 | 量化 | 显存占用 | 预期解码速度 |
|---|---|---|---|---|
| **Qwen3-14B** | Ollama / llama.cpp | Q6_K / Q8_0 | ~12~15 GB | 25~40 tok/s |
| DeepSeek-R1-Distill-Qwen-14B | Ollama / llama.cpp | Q6_K / Q8_0 | ~12~15 GB | 20~35 tok/s |
| Qwen3-32B（激进） | llama.cpp | Q4_K_S / Q4_K_M | ~18~19 GB（略超，需低上下文 + KV 量化 + 少量层 offload） | 8~15 tok/s |
| Qwen3-30B-A3B（MoE，激进） | llama.cpp / Ollama | Q4_K_M | ~18 GB（临界，小上下文） | 25~45 tok/s（激活仅 3B） |
| Qwen3-8B | Ollama | FP16 | ~16 GB（紧） | 50~70 tok/s |

**推荐结论：16GB 稳妥之选是 Qwen3-14B（Q6_K 或 Q8_0），质量高且速度快；想上 32B 级可尝试 Qwen3-32B（Q4_K_S + 短上下文 + KV Cache 量化，必要时把末几层放内存，速度会降到 8~15 tok/s）；MoE 尝鲜可选 Qwen3-30B-A3B（Q4，小上下文），解码速度明显快于同显存 Dense 模型。**

### 5.4 24GB 显存（RTX 4090 / 3090 / 4080 Super 16G 用户看 5.3）

| 推荐模型 | 推理工具 | 量化 | 显存占用 | 预期解码速度 |
|---|---|---|---|---|
| **Qwen3-32B** | llama.cpp / Ollama / vLLM | Q4_K_M / Q5_K_M | ~19~22 GB | 15~30 tok/s |
| **QwQ-32B** | llama.cpp / Ollama / vLLM | Q4_K_M / AWQ | ~19 GB | 15~25 tok/s |
| **DeepSeek-R1-Distill-Qwen-32B** | llama.cpp / Ollama / vLLM | Q4_K_M / Q5_K_M | ~19~22 GB | 15~28 tok/s |
| Qwen3-30B-A3B（MoE） | vLLM / llama.cpp | Q5_K_M / Q4_K_M | ~18~21 GB | 25~45 tok/s |
| Qwen3-14B | llama.cpp | Q8_0 | ~15 GB | 40~60 tok/s |

**推荐结论：24GB 是消费级甜点位，首选 Qwen3-32B（Q4_K_M/Q5_K_M），综合能力最强；深度思考/数学推理场景选 QwQ-32B（Q4_K_M）或 DeepSeek-R1-Distill-Qwen-32B（Q4_K_M）；看重速度可换 MoE 的 Qwen3-30B-A3B。注意：QwQ-32B 的"全精度（BF16）"实际需约 64GB 显存，24GB 单卡只能跑量化版；同样 R1-Distill-70B（Q4 约 42GB）在 24GB 单卡装不下，需 48GB 单卡或双卡（见 5.5）。**

### 5.5 48GB+ / 多卡

| 配置 | 推荐模型 | 推理工具 | 量化 | 显存占用 | 预期解码速度 |
|---|---|---|---|---|---|
| 单卡 48GB（RTX A6000 / 6000 Ada / L40S） | **DeepSeek-R1-Distill-Llama-70B** | llama.cpp / vLLM | Q4_K_M / AWQ | ~40~42 GB | 10~18 tok/s |
| 2×24GB（4090×2 / 3090×2） | **DeepSeek-R1-Distill-Llama-70B** | vLLM / llama.cpp | Q4_K_M / AWQ | ~42 GB（TP2 均摊） | 20~35 tok/s |
| 2~3×24GB | Qwen3-32B / QwQ-32B | vLLM | FP8 或 BF16 | FP8 ~32 GB；BF16 ~64 GB（3×24GB） | 30~50 tok/s |
| 6~8×24GB（4090/5090 集群） | **Qwen3-235B-A22B（MoE）** | vLLM / SGLang / llama.cpp | Q4_K_M / AWQ | ~141 GB | 20~40 tok/s |
| 8×80GB（A100/H100 级服务器） | **DeepSeek-R1 / V3（671B MoE）** | vLLM / SGLang / TensorRT-LLM | FP8 或 AWQ 4bit | FP8 ~671 GB；AWQ 4bit ~335~400 GB | 15~40 tok/s |

**推荐结论：**

- **想体验"真·DeepSeek-R1"（671B 原版）需要 8×80GB（A100/H100）级服务器，用 FP8 或 AWQ 4bit 多卡部署；普通消费者不要指望单卡/双卡跑原版 R1。**
- **消费级多卡（6~8×RTX 4090/5090）最合适的目标是 Qwen3-235B-A22B（Q4，约 141GB），22B 激活参数使其速度远快于同体积 Dense 模型。**
- **2×24GB 双卡即可跑 R1-Distill-70B（Q4，约 42GB），是"低预算体验 70B"的最佳入口。**

---

## 6. Qwen vs DeepSeek 在 NVIDIA 平台上的部署差异

| 维度 | Qwen 系列 | DeepSeek 系列 |
|---|---|---|
| 模型形态 | Qwen3：Dense（0.6B~32B）+ MoE（30B-A3B、235B-A22B）；QwQ-32B 为 Dense | R1/V3 原版为 **671B MoE（37B 激活）**；R1-Distill 蒸馏版为 Dense（7B/14B/32B/70B） |
| 显存占用 | Dense 版"总参数量 × 每参数字节"直接对应显存；MoE 版总参数大但激活少 | 原版总参数 671B 极大，**显存占用主要由总参数决定，而非激活参数**；蒸馏版按 Dense 估算 |
| 带宽敏感度 | Dense 模型解码速度 ≈ 显存带宽 / 每 token 加载字节数，带宽越高越快；MoE 版因只加载激活专家，**同等带宽下速度优势明显** | 原版 MoE 每 token 只激活 37B，**解码速度主要受显存带宽 + 多卡通信带宽双重制约**；消费级多卡走 PCIe（无 NVLink）时 All-to-All 专家路由成为瓶颈 |
| 多卡通信 | 32B 及以下单卡即可；235B-A22B 多卡 TP 时专家通信量大，建议同机箱 + 大 PCIe 带宽 | 原版 671B 必须多卡；**vLLM/SGLang 的 expert parallel 对 PCIe/NVLink 拓扑敏感，建议 8 卡同节点部署** |
| 注意力机制 | Qwen3 用 GQA，KV Cache 已压缩，对长上下文友好 | 原版用 **MLA（多头潜在注意力）**，KV Cache 极小、长上下文成本低，但需要 vLLM/SGLang 专门实现（llama.cpp 0.4.x+ 才逐步支持） |
| 思考模式 | Qwen3 支持可控 thinking（`think` 标签可开/关），关闭后更快更省显存 | R1 固定输出思考链，token 更长、耗时更多 |
| 工具链成熟度 | llama.cpp / vLLM / SGLang / TensorRT-LLM 全系支持成熟，GGUF 生态完整 | Distill 版与 Qwen/Llama 同构、支持成熟；原版 R1 建议 vLLM/SGLang/TRT-LLM（FP8 优化），GGUF 也有但文件巨大 |
| NVIDIA 特有优化 | FP8 可跑（RTX 40/50）；TRT-LLM 官方模型库有 Qwen3 | 原版 R1 在 TRT-LLM/vLLM 的 FP8 加速收益显著（RTX 40/50、A/H 卡）；RTX 30 无 FP8 硬件加速，用 AWQ 4bit |

**部署建议差异（加粗为推荐结论）：**

- **个人单卡（≤24GB）：DeepSeek 一律选 R1-Distill 蒸馏版（Dense，好部署），不要碰原版 R1；Qwen 选 Qwen3 对应尺寸即可。**
- **MoE 模型（Qwen3-235B-A22B / DeepSeek 原版）对显存带宽极度敏感：优先选带宽高的卡（RTX 4090/5090 > 3090 > 4070 Ti Super > 4060），多卡时优先同节点、避免跨节点。**
- **DeepSeek 原版务必用 vLLM / SGLang（MLA 优化），llama.cpp 兼容性次之；Qwen3 则工具随意。**
- **长上下文场景：DeepSeek 原版 MLA 省 KV Cache 是优势；Qwen3 建议配合 KV Cache 量化使用。**

---

## 7. 安装与启动关键命令

> ⚠️ **以下命令中涉及的驱动 / CUDA 版本请用户自行确认：**
> `nvidia-smi` 输出的 Driver Version 必须 ≥ 框架要求的 CUDA 对应驱动（例如 CUDA 12.4 通常需驱动 ≥ 550），
> 且显卡 Compute Capability 需满足框架要求（RTX 30=8.0 / RTX 40=8.9 / RTX 50=12.0）。

### 7.1 环境检查

```bash
nvidia-smi                        # 查看 GPU 型号、显存、Driver 版本、最高支持 CUDA 版本
nvcc --version                    # 查看已安装的 CUDA Toolkit 版本（未装则跳过）
python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
```

### 7.2 Ollama（最省心）

```bash
# 安装（Linux）
curl -fsSL https://ollama.com/install.sh | sh

# 拉取并运行模型（GGUF 量化由 Ollama 自动管理）
ollama pull qwen3:4b        # Qwen3-4B
ollama pull qwen3:8b        # Qwen3-8B
ollama pull qwen3:14b       # Qwen3-14B
ollama pull qwen3:32b       # Qwen3-32B
ollama pull deepseek-r1:7b  # DeepSeek-R1-Distill-Qwen-7B
ollama pull deepseek-r1:14b # DeepSeek-R1-Distill-Qwen-14B
ollama pull qwq             # QwQ-32B

ollama run qwen3:8b "你好，请介绍一下你自己"
ollama run deepseek-r1:14b "解一道微积分题：∫x²dx"

# 常用环境变量（按需设置）
OLLAMA_NUM_GPU=999          # 强制全部层上 GPU
OLLAMA_CONTEXT_LENGTH=8192  # 上下文长度

# OpenAI 兼容 API（默认 11434 端口）
ollama serve
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3:8b","messages":[{"role":"user","content":"hi"}]}'
```

### 7.3 llama.cpp（轻量可控，需自行编译 CUDA 版本）

```bash
# 克隆并编译（需 CMake ≥ 3.22、CUDA Toolkit）
git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=native
cmake --build build --config Release -j

# 下载 GGUF（以 Qwen3-8B 为例，也可从 HF 的 Qwen/Qwen3-*-GGUF 仓库下载）
huggingface-cli download Qwen/Qwen3-8B-GGUF \
  --include "Qwen3-8B-Q4_K_M.gguf" --local-dir ./models

# 命令行推理（-ngl 99 = 全部层上 GPU；-c 上下文长度）
./build/bin/llama-cli -m ./models/Qwen3-8B-Q4_K_M.gguf \
  -p "你好" -ngl 99 -c 8192

# 启动 OpenAI 兼容服务（默认 8080 端口）
./build/bin/llama-server -m ./models/Qwen3-8B-Q4_K_M.gguf \
  -ngl 99 -c 8192 --host 0.0.0.0 --port 8080

# KV Cache 量化省显存（8B 模型 16K 上下文也不怕）
./build/bin/llama-cli -m model.gguf -ngl 99 -c 16384 -ctk q8_0 -ctv q8_0
```

### 7.4 vLLM（高吞吐服务化）

```bash
pip install vllm          # 需 Python 3.9+，Linux 首选；Windows 建议 WSL2

# 直接部署 HuggingFace 模型（自动下载权重）
vllm serve Qwen/Qwen3-8B --max-model-len 8192

# AWQ 4bit 量化（省显存 + 高吞吐，服务场景首选）
vllm serve Qwen/Qwen3-8B-AWQ --quantization awq --max-model-len 8192

# FP8（仅 RTX 40/50 或 A/H 卡；RTX 30 不支持会报错/回退）
vllm serve Qwen/Qwen3-32B --dtype float8_e4m3fn --max-model-len 16384

# 多卡张量并行（TP=卡数）
vllm serve deepseek-ai/DeepSeek-R1-Distill-Qwen-14B --tensor-parallel-size 2

# 原版 DeepSeek-R1（671B，需 8×80GB 级服务器）
vllm serve deepseek-ai/DeepSeek-R1 --tensor-parallel-size 8 \
  --max-model-len 32768 --enable-prefix-caching
```

### 7.5 SGLang（长上下文 / Agent 场景）

```bash
pip install "sglang[all]"

python -m sglang.launch_server \
  --model-path Qwen/Qwen3-32B --tp-size 2 --port 30000

python -m sglang.launch_server \
  --model-path deepseek-ai/DeepSeek-R1-Distill-Qwen-14B --tp-size 2

# 原版 DeepSeek（MLA 优化，多卡）
python -m sglang.launch_server \
  --model-path deepseek-ai/DeepSeek-R1 --tp-size 8
```

### 7.6 TensorRT-LLM（极致性能，构建较繁琐）

```bash
pip install tensorrt-llm

# 1) 转换/量化权重生成模型配置
# 2) 构建引擎（以 Qwen3-8B FP8 为例，命令因版本略有差异）
trtllm-build --model_config ./qwen3-8b-fp8-config.json \
  --output_dir ./qwen3-8b-engine --gemm_plugin auto

# 3) 启动服务
trtllm-serve --model_dir ./qwen3-8b-engine --port 8000
```

### 7.7 多卡显存拆分（llama.cpp 双卡示例）

```bash
./build/bin/llama-cli -m ./models/R1-Distill-Llama-70B-Q4_K_M.gguf \
  -ngl 99 --split-mode layer --main-gpu 0 -c 8192
```

---

## 8. 常见问题与调优建议

| 症状 | 原因 | 解决 |
|---|---|---|
| CUDA error: out of memory | 模型/上下文超显存 | 降量化（Q8→Q5→Q4）、缩短 `-c` 上下文、KV Cache 量化（`-ctk q8_0`）、降低 `-ngl` 把部分层放内存、换小模型 |
| 速度远低于预期 | 部分层被 offload 到 CPU（看日志 "offloaded X/Y layers to CPU"）；或编译时未指定正确 GPU 架构 | 确认 `-ngl 99` / `OLLAMA_NUM_GPU=999`；llama.cpp 用 `-DCMAKE_CUDA_ARCHITECTURES=native` 重编；检查 `ollama ps` 确认模型在 GPU 上 |
| FP8 相关报错或巨慢 | RTX 30（Ampere）无原生 FP8 硬件加速 | 改用 AWQ/GPTQ 4bit 或 GGUF Q4_K_M；只有 RTX 40/50 及以上才建议 FP8 |
| vLLM 在 Windows 装不上/不稳定 | vLLM 官方主要支持 Linux | 用 WSL2 或 Docker（`nvidia/cuda:12.x-devel` 镜像），或换 Ollama/llama.cpp（有 Windows 原生版） |
| 长上下文 OOM 或极慢 | KV Cache 随长度线性增长 | 量化 KV Cache（Q8）、降低 `max-model-len`、换 MLA 的 DeepSeek 或 GQA 的 Qwen3 |
| 多卡速度不随卡数线性提升 | 消费级无 NVLink，跨卡走 PCIe 通信 | 用 vLLM/SGLang 的 TP；MoE 模型避免跨节点；优先同机箱多卡 |
| 显存有富余但效果一般 | 量化过低（Q2/Q3） | 显存够就升 Q5_K_M/Q8_0，或换更大模型 |
| 想跑"DeepSeek-R1 原版" | 671B 需要 ~400GB+ | 现实路径：R1-Distill-32B/70B，或多卡服务器 FP8/AWQ 部署 |

---

## 9. 参考链接

- Ollama：https://ollama.com （模型列表：https://ollama.com/library/qwen3、/deepseek-r1、/qwq）
- llama.cpp：https://github.com/ggml-org/llama.cpp
- vLLM：https://docs.vllm.ai
- SGLang：https://docs.sglang.ai
- TensorRT-LLM：https://github.com/NVIDIA/TensorRT-LLM
- Qwen3 模型仓库：https://huggingface.co/Qwen （GGUF：`Qwen/Qwen3-8B-GGUF` 等）
- DeepSeek-R1：https://huggingface.co/deepseek-ai/DeepSeek-R1
- NVIDIA 驱动下载：https://www.nvidia.com/drivers （请按显卡型号自行确认版本）
- CUDA Toolkit：https://developer.nvidia.com/cuda-toolkit

---

*文档版本：v1.0 · 面向 NVIDIA GPU（RTX 30/40/50 与 A 系列）· 所有命令与参数请以官方最新文档为准。*

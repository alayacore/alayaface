# Qwen / DeepSeek 开源模型 AMD GPU 本地部署方案

> 适用对象：使用 AMD 消费级显卡（Radeon RX 6000/7000 系列）或 Radeon Pro 系列，希望在本地部署 Qwen 系列与 DeepSeek 系列开源模型的技术人员。
>
> 核心结论速览：
> - **RX 7000 系列（RDNA3）在 Linux 上是 AMD 本地部署的首选平台，官方 ROCm 支持最完整；RX 6000 系列（RDNA2）不被官方支持，需靠 `HSA_OVERRIDE_GFX_VERSION` 兼容层运行，稳定性有风险。**
> - **Windows 上 AMD 生态远弱于 Linux：ROCm 仅限"预览"且只覆盖 7900 系等少数卡，强烈建议 Windows 用户走 Vulkan 路线（LM Studio / llama.cpp Vulkan 后端），或改用 WSL2/双系统。**
> - **个人玩家首选工具为 Ollama（ROCm 版）与 llama.cpp（HIP/Vulkan 后端）；追求吞吐与批量推理选 vLLM（仅限 Linux）；追求开箱即用选 LM Studio（Vulkan）。**
> - **显存 24GB（RX 7900 XTX/XT）是消费级"甜点"，可跑 Qwen3-32B / R1-Distill-32B / QwQ-32B 的 Q4 量化；MoE 模型（Qwen3-30B-A3B）在 AMD 上建议优先用 llama.cpp HIP 后端。**

---

## 1. 硬件特性与生态现状

### 1.1 ROCm / HIP 对消费级显卡的支持矩阵

ROCm 是 AMD 的开源计算栈，HIP 是其在 GPU 上执行 kernel 的编程接口（CUDA 的对应物）。ROCm 的"官方支持"分三层：数据中心卡（Instinct）→ 工作站专业卡（Radeon Pro）→ 消费级卡（Radeon RX，多为社区驱动 / 部分官方支持）。

| GPU 型号 | 架构代号 | gfx target | 显存 | Linux ROCm 官方支持 | Windows ROCm 支持 |
|---|---|---|---|---|---|
| RX 7600 / 7600 XT | RDNA3 (Navi 33) | gfx1102 | 8GB / 16GB | ✅ ROCm 6.0+ 官方支持 | ⚠️ 受限（非官方推荐） |
| RX 7700 XT / 7800 XT | RDNA3 (Navi 32) | gfx1101 | 12GB / 16GB | ✅ ROCm 6.0+ 官方支持 | ⚠️ 受限（非官方推荐） |
| RX 7900 GRE | RDNA3 (Navi 31) | gfx1100 | 16GB | ✅ ROCm 5.7+ 官方支持 | ⚠️ 预览支持 |
| RX 7900 XT | RDNA3 (Navi 31) | gfx1100 | 20GB | ✅ ROCm 5.7+ 官方支持 | ⚠️ 预览支持 |
| RX 7900 XTX | RDNA3 (Navi 31) | gfx1100 | 24GB | ✅ ROCm 5.7+ 官方支持 | ⚠️ 预览支持 |
| Radeon Pro W7800 / W7900 | RDNA3 (Navi 31) | gfx1100 | 32GB / 48GB | ✅ 官方支持（专业卡） | ✅ 官方支持 |
| RX 6600 / 6600 XT | RDNA2 (Navi 23) | gfx1032 | 8GB | ❌ 不支持（override 也易崩） | ❌ |
| RX 6700 XT / 6750 XT | RDNA2 (Navi 22) | gfx1031 | 12GB | ❌ 需 `HSA_OVERRIDE_GFX_VERSION=10.3.0` | ❌ |
| RX 6800 / 6800 XT / 6900 XT | RDNA2 (Navi 21) | gfx1030 | 16GB | ❌ 需 `HSA_OVERRIDE_GFX_VERSION=10.3.0`（社区可用） | ❌ |
| Radeon Pro W6800 / W6900 | RDNA2 (Navi 21) | gfx1030 | 32GB | ✅ 官方支持（专业卡） | ✅ 官方支持 |
| RX 5700 XT 及更早（GCN/RDNA1） | — | gfx1010 及以下 | — | ❌ ROCm 5.7+ 已放弃 | ❌ |

**要点解读：**

1. **Linux 是 AMD 推理的主战场。** RDNA3（gfx1100/1101/1102）自 ROCm 5.7/6.0 起进入官方支持名单，配合 AMD 官方仓库的驱动（amdgpu-dkms + rocm）即可获得接近 CUDA 的体验。
2. **RDNA2 是被官方"遗忘"的一代。** RX 6000 消费卡与 W6800 专业卡同芯片（gfx1030），但 AMD 只对专业卡提供支持；消费卡必须设置 `HSA_OVERRIDE_GFX_VERSION=10.3.0` 欺骗运行库，部分算子（如某些 attention kernel）仍可能崩溃。
3. **ROCm 5.7 之后不再支持 GCN（Vega/北极星）与 RDNA1。** 老卡（RX 5700 XT、Vega 56/64）在 ROCm 下已无路可走，只能走 Vulkan。
4. **Windows 的 ROCm 只是"预览"。** 官方 Windows 支持列表基本限定在 Radeon Pro 与 7900 系；Ollama / vLLM 在 Windows 上的 AMD 支持更晚、更不稳定。**Windows 用户请直接拥抱 Vulkan。**

### 1.2 Vulkan 作为通用后备方案的可行性

Vulkan 是跨厂商图形/计算 API，AMD 在所有 RDNA（乃至 GCN）显卡上提供完整驱动（Windows 与 Linux 皆然），且**不需要安装 ROCm、不区分"官方支持名单"**。

- **可行性：非常高。** llama.cpp 的 Vulkan 后端、LM Studio 默认即用 Vulkan，任何能被驱动枚举到的 AMD 显卡（包括 RDNA1、RDNA2、RDNA3）都能跑 GGUF 量化模型。
- **性能：可用但非最优。** Vulkan 后端比 HIP 后端通常慢约 10%–25%（取决于算子与 MoE 占比），且对显存管理不如 HIP 精细（层全部常驻显存，无 CPU 混合卸载的精细控制）。**但换来的兼容性是无价的：Windows 上跑 AMD 推理，Vulkan 就是默认答案。**
- **结论：** Vulkan 适合"能跑就行"、老卡、Windows 用户；追求性能与 24GB 卡的极限压榨，用 HIP/ROCm。

---

## 2. 工具链对比与选型

| 工具 | AMD 后端 | Linux 支持 | Windows 支持 | AMD 成熟度 | 主要坑 |
|---|---|---|---|---|---|
| **Ollama（ROCm 版）** | HIP（自带 ROCm 运行库） | ✅ 自动检测 | ⚠️ 仅部分 7900 系 | ★★★★☆ | 内置 ROCm 版本滞后；RDNA2 需 override；无官方包时可能回退 CPU |
| **llama.cpp（HIP）** | HIP | ✅ 需自行装 ROCm 编译 | ⚠️ 可编译但配置繁琐 | ★★★★☆ | 需 `-DAMDGPU_TARGETS` 匹配；编译耗时长；ROCm 版本需 ≥ 5.7 |
| **llama.cpp（Vulkan）** | Vulkan | ✅ | ✅ | ★★★★☆ | 比 HIP 慢；老版本 MoE 支持不佳，需用新版 |
| **vLLM（ROCm）** | HIP | ✅ 仅 Linux | ❌ | ★★★☆☆ | 需匹配 PyTorch ROCm 构建；flash-attention 在消费卡上折腾；MoE 内存碎片 |
| **LM Studio** | Vulkan（AMD 默认） | ✅ | ✅ | ★★★★☆ | 图形界面、无脚本化 API 友好度一般；性能非最优；底层仍封装 llama.cpp |

### 2.1 各工具细节与已知坑

**Ollama（ROCm 版）**
- 官方安装脚本在 Linux 上会自动检测 AMD GPU 并安装带 ROCm 运行库的版本（约 1–2GB 的 rocm 库随包分发，无需单独装 ROCm 全家桶）。
- **坑 1：内置 ROCm 版本滞后。** Ollama 打包的 ROCm 可能落后最新版，对新卡（如刚发布的 RDNA3 衍生卡）支持不及时，此时需等更新或改用 llama.cpp。
- **坑 2：RDNA2 必须设置 `HSA_OVERRIDE_GFX_VERSION=10.3.0`**，且要保证该环境变量同时作用于 `ollama serve` 与 `ollama run`（推荐写入 systemd 或 shell profile）。
- **坑 3：Windows 版 Ollama 的 AMD 支持只覆盖少量卡**，且早期版本存在 ROCm 库缺失导致静默回退 CPU 的问题（`ollama ps` 能看到显存占用为 0 即中招）。
- 优点：一条命令拉模型、自动量化（`q4_K_M` 默认）、`OLLAMA_HOST` 暴露 OpenAI 兼容 API，最适合入门。

**llama.cpp**
- HIP 后端：需先装 ROCm（含 hip-dev / rocm-dev），`cmake -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1100` 编译。**坑：`AMDGPU_TARGETS` 必须与你显卡的 gfx target 完全匹配**，否则运行时报 "no kernel image is available"；RDNA2 编译时用 `gfx1030` 并运行时加 override。
- Vulkan 后端：`cmake -DGGML_VULKAN=ON`，依赖 vulkan-sdk/驱动，无需 ROCm。**坑：老版本对 MoE 模型支持差，务必用最新 master 或 ≥ b4000 系列版本。**
- 支持 `-ngl` 逐层卸载、`--split-mode` 多卡、`llama-server` 提供 OpenAI 兼容 API，是**可控性最强**的路线。

**vLLM（ROCm）**
- 仅 Linux。官方提供 ROCm docker 镜像（`rocm/vllm`）与 pip 轮子；对消费卡（gfx1100）需从源码编译（`VLLM_TARGET_DEVICE=rocm`），官方 CI 主要验证 Instinct MI 系列。
- **坑 1：PyTorch 必须是 ROCm 构建**（`pip install torch --index-url https://download.pytorch.org/whl/rocm6.x`），且与系统 ROCm 大版本一致，否则疯狂报错。
- **坑 2：flash-attention**。gfx1100 上需 `VLLM_ATTENTION_BACKEND=FLASHINFER` 或 `FLASH_ATTENTION`（需额外编译），否则退回慢速 kernel。
- **坑 3：MoE 模型的显存碎片与 expert 调度**在 AMD 上比 NVIDIA 更容易爆显存，建议调小 `--max-num-seqs` 与 `--gpu-memory-utilization`。
- 定位：**只有"高吞吐批量推理 / 服务化"需求才选 vLLM；个人单机对话用它属于自找麻烦。**

**LM Studio**
- 图形界面，内置 GGUF 下载、量化选择、聊天与本地 API；AMD 上默认走 Vulkan，**Windows 用户的第一推荐**。
- 坑：底层仍封装 llama.cpp，MoE 模型记得手动更新到最新版内核；无 Docker/无 headless 场景支持。

### 2.2 选型决策树

- 想省事、第一次玩 → **Ollama（Linux）或 LM Studio（Windows）**
- 想要最高性能 + 可控性 → **llama.cpp HIP 后端（Linux + RDNA3）**
- 兼容性优先、老卡/Windows → **llama.cpp Vulkan 后端 / LM Studio**
- 生产服务、批量推理、多卡 → **vLLM（ROCm，Linux）**

---

## 3. 按显存分级的推荐组合

> 说明：模型体积按 GGUF `Q4_K_M` 量化估计（含少量 KV cache 余量）；实际占用随上下文长度浮动。以下标注 **加粗** 的是推荐结论。

### 3.1 8GB 显存（如 RX 7600）

**推荐组合：**

| 模型 | 量化 | 模型文件大小 | 推荐工具 | 说明 |
|---|---|---|---|---|
| **Qwen3-4B** | Q4_K_M | ≈ 2.6GB | Ollama / llama.cpp Vulkan | 轻量、支持 thinking 模式，留足上下文 |
| **Qwen3-8B** | Q4_K_M | ≈ 5.1GB | Ollama / llama.cpp | 8GB 下的"性价比甜点"，注意留出 KV cache |
| **DeepSeek-R1-Distill-Qwen-7B** | Q4_K_M | ≈ 4.7GB | llama.cpp / Ollama | 推理风格强，显存余量尚可 |
| Qwen2.5-7B-Instruct | Q4_K_M | ≈ 4.4GB | LM Studio（Windows） | 老牌稳定，Windows 友好 |

- **8GB 卡不要尝试 14B 及以上的 Q4 模型**（≈9GB 超出显存，被迫大幅 CPU 卸载后速度不可用）。
- 工具首选 **Ollama**（Linux）或 **LM Studio**（Windows）；RX 7600 是 gfx1102，ROCm 6.0+ 官方支持，但 Windows 下仍建议 Vulkan。

### 3.2 16GB 显存（如 RX 7800 XT / RX 6800）

**推荐组合：**

| 模型 | 量化 | 模型文件大小 | 推荐工具 | 说明 |
|---|---|---|---|---|
| **Qwen3-14B** | Q4_K_M | ≈ 9.0GB | Ollama / llama.cpp HIP | 16GB 的"主力选手"，8K 上下文无压力 |
| **DeepSeek-R1-Distill-Qwen-14B** | Q4_K_M | ≈ 9.0GB | llama.cpp HIP | 推理质量明显优于 7B 蒸馏版 |
| Qwen3-8B | Q8_0 | ≈ 8.5GB | llama.cpp | 追求精度时的高质量选择 |
| Qwen2.5-Coder-14B | Q4_K_M | ≈ 9.0GB | llama.cpp | 代码场景替代项 |

- **32B 级模型（Q4 ≈ 20GB）在 16GB 卡上放不下，不要强行上**；如确实想尝鲜，可试 Q3/Q2 量化但质量损失明显，不推荐。
- RX 6800 属 RDNA2（gfx1030），**必须加 `HSA_OVERRIDE_GFX_VERSION=10.3.0`**；RX 7800 XT（gfx1101）ROCm 6.0+ 官方支持，体验更好。

### 3.3 24GB 显存（如 RX 7900 XTX / XT / GRE、W7900）

**这是消费级 AMD 部署的"甜点区间"，推荐组合：**

| 模型 | 量化 | 模型文件大小 | 推荐工具 | 说明 |
|---|---|---|---|---|
| **Qwen3-32B** | Q4_K_M | ≈ 19.5GB | llama.cpp HIP / Ollama | 24GB 首选，通用能力/思考链俱佳 |
| **DeepSeek-R1-Distill-Qwen-32B** | Q4_K_M | ≈ 20.0GB | llama.cpp HIP | 单卡可跑的"最强推理风格" |
| **QwQ-32B** | Q4_K_M | ≈ 19.8GB | llama.cpp HIP / vLLM(可选) | 深度推理模型，需较大 KV cache，上下文别拉满 |
| **Qwen3-30B-A3B（MoE）** | Q4_K_M | ≈ 18.5GB | llama.cpp HIP（新版 Vulkan 亦可） | 仅 3B 激活参数，24GB 单卡推理速度极快 |
| Qwen3-14B | Q8_0 | ≈ 15.5GB | llama.cpp | 高精度场景 |

- **工具首选 llama.cpp HIP 后端**（gfx1100 是 ROCm 支持最完善的消费级 target）；Ollama 亦可，胜在省事。
- **vLLM 在 24GB 消费卡上也能跑**，但需自行编译 + 处理 flash-attention，个人用户收益有限；除非要并发服务，否则不推荐。
- W7900（48GB）可直接上 Qwen3-32B 的 Q8 或两个 32B 模型，甚至 QwQ-32B 开满上下文。

### 3.4 多卡 / 工作站：DeepSeek-V3 / R1 量化部署注意点

DeepSeek-V3/R1 本体为 671B 参数的 MoE（37B 激活），量化后体积仍然巨大：

| 量化档位 | 体积（约） | 最少显存需求 | 说明 |
|---|---|---|---|
| Q4_K_M | ≈ 404GB | 8×24GB（192GB）仍不够 | 消费级基本不可行 |
| UD-IQ2_XS / Q2_K_XS | ≈ 230–260GB | 8×24GB + 大量 CPU 卸载 | 需配合大内存（≥256GB）与高速 NVMe |
| IQ1 / Q1 实验量化 | ≈ 130–160GB | 6×24GB 或 4×48GB | 质量损失显著 |

**多卡部署注意点（AMD 平台）：**

1. **消费卡没有 NVLink/NVSwitch，PCIe 带宽是硬瓶颈。** 4×RX 7900 XTX 的多卡扩展效率远低于同配置 NVIDIA，MoE 的 expert 分发对互联带宽极敏感，**实测 PCIe 4.0 x16 多卡扩展效率通常只有 60%–80%**。
2. **AMD 多卡通信用 RCCL（ROCm 版 NCCL）**，vLLM 多卡需正确安装 `rccl` 并保证 `ROCR_VISIBLE_DEVICES`/`HIP_VISIBLE_DEVICES` 显式指定卡序；llama.cpp 多卡走 `--split-mode layer`（按层切分），比 tensor 并行更稳。
3. **MoE 在 AMD 上的表现：** MoE 的"激活参数少、权重常驻显存"特性放大了显存带宽需求（RX 7900 XTX 约 960GB/s，仅约为 RTX 4090 的 70%），**单卡 MoE（Qwen3-30B-A3B）没问题，671B 级 MoE 多卡则受带宽拖累明显**。
4. **务实建议：** 工作站/多卡场景若目标是 671B DeepSeek，**首选 2×MI300X（192GB×2）或 8×MI210/250 等 Instinct 平台**；消费级多卡跑 671B 属于"能跑但性价比极差"，**更推荐部署 R1-Distill-32B / QwQ-32B 等"单卡可达"的推理级模型**。
5. **务必用 GGUF 分片（llama.cpp）或 vLLM 官方 ROCm 镜像**，避免自己拼装的 wheel 在 AMD 多卡上出现 RCCL 初始化失败。

---

## 4. Qwen vs DeepSeek 在 AMD 平台上的部署差异

**模型结构差异（决定 AMD 适配难度）：**

| 维度 | Qwen 系列 | DeepSeek 系列 |
|---|---|---|
| 主流开源形态 | Qwen3 系列含 Dense（4B~32B）与 MoE（30B-A3B、235B-A22B） | R1/V3 本体为 671B MoE；R1-Distill 为 Qwen/Llama 架构 Dense |
| 激活参数占比 | Dense：100%；MoE：约 10% | 约 5.5%（37B/671B） |
| 显存带宽敏感度 | Dense 中等；MoE 高 | 极高（权重常驻、expert 频繁调度） |
| AMD 部署难度 | Dense 低；30B-A3B 中 | Distill（Dense）低；671B 本体极高 |
| 量化生态 | GGUF/AWQ 齐全 | 本体以 GGUF（UD 系列）/ FP8 为主，Distill 与 Qwen 同生态 |

**关键结论（加粗）：**

- **在 AMD 上，Dense 模型（Qwen3-4B~32B、R1-Distill-7B/14B/32B、QwQ-32B）是"体验最可预期"的选择**——它们在 llama.cpp HIP/Vulkan 与 Ollama 上均运行良好，量化与上下文配置成熟。
- **MoE 模型在 AMD 上"能跑但要看后端"：llama.cpp HIP 后端对 MoE 支持成熟，Vulkan 后端需用最新版（否则 expert 路由成为性能黑洞）；vLLM 跑 MoE 需处理显存碎片。**
- **Qwen3-30B-A3B（3B 激活）是 AMD 单卡（24GB）跑 MoE 的最佳实践**：激活小、推理快，且 18.5GB 的 Q4 体积恰好塞进 7900 XTX。
- **DeepSeek-R1-Distill 系列因架构就是 Qwen/Llama，在 AMD 上的行为与 Qwen 完全一致**，无需特殊对待；真正"特殊"的只有 671B 本体，其部署难度与成本（见 3.4 节）在 AMD 消费平台上通常不划算。
- **R1 本体的"思考链"优势，用 QwQ-32B 或 R1-Distill-32B 在单卡 24GB 上即可获得 90% 的体验**，这是 AMD 消费级用户的最优取舍。

---

## 5. 安装与启动关键命令

### 5.1 ROCm 安装要点（Linux / Ubuntu）

```bash
# 1) 添加 AMD 官方仓库并安装（以 ROCm 6.2 / Ubuntu 22.04 为例）
wget https://repo.radeon.com/amdgpu-install/6.2/ubuntu/jammy/amdgpu-install_6.2.60200-1_all.deb
sudo apt install -y ./amdgpu-install_6.2.60200-1_all.deb
sudo amdgpu-install --usecase=rocm

# 2) 验证 GPU 被识别（应看到 gfx1100 / gfx1101 / gfx1102）
rocminfo | grep -E "gfx|Marketing"
rocm-smi           # 查看温度/频率/显存占用

# 3) RDNA2（RX 6000 消费卡）必须设置兼容层，否则 "no kernel image"
export HSA_OVERRIDE_GFX_VERSION=10.3.0   # 写入 ~/.bashrc 或 systemd 环境

# 4) 安装 HIP/开发头（编译 llama.cpp 需要）
sudo apt install -y rocm-dev hip-dev
export PATH=/opt/rocm/bin:$PATH
```

> **注意：** 系统 ROCm、PyTorch ROCm 轮子、Ollama 自带 ROCm 三者大版本尽量一致（如都基于 6.x），混用 5.x/6.x 是 AMD 上最常见的"玄学报错"来源。

### 5.2 Ollama（ROCm 版）

```bash
# Linux 官方脚本：自动检测 AMD GPU 并安装带 ROCm 的版本
curl -fsSL https://ollama.com/install.sh | sh

# RDNA2 用户：先设 override 再启动服务
export HSA_OVERRIDE_GFX_VERSION=10.3.0
ollama serve &

# 拉取并运行（Ollama 自动下载 Q4_K_M 量化）
ollama run qwen3:8b
ollama run deepseek-r1:7b

# 验证是否真正用上 GPU（显存占用 > 0 即成功，0 说明回退 CPU）
ollama ps
```

### 5.3 llama.cpp（HIP / Vulkan 编译）

```bash
git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp

# 方式 A：HIP 后端（Linux + ROCm，性能最优）
cmake -B build -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1100   # RDNA3 7900 系；7600 用 gfx1102；RDNA2 用 gfx1030
cmake --build build --config Release -j $(nproc)

# 方式 B：Vulkan 后端（Windows/Linux 通用，免 ROCm）
# Ubuntu: sudo apt install libvulkan-dev glslang-tools
cmake -B build -DGGML_VULKAN=ON
cmake --build build --config Release -j $(nproc)

# 运行（-ngl 99 = 全部层进 GPU；-c 为上下文长度）
./build/bin/llama-cli -m ./qwen3-32b-q4_k_m.gguf -ngl 99 -c 8192 -p "你好，请介绍一下你自己"

# 服务模式（OpenAI 兼容 API）
./build/bin/llama-server -m ./model.gguf -ngl 99 --host 0.0.0.0 --port 8080

# 性能基准测试
./build/bin/llama-bench -m ./model.gguf -ngl 99
```

### 5.4 vLLM（ROCm，Linux）

```bash
# 方式 A：官方 ROCm docker 镜像（推荐，省去环境地狱）
docker run --device=/dev/kfd --device=/dev/dri \
  --group-add=video --ipc=host --shm-size=16g \
  -v ~/models:/models \
  rocm/vllm:latest \
  vllm serve /models/Qwen3-14B-GPTQ-Int4 --dtype float16

# 方式 B：源码编译（消费卡 gfx1100 常见路线）
git clone https://github.com/vllm-project/vllm && cd vllm
pip install torch --index-url https://download.pytorch.org/whl/rocm6.2
VLLM_TARGET_DEVICE=rocm python setup.py install
# 消费卡 flash-attention 兜底：
export VLLM_ATTENTION_BACKEND=FLASHINFER
```

### 5.5 LM Studio（Windows / Linux）

- 官网下载安装包（lmstudio.ai），首次启动选择 Vulkan 后端（AMD 默认）。
- 内置模型浏览器搜索 `Qwen3` / `DeepSeek-R1-Distill`，选择 GGUF 与量化档位（Q4_K_M），下载后直接聊天。
- 本地 API：Settings → Local Server，勾选启用后即得 `http://localhost:1234/v1`（OpenAI 兼容）。

---

## 6. 兼容性风险与验证步骤

### 6.1 风险清单（按影响排序）

| 风险 | 现象 | 规避/修复 |
|---|---|---|
| **ROCm 版本不匹配**（PyTorch 轮子 / 编译库 / 驱动三方打架） | "no kernel image is available for execution on the device" | 统一到同一大版本；优先用官方 docker 镜像 |
| **RDNA2 消费卡不被官方支持** | 启动即崩 / 特定算子（attention）报错 | `HSA_OVERRIDE_GFX_VERSION=10.3.0`；仍不稳定就换 Vulkan 后端 |
| **Ollama 静默回退 CPU** | `ollama ps` 显存占用 0，速度奇慢 | 检查是否装了 ROCm 版；`journalctl` 查日志；RDNA2 加 override |
| **Vulkan 跑 MoE 性能差** | 30B-A3B/671B 等模型 token/s 异常低 | 升级 llama.cpp 到最新版；改用 HIP 后端 |
| **vLLM flash-attention 缺失** | 显存暴涨 / 极慢 | `VLLM_ATTENTION_BACKEND=FLASHINFER` 或换 llama.cpp |
| **Windows ROCm 半残** | 装不上 / 随机崩溃 | 放弃 ROCm，改用 Vulkan（LM Studio / llama.cpp Vulkan） |
| **多卡 RCCL 初始化失败** | vLLM 多卡启动报 nccl 错误 | 显式设置 `HIP_VISIBLE_DEVICES`；llama.cpp 用 `--split-mode layer` |
| **老卡（GCN/RDNA1）被 ROCm 抛弃** | ROCm 5.7+ 无法安装 | 走 Vulkan 路线，或换卡 |

### 6.2 部署后必做验证清单

```bash
# 1) 驱动与 ROCm 层
rocminfo | grep -E "gfx|Name"      # 应显示你的 gfx target
rocm-smi                            # 显卡可见、温度正常

# 2) Vulkan 层（走 Vulkan 路线时）
vulkaninfo | grep -A2 "GPU0"        # 应显示 AMD 显卡型号

# 3) 推理是否真正用上 GPU
ollama ps                           # GPU 列显存占用 > 0
# llama.cpp: 观察启动日志 "llama_kv_cache_init: VRAM = ..." 以及
# 运行中 nvidia-smi 对应改为 rocm-smi 看显存占用增长

# 4) 性能是否达标（RDNA3 参考值，Q4 模型，不同模型差异大）
#    Qwen3-8B  Q4:  > 40 tok/s
#    Qwen3-32B Q4:  > 20 tok/s（7900 XTX）
#    QwQ-32B   Q4:  > 15 tok/s（7900 XTX）
./build/bin/llama-bench -m ./model.gguf -ngl 99

# 5) 压力验证：连续对话 + 长上下文，观察是否 OOM/崩溃
#    OOM 时降低 -c 或改用更小量化（Q4_K_M → Q4_0 → Q3_K_M）
```

---

## 7. 总结：推荐结论（加粗汇总）

1. **平台：Linux 优先。** RX 7000 系列（gfx1100/1101/1102）用官方 ROCm 6.x；RX 6000 消费卡加 `HSA_OVERRIDE_GFX_VERSION=10.3.0` 可用但有风险；Windows 一律走 Vulkan（LM Studio / llama.cpp Vulkan 后端）。
2. **工具：Ollama（ROCm 版）入门最省事；llama.cpp HIP 后端性能与可控性最佳；vLLM 仅限 Linux 且面向服务化场景；LM Studio 是 Windows 用户的第一推荐。**
3. **显存分级（Q4_K_M 量化）：8GB → Qwen3-8B / R1-Distill-7B；16GB → Qwen3-14B / R1-Distill-14B；24GB → Qwen3-32B / R1-Distill-32B / QwQ-32B / Qwen3-30B-A3B。**
4. **MoE 模型在 AMD 上：单卡 24GB 跑 Qwen3-30B-A3B 是最优实践；671B 级 DeepSeek 本体在消费级 AMD 多卡上性价比极差，工作站请选 Instinct（MI300X/MI210+）平台，个人用户用 QwQ-32B / R1-Distill-32B 替代。**
5. **所有部署完成后，务必用 `ollama ps` / `rocm-smi` / `llama-bench` 验证"真用上 GPU"与性能达标，避免静默回退 CPU 的假部署。**

---

*本文档基于 ROCm 5.7–6.x 生态撰写；AMD 生态迭代极快（尤其 ROCm for Windows 与 Ollama 的 AMD 支持），部署前请以 AMD ROCm 官方文档与各工具 GitHub Release 为准。*

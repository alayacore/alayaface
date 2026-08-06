# Qwen 与 DeepSeek 开源模型调研及三平台部署最终推荐报告

> **交付物说明（自包含）**：本文汇总 Qwen / DeepSeek 开源模型调研成果与 NVIDIA（CUDA）、Mac（Apple Silicon）、AMD（ROCm/Vulkan）三大平台部署方案，给出明确的选型与推荐结论，可直接作为交付物阅读。
>
> **执行说明（文件状态）**：
> - ✅ 已读取并采纳：`deploy_nvidia.md`、`deploy_mac.md`、`deploy_amd.md`（三份部署方案完整）
> - ⚠️ **缺失并基于已有知识补全**：`research_qwen.md`、`research_deepseek.md` 在 `src-go/docs/` 目录下不存在。其调研内容已依据三份部署文档中内嵌的 Qwen/DeepSeek 对比信息、HuggingFace / Ollama 模型库现状及公开资料补全，并在此注明。报告正文中所有 Qwen/DeepSeek 对比数据均视为"调研补全版"。
>
> 文档版本：v1.0 ｜ 面向：本地部署开源大模型的开发者与个人用户

---

## 目录

1. [Qwen vs DeepSeek 综合对比](#一qwen-vs-deepseek-综合对比)
2. [三平台横向对比：NVIDIA / Mac / AMD](#二三平台横向对比nvidia--mac--amd)
3. [最终推荐：按用户场景选型](#三最终推荐按用户场景选型)
4. [常见问题 FAQ](#四常见问题-faq)
5. [参考与数据来源](#五参考与数据来源)

---

## 一、Qwen vs DeepSeek 综合对比

### 1.1 背景速览

- **Qwen（通义千问）**：阿里巴巴通义实验室出品，是全球采用量最高的开源大模型家族之一。Qwen3（2025 年发布）覆盖 0.6B ~ 235B 全尺寸（Dense + MoE），配套 QwQ-32B 推理模型、Qwen-VL 多模态与 Qwen-Coder 代码系列，被称为"开源模型全家桶"。Qwen3 发布后长期占据 HuggingFace 下载与榜单头部。
- **DeepSeek（深度求索）**：幻方量化旗下，DeepSeek-R1（2025 年 1 月）以"推理能力比肩 o1 + 完全开源"引发全球现象级关注，App 一度登顶多国下载榜。其 V3/R1 本体为 671B MoE 旗舰；面向普通用户主要使用的是 **R1-Distill 蒸馏版**（1.5B/7B/8B/14B/32B/70B）。

### 1.2 综合对比表

| 维度 | **Qwen（通义千问）** | **DeepSeek（深度求索）** |
|---|---|---|
| 使用人数 / 热度 | 全球开源采用量第一梯队，Qwen3 登顶多榜；国内开源事实标准之一，生态（GGUF/MLX/微调）最全 | R1 出圈热度历史级；推理榜单一度霸榜；原版推理模型关注度极高，但普通本地用户主要用蒸馏版 |
| 定位 | **通用助手全家桶**：对话、写作、翻译、代码、工具调用/Agent、多模态（VL）、Coder；QwQ-32B 补足深度推理 | **深度推理专家**：数学、代码、逻辑推理（R1 思考链）；V3 为通用 MoE 底座；无多模态 |
| 模型规模 | 全尺寸覆盖：Qwen3 Dense 0.6B/1.7B/4B/8B/14B/32B + MoE 30B-A3B/235B-A22B；QwQ-32B；Qwen2.5-VL/Coder | 原版 V3/R1 为 **671B MoE（37B 激活）**；R1-Distill 蒸馏版 1.5B/7B/8B/14B/32B/70B（Dense） |
| 许可证 | Qwen3 / Qwen2.5 系列 **Apache 2.0**（可商用、可自由分发） | DeepSeek-R1 / V3 **MIT**（可商用、更宽松） |
| 中文能力 | 母语级中文，写作/翻译/风格化输出业界第一梯队，中文通用对话综合最强 | 母语级中文，中文推理/数学类问答极强；通用中文写作、风格化略逊 Qwen |
| 推理 / 思考模式 | Qwen3 支持**可控 thinking**（`think` 标签可开/关，关闭后更快更省显存）；QwQ-32B 专攻深度推理 | R1 固定输出完整思考链，推理/数学/代码能力顶级，但 token 更长、耗时与显存开销更大 |
| 本地部署友好度 | **极高**：尺寸梯度细、小模型多（0.6B 起）；官方 GGUF / **官方 MLX** 权重；MoE 激活参数少、带宽友好；全工具链成熟 | 原版 671B 本地不现实（需 ~400GB+）；**蒸馏版与 Qwen/Llama 同构、部署同样容易**；无官方 MLX（靠社区转换） |
| 资源门槛 | 全档位覆盖：最低 0.6B 可跑 CPU；8B Q4 ≈ 5GB；14B Q4 ≈ 9GB；32B Q4 ≈ 20GB；235B-A22B Q4 ≈ 130~141GB | 蒸馏版门槛与 Qwen 同尺寸一致（7B Q4 ≈ 4.5~5GB）；**原版需 8×80GB 服务器级**（FP8 ~671GB / AWQ 4bit ~335~400GB） |
| 多模态 | ✅ Qwen2.5-VL / Qwen3-VL 可本地跑 | ❌ 无多模态 |
| 微调生态 | mlx-lm LoRA、LLaMA-Factory 等资料丰富 | 蒸馏版与 Qwen 同生态；原版微调门槛极高 |

### 1.3 一句话结论

> **Qwen = 通用、轻量、中文写作、Agent、多模态、Mac 友好（官方 MLX）的"全能选手"；DeepSeek = 深度推理、数学、代码的"专家"，本地用户请认准 R1-Distill 蒸馏版（原版 671B 非服务器不可为）。**

---

## 二、三平台横向对比：NVIDIA / Mac / AMD

### 2.1 各平台核心特征

| 维度 | **NVIDIA（CUDA）** | **Mac（Apple Silicon）** | **AMD（ROCm / Vulkan）** |
|---|---|---|---|
| 生态成熟度 | ★★★★★ **最成熟**：vLLM / TensorRT-LLM / SGLang / Ollama / llama.cpp 全系第一优先支持 | ★★★★☆ MLX 官方框架 + Ollama / llama.cpp（Metal）成熟 | ★★★☆ Linux 上 ROCm 可用（RDNA3 官方支持）；**Windows 生态明显偏弱** |
| 硬件形态 | 独立显卡显存（消费级 8~24GB；专业卡 48/80GB） | **统一内存**（16~192GB），CPU/GPU/NPU 共享内存池，内存即"显存" | 独立显卡显存（消费级 8~24GB；Pro 32/48GB） |
| 决定性瓶颈 | **显存容量**决定能跑多大模型；**显存带宽**决定速度 | **内存容量**决定上限；**内存带宽**决定速度（带宽 ≈ token/s 上限） | 同 NVIDIA：容量 + 带宽；且 7900 XTX 带宽约 960GB/s，约为 RTX 4090 的 70% |
| 推荐工具链 | Ollama、llama.cpp、vLLM、SGLang、TensorRT-LLM | **mlx-lm（官方最优）**、Ollama、llama.cpp、LM Studio | Ollama（ROCm 版）、llama.cpp（HIP/Vulkan）、vLLM（仅 Linux）、LM Studio（Vulkan） |
| 量化方案 | GGUF Q4/Q5/Q8、AWQ、GPTQ、**FP8（仅 RTX 40/50 硬件加速）** | GGUF / MLX 4bit / 8bit（无 FP8） | 以 GGUF Q4_K_M/Q5/Q8 为主；无 FP8 硬件加速 |
| 多卡能力 | 成熟（TP/EP）；消费级无 NVLink 走 PCIe，MoE 通信有瓶颈 | 无多卡扩展（单芯片；不支持 eGPU 加速 LLM） | RCCL 可用但扩展效率通常仅 60~80%；消费级多卡跑 671B 性价比极差 |
| 主要风险 / 坑 | 显存不足；驱动/CUDA 版本不匹配；FP8 需 40/50 系；vLLM 在 Windows 不友好（用 WSL2） | 内存带宽决定速度（M3 Pro 带宽 150GB/s 反而低于 M2 Pro）；128GB 也跑不了 671B 原版；Intel Mac 仅 CPU | RDNA2（RX 6000）非官方支持需 `HSA_OVERRIDE_GFX_VERSION`；Windows ROCm 仅"预览"；Ollama 可能静默回退 CPU；ROCm/PyTorch 版本错配"玄学报错" |
| 适合人群 | 追求性能/服务化的玩家、生产环境、多卡集群 | 办公+开发一体机、安静低功耗、想跑大模型（内存大）的用户 | 已有 AMD 卡不想换 N 卡的用户、Linux 玩家、Windows 上求"能跑"的用户 |
| 速度参考（8B Q4） | 30~60 tok/s（RTX 40 系） | 10~30 tok/s（M 系列按带宽） | 40+ tok/s（7900 XTX 级别，Linux HIP） |
| 能否跑原版 DeepSeek-R1 | 需 8×80GB 服务器（FP8 ~671GB） | ❌ 不现实（128GB 装不下 Q4 ~400GB） | ❌ 不现实（消费级 8 卡仍不够，需 Instinct MI300X 级） |

### 2.2 平台优劣势总结表

| 平台 | ✅ 优势 | ❌ 劣势 | 一句话定位 |
|---|---|---|---|
| **NVIDIA（CUDA）** | 生态最成熟、性能最好、量化/工具选择最多、多卡与生产服务方案最完善、FP8 硬件加速 | 显存容量是硬上限（消费级 ≤24GB）；好卡贵、功耗高；驱动/CUDA 版本管理麻烦 | **性能与生态的"天花板"**，本地部署首选平台 |
| **Mac（Apple Silicon）** | 统一内存可跑 70B/235B 大模型；官方 MLX + Qwen 官方 MLX 权重开箱即用；安静低功耗；无显存/内存之分 | 带宽决定速度（基础款 M 系列慢）；M3 Pro 带宽反降；128GB 也装不下 671B；多卡/eGPU 不可行 | **"内存即显存"的大模型工作站**，适合轻量到中型部署（最高 235B-A22B） |
| **AMD（ROCm/Vulkan）** | 显存大且相对便宜（7900 XTX 24GB）；Linux RDNA3 官方支持；Vulkan 兜底兼容所有老卡 | Windows 生态半残；RDNA2 需兼容层有风险；工具链滞后（无 FP8、vLLM 折腾）；MoE/多卡效率低于 NVIDIA | **"性价比折腾派"**：Linux + RDNA3 可用，Windows 请走 Vulkan |

### 2.3 工具链对照速查（三平台通用）

| 工具 | NVIDIA | Mac | AMD | 适用 |
|---|---|---|---|---|
| **Ollama** | ✅ 一键 | ✅ 一键 | ✅ Linux ROCm 版 / Windows 部分卡 | 绝大多数人：零配置体验 |
| **llama.cpp** | ✅ CUDA | ✅ Metal | ✅ HIP（Linux）/ Vulkan（全平台） | 精细控制、服务化、CPU 混合 |
| **vLLM / SGLang** | ✅ 最成熟 | ❌ | ⚠️ 仅 Linux + 折腾 | 高吞吐、多用户、生产服务 |
| **mlx-lm** | ❌ | ✅ 官方最优 | ❌ | Mac 极限速度 / LoRA 微调 |
| **LM Studio** | ✅ | ✅ | ✅（Vulkan 默认） | 图形界面新手、Windows AMD 用户 |
| **TensorRT-LLM** | ✅ 极致 | ❌ | ❌ | NVIDIA 生产级吞吐优化 |

---

## 三、最终推荐：按用户场景选型

> 推荐组合按"首选模型 + 工具 + 量化"给出，并标注预期速度量级。量化默认 Q4_K_M（黄金平衡点），显存/内存有富余可升 Q5/Q8。

### 3.1 入门档：8~16GB（轻量日常）

| 平台 | 首选组合 | 备选 | 说明 |
|---|---|---|---|
| NVIDIA 8GB | **Qwen3-8B + Ollama/llama.cpp + Q4_K_M**（≈5GB，30~50 tok/s） | DeepSeek-R1-Distill-Qwen-7B Q4（≈4.5GB）；Qwen3-4B Q4（≈2.5GB，秒回） | 8GB 跑 14B 不现实；上下文建议 ≤8K |
| NVIDIA 12~16GB | **Qwen3-14B + Ollama/llama.cpp + Q4_K_M**（≈9GB，20~35 tok/s） | DeepSeek-R1-Distill-Qwen-14B Q4；Qwen3-8B Q8_0（高质量） | 12GB 是 14B Q4 的舒适区；16GB 可升 Q6/Q8 |
| Mac 16GB | **Qwen3-8B + Ollama/mlx-lm + Q4**（≈5.5GB，10~18 tok/s） | DeepSeek-R1-Distill-Qwen-7B Q4；Qwen3-4B Q4（30~50 tok/s） | 注意给系统留内存；不开超大上下文 |
| AMD 8GB | **Qwen3-8B + Ollama（Linux）/LM Studio（Windows）+ Q4_K_M**（≈5.1GB） | DeepSeek-R1-Distill-Qwen-7B Q4（≈4.7GB） | Windows 一律 Vulkan；RDNA2 需兼容层 |
| AMD 16GB | **Qwen3-14B + llama.cpp HIP / Ollama + Q4_K_M**（≈9GB） | DeepSeek-R1-Distill-Qwen-14B Q4；Qwen3-8B Q8_0 | 16GB 不要强上 32B（Q4 ≈20GB 放不下） |

### 3.2 主流档：16~32GB（主力日常 + 中大型模型）

| 平台 | 首选组合 | 备选 | 说明 |
|---|---|---|---|
| NVIDIA 24GB（4090/3090） | **Qwen3-32B + llama.cpp/Ollama/vLLM + Q4_K_M/Q5_K_M**（≈19~22GB，15~30 tok/s） | QwQ-32B Q4；DeepSeek-R1-Distill-Qwen-32B Q4；Qwen3-30B-A3B（MoE，25~45 tok/s 更快） | 消费级甜点位；要推理能力换 QwQ-32B / R1-Distill-32B；要速度换 MoE |
| Mac 32GB | **Qwen3-14B + mlx-lm + Q4**（12~30 tok/s）；**Qwen3-30B-A3B（MoE）Q4**（25~50 tok/s，强烈推荐） | DeepSeek-R1-Distill-Qwen-14B Q4；Qwen3-32B Q4（内存偏紧，上下文 ≤8K） | MoE 激活仅 3B，是 Mac 带宽受限场景下的最优解 |
| Mac 64GB | **Qwen3-32B + mlx-lm + Q8**（≈32GB，10~15 tok/s）或 Q4（15~22 tok/s） | QwQ-32B / R1-Distill-32B Q4；DeepSeek-R1-Distill-Llama-70B Q4（≈42GB，7~10 tok/s） | 64GB 是"重载工作站"，可上 70B 蒸馏 |
| AMD 24GB（7900 XTX/XT） | **Qwen3-32B + llama.cpp HIP + Q4_K_M**（≈19.5GB） | DeepSeek-R1-Distill-Qwen-32B Q4（≈20GB）；QwQ-32B Q4；Qwen3-30B-A3B Q4（≈18.5GB，速度快） | 24GB 是 AMD 消费级甜点；工具首选 llama.cpp HIP |

### 3.3 高配档：48GB+ / 多卡（70B+ / 旗舰 MoE）

| 平台 | 首选组合 | 备选 | 说明 |
|---|---|---|---|
| NVIDIA 48GB（A6000/L40S） | **DeepSeek-R1-Distill-Llama-70B + llama.cpp/vLLM + Q4_K_M/AWQ**（≈40~42GB，10~18 tok/s） | Qwen3-32B FP8/BF16 全精度 | 单卡体验 70B 的门槛 |
| NVIDIA 2×24GB（4090×2） | **DeepSeek-R1-Distill-Llama-70B + vLLM + Q4_K_M（TP2）**（≈42GB 均摊，20~35 tok/s） | Qwen3-32B FP8（2 卡足够） | 低预算体验 70B 的最佳入口 |
| NVIDIA 6~8×24GB | **Qwen3-235B-A22B（MoE）+ vLLM/SGLang + Q4_K_M/AWQ**（≈141GB，20~40 tok/s） | 多卡张量并行；注意 PCIe 通信 | 消费级多卡最优目标是 235B-A22B（22B 激活，速度快） |
| NVIDIA 8×80GB（服务器） | **DeepSeek-R1/V3 原版 671B + vLLM/SGLang/TensorRT-LLM + FP8 或 AWQ 4bit**（FP8 ≈671GB / AWQ ≈335~400GB，15~40 tok/s） | 这是"真·DeepSeek-R1"的唯一现实路径 | 必须同节点多卡；MLA 需 vLLM/SGLang 专门优化 |
| Mac 128GB+（M2 Ultra/M4 Max） | **Qwen3-235B-A22B（MoE）+ mlx-lm + Q4**（≈130GB，25~45 tok/s） | DeepSeek-R1-Distill-Llama-70B Q5/Q6；Qwen3-32B FP16 全精度 | 本地接近 API 级质量；DeepSeek 671B 在 Mac 上不现实 |
| AMD 多卡/工作站 | 不推荐消费级多卡跑 671B；**务实选择：QwQ-32B / R1-Distill-32B 单卡**；若必须大模型用 Instinct（MI300X/MI210+）平台 | llama.cpp 多卡用 `--split-mode layer` | 消费级 AMD 多卡扩展效率仅 60~80%，性价比差 |

### 3.4 "Qwen 优先"还是"DeepSeek 优先"？——决策建议

| 你的场景 | 决策 | 理由 |
|---|---|---|
| 中文通用对话、写作、翻译、风格化输出 | **Qwen 优先** | Qwen3 中文写作/通用能力第一梯队，尺寸选择多 |
| 轻量部署（8~16GB、CPU、小显存） | **Qwen 优先** | Qwen 有 0.6B/1.7B/4B 梯度；DeepSeek 蒸馏版最小 1.5B，选择更少 |
| Agent / 工具调用 / 结构化输出 | **Qwen 优先** | Qwen3 thinking 可开关、工具链资料最全 |
| 多模态需求（看图/视频） | **Qwen 优先** | DeepSeek 无多模态 |
| **Mac 用户** | **Qwen 优先** | Qwen 官方提供 MLX 权重开箱即用；DeepSeek 仅社区转换 |
| 想体验 MoE 大模型（30B-A3B / 235B-A22B） | **Qwen 优先** | DeepSeek MoE 仅 671B 原版（本地不现实） |
| 深度推理：数学、代码难题、逻辑题 | **DeepSeek 优先** | R1 思考链与推理能力是招牌；本地用 R1-Distill-14B/32B/70B |
| 需要"R1 风格"强推理但资源有限 | **DeepSeek 优先（蒸馏版）** | R1-Distill-Qwen-* 系列：DeepSeek 推理能力 + Qwen 架构的部署便利 |
| 70B 级大模型（48GB+ / 双卡） | **DeepSeek 优先** | R1-Distill-Llama-70B 是 70B 档位最易得的推理模型 |
| 长上下文 / 极致 KV Cache 效率 | **DeepSeek 优先（原版）** | 原版 MLA 的 KV Cache 极小；但需服务器级硬件，个人用户意义有限 |
| 生产服务、高并发 API | 两者皆可，按任务选 | Qwen 通用服务 + vLLM；DeepSeek 原版仅限 8×80GB 服务器 |

**总原则**：
1. **默认 Qwen**：中文通用、轻量部署、Mac、Agent、多模态，Qwen 是"闭眼选不会错"的答案；
2. **推理任务换 DeepSeek**：数学/代码/深度推理，用 R1-Distill 系列（或 Qwen 自家的 QwQ-32B 作为替代）；
3. **折中最优解**：`DeepSeek-R1-Distill-Qwen-*` = DeepSeek 的推理风格 + Qwen 的部署生态，两边优势兼得；
4. **原版 DeepSeek-R1（671B）只属于服务器**，任何单卡/单机（除 8×80GB 集群）场景都请转向蒸馏版或 QwQ-32B。

---

## 四、常见问题 FAQ

### Q1：内存 / 显存不足（OOM）怎么办？
按优先级依次尝试：
1. **降量化**：Q8 → Q5_K_M → Q4_K_M → Q4_0 → Q3_K_M（质量逐级下降）；
2. **缩短上下文**：`-c 8192` → `4096` → `2048`（KV Cache 随长度线性增长，是最常见的隐性杀手）；
3. **量化 KV Cache**：llama.cpp 加 `-ctk q8_0 -ctv q8_0`，vLLM 用 `--kv-cache-dtype fp8`；
4. **部分层 offload 到内存**：llama.cpp 降低 `-ngl`（如 `-ngl 20`），速度下降但能跑；
5. **换更小模型**：32B → 14B → 8B → 4B（一步到位）；
6. Mac 用户先关闭其他大内存应用；AMD 用户检查是否静默回退 CPU（`ollama ps` 显存占用是否为 0）。

### Q2：量化精度怎么选？
- **Q4_K_M：默认首选**，速度/体积/质量黄金平衡点，个人日用无脑选；
- **Q5_K_M**：质量略好、体积略增，显存有富余时升级；
- **Q8_0**：接近全精度（FP16）但体积翻倍，适合"显存够但不想换大模型"时追求质量（如 16GB 跑 14B）；
- **AWQ / GPTQ 4bit**：服务化（vLLM）标准选择，批量吞吐好；
- **FP8**：仅 RTX 40/50 与 A/H 系列有硬件加速，RTX 30（Ampere）无 FP8 加速，请用 AWQ/Q4；
- **Q2/Q3**：应急选项，质量损失明显，仅在内存极度紧张时使用。

### Q3：只有 CPU（无独显 / Intel Mac）能跑吗？
- 可以，但**请把预期放低**：CPU 推理速度约为 GPU 的 1/10~1/20；
- 推荐 **Qwen3-1.7B / Qwen3-4B / R1-Distill-Qwen-1.5B（Q4/Q8）** 等小模型，用 llama.cpp 或 Ollama 的纯 CPU 模式；
- 7~8B Q4 在纯 CPU 上约 2~5 tok/s（Intel Mac 亦如此），仅适合体验；正式使用建议升级硬件或走 API；
- 关键变量：内存要够（模型体积 + 4GB 开销）、最好有 AVX2/AVX-512 的现代 CPU。

### Q4：Mac 和 Windows 在本地部署上差异大吗？
| | Mac（Apple Silicon） | Windows |
|---|---|---|
| 首选工具 | **mlx-lm**（官方，最快）或 Ollama | NVIDIA 卡：Ollama / llama.cpp / LM Studio；AMD 卡：**LM Studio（Vulkan）** |
| 加速后端 | Metal / MLX | CUDA（N 卡）或 Vulkan（A 卡） |
| 内存模型 | 统一内存，内存=显存，可跑大模型 | 显存独立，受显卡显存上限约束 |
| 大模型上限 | 64GB 内存可跑 70B Q4，128GB 可跑 235B-A22B | 消费级 24GB 显存约跑到 32B Q4 |
| 坑 | 基础款带宽低速度慢；Intel Mac 仅 CPU | AMD 卡别指望 ROCm（半残），走 Vulkan；vLLM 需 WSL2 |

### Q5：原版 DeepSeek-R1（671B）到底能不能本地跑？
- **不能**（对个人用户）。Q4 量化约需 400GB+，即 8×80GB（A100/H100）级服务器，或消费级 8×24GB 也不够；
- 现实替代路径：
  1. **DeepSeek-R1-Distill-32B**（24GB 卡 Q4 可跑，获得约 90% 的推理体验）；
  2. **QwQ-32B**（Qwen 自家推理模型，同等门槛）；
  3. **DeepSeek-R1-Distill-Llama-70B**（48GB 单卡或 2×24GB 双卡）；
  4. 直接用官方 API（API 是最便宜的"原版体验"方式）。

### Q6：为什么多卡速度不随卡数线性提升？
- 消费级显卡（4090/5090 等）**无 NVLink**，多卡之间走 PCIe 通信；
- MoE 模型的专家路由（All-to-All）对互联带宽极敏感，PCIe 下吞吐损失明显；
- 建议：多卡优先 vLLM/SGLang 张量并行（TP）；MoE 模型避免跨节点、优先同机箱；AMD 消费级多卡扩展效率仅 60~80%，更不推荐。

### Q7：Mac 上 mlx-lm 和 Ollama 选哪个？
- **省心、日常用 → Ollama**：一条命令拉模型、自动量化、自带 OpenAI 兼容 API；
- **追求极限速度 / 官方 MLX 权重 / LoRA 微调 → mlx-lm**：实测通常比 llama.cpp/Ollama 快 10%~30%，且 Qwen 官方发布 MLX 权重，开箱即用；
- 服务化/精细控制 → llama.cpp（llama-server）；图形界面新手 → LM Studio。

### Q8：Windows + AMD 显卡怎么部署最省事？
- **LM Studio**（默认 Vulkan 后端）是第一推荐：图形界面搜模型、选 Q4_K_M、开本地 API；
- 或 llama.cpp 的 **Vulkan 后端**（`-DGGML_VULKAN=ON`）命令行部署；
- **不要**在 Windows 上折腾 ROCm（仅"预览"、仅 7900 系等少数卡）；RDNA2 老卡 + Windows 也走 Vulkan 即可。

### Q9：Ollama 拉模型慢 / 国内网络怎么办？
- 设置代理：`export HTTPS_PROXY=http://127.0.0.1:7890`；
- HuggingFace 模型下载设镜像：`export HF_ENDPOINT=https://hf-mirror.com`；
- Mac 用户可从 Ollama 官方应用商店或镜像站下载安装包。

### Q10：如何确认模型真的在用 GPU（而不是静默跑 CPU）？
- NVIDIA：`nvidia-smi` 观察显存占用 > 0；llama.cpp 启动日志看 `offloaded X/Y layers to GPU`；
- Mac：活动监视器观察 GPU 占用升高、CPU 占用显著降低；
- AMD：`ollama ps` 显存占用 > 0；`rocm-smi` 查看；llama.cpp 看 `llama_kv_cache_init: VRAM` 日志；
- 性能自检：`llama-bench -m model.gguf -ngl 99` 与文档中的参考速度量级对比。

---

## 五、参考与数据来源

**本文档依据（已读取）**：
- `deploy_nvidia.md`：NVIDIA（CUDA）部署方案——工具链、量化、显存估算、分级推荐、vLLM/SGLang/TensorRT-LLM 命令
- `deploy_mac.md`：Mac（Apple Silicon）部署方案——统一内存、带宽决定速度、MLX/Ollama/llama.cpp/LM Studio、分级推荐
- `deploy_amd.md`：AMD（ROCm/Vulkan）部署方案——支持矩阵、兼容层、工具链、风险清单、分级推荐

**调研补全来源（原 research_qwen.md / research_deepseek.md 缺失，基于以下公开资料补全）**：
- HuggingFace 模型仓库：Qwen（Qwen3/QwQ/Qwen3-VL 系列）、deepseek-ai（DeepSeek-R1/V3、R1-Distill 系列）
- Ollama 模型库：qwen3 / qwq / deepseek-r1 各尺寸
- Qwen3（Apache 2.0）、DeepSeek-R1/V3（MIT）许可证信息
- 三份部署文档中内嵌的 Qwen vs DeepSeek 对比章节（NVIDIA 第 6 节、Mac 第 4 节、AMD 第 4 节）

**官方链接**：Ollama（ollama.com）· llama.cpp（github.com/ggml-org/llama.cpp）· vLLM（docs.vllm.ai）· SGLang（docs.sglang.ai）· TensorRT-LLM（github.com/NVIDIA/TensorRT-LLM）· MLX（github.com/ml-explore/mlx）· LM Studio（lmstudio.ai）

---

*本报告为综合调研与部署方案的一站式交付物；所有显存占用、速度均为经验估算值，实际以你的硬件、驱动、量化与上下文为准。部署前请核对各平台文档与最新版本。*

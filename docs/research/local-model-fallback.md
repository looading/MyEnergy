# 本地中文模型备选

核查日期：2026-11-20，Asia/Shanghai。用途：为每日复盘和习惯建议选择可在 iPhone、其次在 Mac 本机推理的备选方案。本文是研究结论与工程建议，未下载模型、安装依赖、修改工程或运行推理；没有手机速度、峰值内存或中文质量实测结果。产品边界沿用 [项目状态](../project/status.md)，本笔记不扩大同步、健康分析或发布范围。

## 优先验证 MLX Swift

建议在 Foundation Models 不可用时，采用 **MLX Swift＋Qwen3-0.6B 的 4-bit MLX 权重**，先提供短篇中文每日复盘与一项习惯建议。它直接在应用进程中执行推理，不要求付费云 key；公开权重可先下载，再离线使用。MLX 官方仓库提供 iOS／macOS 的语言模型应用示例，Qwen3 的 Swift 实现也已存在，无须从零移植模型结构。[MLX Swift 官方说明](https://github.com/ml-explore/mlx-swift/blob/0.29.1/README.md)、[固定版本的 Qwen3 实现](https://github.com/ml-explore/mlx-swift-lm/blob/2.29.3/Libraries/MLXLLM/Models/Qwen3.swift)

这条路径不依赖系统的 Apple Intelligence 模型，但仍受设备 GPU、可用内存、操作系统和 Metal 编译兼容性影响。iOS 17／macOS 14 可以作为待验证的部署目标，不能据此承诺所有满足系统版本的设备都能正常运行。Mac 首先覆盖 Apple silicon；本文不承诺 Intel Mac、Apple Watch 或模拟器上的模型推理。[MLX 的 Apple silicon 定位](https://github.com/ml-explore/mlx-swift/blob/0.29.1/README.md)

## 固定模型与下载资产

| 项目 | 核查结果 |
| --- | --- |
| 源模型 | `Qwen/Qwen3-0.6B`，官方模型卡标称 0.6B 参数、28 层、32,768 token 上下文 |
| 源模型固定 revision | `c1899de289a04d12100db370d81485cdf75e47ca` |
| 应用候选资产 | `mlx-community/Qwen3-0.6B-4bit`，由 MLX Community 发布的量化转换，并非 Qwen 官方直接发布的 MLX 文件 |
| 量化资产固定 revision | `73e3e38d981303bc594367cd910ea6eb48349da8` |
| 量化配置 | 4 bit、group size 64，`model_type` 为 `qwen3` |
| 权重文件 | `model.safetensors`，335,450,584 bytes，约 335.45 MB／319.91 MiB |
| 权重 SHA-256 | `392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2` |
| 仓库文件总量 | 本次 HF API 所列 11 个文件合计 351,386,061 bytes，约 351.39 MB／335.11 MiB；包含 tokenizer 等文件。下载工具缓存、临时文件和应用体积另计 |
| 访问条件 | 本次 HF API 返回 `private: false`、`gated: false`；公开资产下载无须推理服务账号或付费 key。具体网络可达性仍待部署地区验证 |

参数与上下文依据 [Qwen 官方模型卡](https://huggingface.co/Qwen/Qwen3-0.6B/blob/c1899de289a04d12100db370d81485cdf75e47ca/README.md)；转换来源依据 [量化资产发布者模型卡](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/blob/73e3e38d981303bc594367cd910ea6eb48349da8/README.md)。固定 revision、文件大小与哈希来自本次只读查询的 [HF 模型 API](https://huggingface.co/api/models/mlx-community/Qwen3-0.6B-4bit?blobs=true)，并交叉读取了 [量化配置](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/blob/73e3e38d981303bc594367cd910ea6eb48349da8/config.json)。API 地址随主分支变化，实际产品清单应保存上述 revision、文件名、长度和 SHA-256。

Qwen 官方公布的语言范围包含简体中文、繁体中文和粤语，可作为选择中文候选模型的依据；这不能替代 MyEnergy 场景的中文质量验收。0.6B 是优先降低手机资源负担的选择，对长篇分析、复杂推理或健康建议的质量没有保证。[Qwen3 官方语言说明](https://qwenlm.github.io/blog/qwen3/)

源模型使用 Apache License 2.0，允许在遵守许可条件的情况下商用、修改和分发；量化资产模型卡也声明同一许可证，并链接回源模型许可。分发时保留许可证与适用的声明，记录量化资产来源。MLX Swift 与 MLX Swift LM 为 MIT，发布清单仍须包含实际解析出的依赖许可。[源模型固定版本 LICENSE](https://huggingface.co/Qwen/Qwen3-0.6B/blob/c1899de289a04d12100db370d81485cdf75e47ca/LICENSE)、[量化资产许可声明](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/blob/73e3e38d981303bc594367cd910ea6eb48349da8/README.md)、[MLX Swift LICENSE](https://github.com/ml-explore/mlx-swift/blob/0.29.1/LICENSE)、[MLX Swift LM LICENSE](https://github.com/ml-explore/mlx-swift-lm/blob/2.29.3/LICENSE)

## 依赖与 Metal 有实际门槛

建议先验证下列固定组合，避免实现期间追随 `main`。这组版本已核对上游 manifest、tag commit 和 Qwen3 注册代码，**尚未在本工程解析或编译**，不能称为已验证兼容组合。

| 依赖 | 候选固定版本与证据 | 本工程需要的部分 |
| --- | --- | --- |
| `ml-explore/mlx-swift-lm` | `2.29.3`，commit `5064b8c5d8ed3b0bbb71385c4124f0fc102e74a2`；manifest 声明 macOS 14／iOS 16，依赖 MLX 0.29.1 的同次版本范围及 Transformers 1.1.6 的同次版本范围 | `MLXLLM`、`MLXLMCommon`；无需接入图像或训练产品 |
| `ml-explore/mlx-swift` | `0.29.1`，commit `072b684acaae80b6a463abab3a103732f33774bf`；manifest 要求 Swift tools 5.10，平台声明覆盖本项目 17／14 最低版本 | Metal runtime 及张量、网络运算；原生 C／C++ 与 shader 资源随包构建 |
| `huggingface/swift-transformers` | `1.1.6`；manifest 提供 `Hub`、`Tokenizers`、`Transformers`，继续依赖 `swift-jinja`、`swift-collections` | 分词、chat template；下载也可由独立资产管理器完成 |

依据：[LM 固定 manifest](https://github.com/ml-explore/mlx-swift-lm/blob/2.29.3/Package.swift)、[MLX 固定 manifest](https://github.com/ml-explore/mlx-swift/blob/0.29.1/Package.swift)、[Transformers 固定 manifest](https://github.com/huggingface/swift-transformers/blob/1.1.6/Package.swift)、[Qwen3 注册](https://github.com/ml-explore/mlx-swift-lm/blob/2.29.3/Libraries/MLXLLM/LLMModelFactory.swift)。tag commit 由本次 `git ls-remote` 读取；后续实际解析须记录完整 `Package.resolved`，包括传递依赖，不能只固定最外层 package。

SwiftPM 可声明这些依赖，但命令行 `swift build` 不能完成 Metal shader 构建。最终应用必须通过完整 Xcode／`xcodebuild` 构建，并验证 shader 资源随应用打包、首次 GPU 运算和实际模型生成。普通纯 Swift 单测通过，不能证明该路径可运行。[官方安装与构建说明](https://github.com/ml-explore/mlx-swift/blob/0.29.1/README.md)、[shader bundle 说明](https://github.com/ml-explore/mlx-swift/blob/0.29.1/Source/MLX/Documentation.docc/troubleshooting.md)

选择旧版本是有针对性的验证起点。截至核查时，官方仓库的 [issue #497](https://github.com/ml-explore/mlx-swift/issues/497) 仍为 open，报告 `mlx-swift 0.32.3` 在 iOS 17 的首次 GPU 运算中因 Metal 模板类型缺失而崩溃。该问题是公开报告，不是本项目复现结论，也不证明候选旧版本必然正常。不要直接将最新版 package 的 iOS 17 声明写成最低系统已验收。

当前 LM 主分支还存在 3.x API 变化；其 manifest 要求 Swift tools 6.2，下载器／分词器集成也已调整。本文的 2.29.3 方案应使用同版本文档和源码，不能混用主分支示例。升级时单独评估编译、Metal、分词模板和生成结果。[LM 主分支升级说明](https://github.com/ml-explore/mlx-swift-lm/blob/main/README.md)、[主分支 manifest](https://github.com/ml-explore/mlx-swift-lm/blob/main/Package.swift)

## 先限制上下文再测内存

建议首轮输入上限为 **2,048 token**，输出上限为 **256 token**，每次新建一次性复盘会话，同时只运行一个生成任务。先把记录整理为确定性统计和少量原文，再交给模型。这里的数值是初始工程预算，实际 API 参数与计数方式须在实现时核对；输出 token 数不等于汉字数。

不能把 335 MB 权重体积当作运行内存。按模型配置的 28 层、8 个 KV heads、每 head 128 维，若采用普通 FP16 KV cache、batch 为 1，则每个 token 的 K＋V 理论占用为 `2 × 28 × 8 × 128 × 2 = 114,688 bytes`，即 112 KiB。2,048 token 仅 KV 就约 224 MiB，4,096 token 约 448 MiB，32,768 token 约 3.5 GiB。这个计算没有包括权重、临时张量、分词器、GPU 缓存和 UI，也没有声称候选 runtime 的实际缓存一定采用该布局。[模型固定配置](https://huggingface.co/Qwen/Qwen3-0.6B/blob/c1899de289a04d12100db370d81485cdf75e47ca/config.json)

模型卡承诺的上下文为 32,768 token；配置中 `max_position_embeddings` 为 40,960、tokenizer 中出现更大上限，都不应被拿来扩大产品承诺。首版的短上下文预算也不代表该模型在旧 iPhone 上已达到可接受速度。必须分别记录冷启动、首 token 延迟、完整生成耗时、峰值内存、取消后回收和热状态；未测之前不填 tokens/s 或最低 RAM 保证。

## Core ML 需要更多适配工作

| 路径 | 可复用的官方基础 | 对当前最低系统的影响 | 工程判断 |
| --- | --- | --- | --- |
| MLX Swift＋现成量化权重 | 已有 Qwen3 模型类、分词器集成及两平台应用示例 | 需要处理真实 GPU／Metal 兼容性，并在 iOS 17／macOS 14 实测 | 首选验证路径，主要新增资产管理与推理生命周期 |
| Core ML 转换与自建生成循环 | Apple 提供 PyTorch 模型导出、转换与文本模型示例 | Core ML 的 stateful model 自 iOS 18／macOS 15 才支持；17／14 需自行处理显式 KV 输入输出，或接受无缓存重算方案的代价 | 作为后续独立工作包；本轮未核实一份由 Qwen 或 Apple 发布且已满足本工程要求的 Qwen3-0.6B Core ML 资产 |

Core ML 可以在设备运行文本模型，但不能把 `.safetensors` 改扩展名直接加载。需要确定支持的运算与动态 shape，导出／转换模型，处理 tokenizer、chat template、采样与停止条件，并核对量化后的输出一致性。Apple 的 OpenELM 转换示例还单独展示了模型导出、转换、分词及 PyTorch／Core ML 结果运行步骤。[官方 OpenELM 转换示例](https://apple.github.io/coremltools/docs-guides/source/convert-openelm.html)

stateful KV cache 的系统门槛见 [Core ML stateful models](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html)。该文档同时说明无状态模型可支持较早系统。因此不能把 Core ML 整体误写为 iOS 18 才可用，也不能忽略为 iOS 17／macOS 14 保留高效生成而产生的适配成本。两条路径的速度、功耗和维护成本比较，均需使用同一设备与同一任务实测后再下结论。

## 最小产品实现与验收

以下为本研究提出的工程设计，尚未由本文实现。

- 将模型推理放在独立的本机 provider 后面，输入为所选日期与现有可用记录；输出带模型 ID、revision、生成时间和所用记录范围。生成失败或缺资产时明确呈现状态；保留原始记录和已有确定性统计。
- 固定 revision 下载到临时目录，按完整文件清单验证长度和哈希后原子启用；用户可取消、重试、删除，应用明确显示下载体积和进度。离线时只检查已经验证的本地资产，禁止由推理入口偷偷回到网络下载。地区网络不可达时，可另行设计本地导入；本文未建立镜像或新增托管费用。
- 生成过程只访问本地资产和用户本机所选数据，不建立云推理客户端，不上传 prompt、原始健康记录或生成正文。资产下载与推理分开，推理开始后可断网完成。没有模型时不能把固定模板结果标成“AI 已生成”。
- 使用模型的 chat template 明确关闭 thinking，候选模板包含 `enable_thinking=false` 的分支；Swift 集成须验证该参数确实传入，不能只在 UI 隐藏 `<think>`。Qwen 官方推荐非思考模式采样值为 temperature 0.7、top-p 0.8、top-k 20、min-p 0，可作为初始值；不能把 greedy decoding 或低 temperature 当作事实准确性的保证。[官方非思考模式说明](https://huggingface.co/Qwen/Qwen3-0.6B/blob/c1899de289a04d12100db370d81485cdf75e47ca/README.md)、[固定量化模板](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/blob/73e3e38d981303bc594367cd910ea6eb48349da8/tokenizer_config.json)
- 中文 prompt 只要求概括已提供记录，并给一项低负担的习惯建议。主观心情与精力、睡眠和生理参考仍分别陈述；缺数据写明缺失，不从 HRV 推断心情，不生成诊断或药物建议。若输出出现未提供的测量、因果断言或非中文正文，应拒绝该次结果并显示可重试状态。
- 用可取消、串行执行的生成任务管理模型；离开页面、切换账号／示例空间或删除数据时停止生成并丢弃旧结果。低内存与热状态进入降级状态。具体内存阈值由目标设备测试决定，不在研究阶段编造通用阈值。

进入交付前，至少需要在目标 iPhone 真机及 Apple silicon Mac 分别验证：完整模型下载与哈希失败、断网生成、中文与缺数据行为、首 token 与总耗时、峰值内存及取消回收、连续生成与热状态、账号切换后的晚到结果隔离。iOS 17／macOS 14 的最低系统检查要单列。本文只确认公开接口与资产可作为实现起点，以上运行验收全部未执行。

## 本次核查记录

采用 `research` 技能，只查 Apple、MLX、Qwen、Hugging Face 资产发布者的文档、manifest、源码和模型元数据。通过网页读取原始来源，通过 Python 标准库在内存读取公开 JSON／文本，通过 `git ls-remote` 查看 tag；没有下载权重、clone 仓库或解析 Swift 依赖。GitHub API tags 查询遭遇公开配额 403，随后用只读 tag refs 和固定版本文件完成核对。

成稿按中文写作规范回读，保留版本、哈希、字节数、上下文及未验证条件。机械检查中，章节编号／量词标题、B2 句式、元话语、中文半角标点和标题破折号均为 0，行尾空白为 0；本地链接存在。22 个不同外链中，20 个 HEAD 检查成功，两份 Core ML 指南的 HEAD 因 TLS 握手超时未完成，正文已通过网页工具读取。本次仅验证资料与文档，没有改变项目已记录的设备、同步或费用授权。

## 实测后选型修订

2026-11-20，主任务完成了 0.6B 的真实本机离线生成，但后续质量检查不足以支持默认交付。一次 full-day 输出将合法的 `sleep_1` 擅自改为 `manualSleep_1`，被严格事实 ID 校验拒绝；加入逐字复制约束、动态 ID 白名单和 summary 优先，并压缩到六项事实后，固定三次检查仍只有一次通过：basic 使用无效引用、full-day 超过条目上限，重复 full-day 才通过。这个 1／3 是本次三项检查的结果，不是模型整体成功率估计；不得用重复尝试中偶然通过的一次覆盖失败记录。原 0.6B 推荐及资产信息保留在上文，作为研究与验证过程的历史记录。运行证据由主任务维护在 [本地 AI 验证记录](../verification/local-ai.md)。

根据这次实际质量证据，将默认下载候选改为 **`mlx-community/Qwen3-1.7B-4bit`**。这是继续验证的候选，不代表已经通过中文事实复盘验收。此次研究只读取公开元数据、模型卡、配置、许可证及小文件；未下载权重、构建或运行 1.7B。

| 固定项 | 1.7B 核查结果 |
| --- | --- |
| 应用模型 ID | `qwen3.1.7b.4bit` |
| 量化仓库 | `mlx-community/Qwen3-1.7B-4bit`，公开且非 gated |
| 量化 revision | `3b1b1768f8f8cf8351c712464f906e86c2b8269e` |
| 源模型及许可 revision | `Qwen/Qwen3-1.7B`，`70d244cc86ccca08cf5af4e1e306ecf908b1ad5e` |
| 权重文件 | `model.safetensors`，968,080,210 bytes |
| 权重 SHA-256 | `0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f` |
| 必须下载总量 | 11 个文件共 **984,025,460 bytes**，约 984.03 MB；含源模型 LICENSE，不含 `.gitattributes` |
| 上下文与许可证 | 官方模型卡标称 32,768 token，Apache License 2.0；不扩大首版短上下文预算 |

来源为 [固定量化配置](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/blob/3b1b1768f8f8cf8351c712464f906e86c2b8269e/config.json)、[量化仓库元数据](https://huggingface.co/api/models/mlx-community/Qwen3-1.7B-4bit?blobs=true)、[Qwen 官方固定模型卡](https://huggingface.co/Qwen/Qwen3-1.7B/blob/70d244cc86ccca08cf5af4e1e306ecf908b1ad5e/README.md) 与 [固定 LICENSE](https://huggingface.co/Qwen/Qwen3-1.7B/blob/70d244cc86ccca08cf5af4e1e306ecf908b1ad5e/LICENSE)。所有小文件已按固定 revision 在内存读取并计算 SHA-256；权重及 tokenizer 大文件的长度与 SHA-256 来自 HF 发布元数据。逐项清单固定在 [QwenAssetManifest.swift](../../Packages/MyEnergyLocalAI/Sources/MyEnergyLocalAI/QwenAssetManifest.swift)，下载实现仍会对实际收到的文件重新校验。

原始配置确认 `model_type` 为 `qwen3`，架构为 `Qwen3ForCausalLM`，量化为 4 bit／group size 64，28 层、8 个 KV heads、head dimension 128；hidden size 增为 2,048。这些配置可由当前 `Qwen3Configuration` 与 `Qwen3Model` 按文件解码，不需要更改 runtime API。tokenizer 与非思考模板的 SHA-256 和原 0.6B 资产相同，包含同一 `enable_thinking=false` 分支；实际加载、模板与生成仍须由主任务重新验证。[1.7B 固定配置](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/blob/3b1b1768f8f8cf8351c712464f906e86c2b8269e/config.json)、[固定 tokenizer 配置](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/blob/3b1b1768f8f8cf8351c712464f906e86c2b8269e/tokenizer_config.json)

本次默认资产比原清单增加 632,629,626 bytes，不能沿用 0.6B 的 351 MB 下载提示、实际速度或内存结果。配置中的 KV 维度未变，因此普通 FP16、batch 为 1 的 2,048 token KV 理论值仍约 224 MiB；总内存会包含更大的权重及临时运算，不能从这个理论值推算 iPhone 是否可用。1.7B 的 Mac 质量、内存、速度与 iPhone 真机资源条件均须单独记录；若仍不能稳定满足结构与事实依据要求，应明确保留不可用或未达标状态，不能放宽事实校验、猜测修正 ID 或自动重试直到通过。

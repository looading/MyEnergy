# 本机复盘模型

本 package 提供 `MyEnergyLocalAI` library 与 `MyEnergyAIProbe` 可执行探针。Apps 入口在主线程调用 `NativeLocalAI.install()`；该入口只为 iPhone 和 Mac 创建资产管理器并注册模型。iPad 注册空 runner 列表和 `modelAssets: nil`，不提供无用途的模型下载；Watch 不依赖这个 package。Core、UI 与 Platform 不反向依赖模型库。

设计、运行结果与未验证设备条件见[本地 AI 验证记录](../../docs/verification/local-ai.md)，公开资料依据见[本地模型备选](../../docs/research/local-model-fallback.md)。

## 固定资产与推理边界

- Apple runner 只选择 `SystemLanguageModel.default`，iOS／macOS 26 起运行时检查 availability 和 `zh-Hans` 支持。真实 `deviceNotEligible` 等原因会保留为不可用状态；每次请求新建结构化生成 session。没有云模型路径。
- MLX runner 只从 `QwenModelAssetStore.verifiedDirectory()` 加载本地文件，直接构造 `Qwen3Model`、加载 weights，并用 `AutoTokenizer.from(modelFolder:)` 分词。没有通过 Hub model ID 或 snapshot 隐式下载的路径。
- 固定 `mlx-community/Qwen3-1.7B-4bit` revision 为 `3b1b1768f8f8cf8351c712464f906e86c2b8269e`；清单全部文件逐项固定大小与 SHA-256，合计 984,025,460 bytes（包括源模型 LICENSE，不包含 `.gitattributes`）。URLSession 直接写磁盘，下载到临时目录；全部验证后以同一文件系统的目录 rename 启用。目录排除系统备份，取消／失败清理临时文件。
- 模型下载是用户主动操作。默认路径为当前用户 Application Support 下的 `MyEnergy/LocalAI/<revision>`，与应用记录、账号和同步数据分开。应用与 probe 共享同一根目录时使用文件锁，避免并发下载替换。
- 每次真实调用 chat template 时传入 `enable_thinking: false`，并验证渲染后的 assistant 前缀含空 think 区块；不会剥掉模型实际生成的思考内容来冒充已关闭。MLX 每阶段输入上限为 2,048 token；四阶段依次输出概述、观察、建议详情和标题，预算为 160／96／160／32 token，合计 448。达到预算而未见 EOS 时拒绝，不接受截断正文。系统模型单次输出仍限 512 token。
- 固定版本 `GenerateParameters` 提供 temperature／top-p，没有 top-k／min-p 参数。本实现设 temperature 0.2、top-p 0.8；没有声称完全复刻 Python sampler 的全部选项。
- 单 runner 同时只执行一次，逐 token 检查取消。每次 TokenIterator 新建 KV cache；只有权重与 tokenizer 缓存，用户输入和 KV 不保留在下一请求。结束时等待 GPU 完成，再清空空闲缓冲池。严重或临界热状态不开始，执行中进入任一状态也停止生成。
- 原生入口给 Apple／MLX 共用同一个 actor 执行名额；本机 UI 与远端 Hub 使用同一份已注册包装器。占用期间返回尚未开始的 `unavailable`，允许路由尝试 Mac，不在本设备排队。取消信号不提前释放名额，必须等待底层 `reflect` 退出并完成 GPU／KV 清理，再显式 `await release` 后把结果或错误交回调用方。CLI 每进程只有一个生成命令，直接调用底层 runner。
- MLX 的四段正文全部来自模型。应用提前选定单项事实供观察／建议使用，再构造字段和事实关联；标题根据同一事实及已验证建议详情概括。每段新 KV，标题看到的建议草稿不作为新增事实。写作目标与拒绝上限分开，具体规则见设计。
- 结果经过 Core 的结构、长度、事实 ID、请求 ID／digest 和有限医疗表达校验，再检查正文各字段含中文。验证失败抛错误，不用固定模板代替 AI。来源关联和中文字符检查不能证明语义质量，仍需场景验收。

默认不提高 iOS 进程内存限额，也没有承诺最低系统的所有设备均可运行。模型文件大小不等于峰值内存；GPU 指标不等于整个进程 RSS。模拟器不被当作 MLX 实测执行设备。Apple silicon Mac 与 iPhone 真机需要分别验证。

## 构建与探针命令

Metal shader 必须通过 Xcode／`xcodebuild` 编译。请先在本 package 目录查看可用 scheme，再构建探针；不要将普通 `swift run` 或 Core 单测当作模型可运行的证据。以下命令从仓库根目录执行。若 Xcode 明确报缺 Metal Toolchain，先运行官方 `xcodebuild -downloadComponent MetalToolchain`。

```sh
cd Packages/MyEnergyLocalAI
xcodebuild -list
xcodebuild -scheme MyEnergyAIProbe -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/MyEnergyAIProbeDerivedData build
```

探针默认只读自己定义的虚构事实，不打开 AppModel、记录数据库、HealthKit、钥匙串或同步服务。可以通过 `--assets` 指定隔离目录，使验证不改动应用默认资产。

```sh
DYLD_FRAMEWORK_PATH=/tmp/MyEnergyAIProbeDerivedData/Build/Products/Debug /tmp/MyEnergyAIProbeDerivedData/Build/Products/Debug/MyEnergyAIProbe status --assets /tmp/MyEnergyAIProbeAssets
DYLD_FRAMEWORK_PATH=/tmp/MyEnergyAIProbeDerivedData/Build/Products/Debug /tmp/MyEnergyAIProbeDerivedData/Build/Products/Debug/MyEnergyAIProbe download --assets /tmp/MyEnergyAIProbeAssets
DYLD_FRAMEWORK_PATH=/tmp/MyEnergyAIProbeDerivedData/Build/Products/Debug /tmp/MyEnergyAIProbeDerivedData/Build/Products/Debug/MyEnergyAIProbe generate --assets /tmp/MyEnergyAIProbeAssets --scenario basic
DYLD_FRAMEWORK_PATH=/tmp/MyEnergyAIProbeDerivedData/Build/Products/Debug /tmp/MyEnergyAIProbeDerivedData/Build/Products/Debug/MyEnergyAIProbe generate --assets /tmp/MyEnergyAIProbeAssets --scenario full-day
```

`status` 只报告资产、模型能力与系统模型实际不可用原因。`download` 在 stderr 输出粗粒度进度；stdout 返回状态，不打印签名下载 URL。`generate` 默认使用 MLX，返回虚构事实生成的结果与指标，其中 `thinkingDisabled` 只有在真实模板分支检查及结果验证通过后才会出现。`basic` 使用两条精力记录的汇总与一项匿名习惯事实；`full-day` 从合成 AppSnapshot 整理较多精力／心情、习惯和手动睡眠，备注与习惯原名不会进入输入。`totalElapsedSeconds` 包含加载，metrics 的耗时包含四阶段生成与结果验证，inputTokens／outputTokens 为四段总和（不是单阶段输入上限）；peakActiveMemoryBytes 为本进程 MLX 的累计峰值，不是 RSS。

在资产验证成功之后断开网络，再运行同一条 `generate` 命令检查离线生成。系统本机模型可单独用下列命令探测与生成；若设备不满足要求，应得到真实不可用错误，不能换成模拟输出。

```sh
DYLD_FRAMEWORK_PATH=/tmp/MyEnergyAIProbeDerivedData/Build/Products/Debug /tmp/MyEnergyAIProbeDerivedData/Build/Products/Debug/MyEnergyAIProbe generate --system --assets /tmp/MyEnergyAIProbeAssets
```

SwiftPM／Xcode 的实际 scheme 名与产物路径仍须以本机 `xcodebuild -list`、构建日志为准。若未生成所示可执行产物，先处理构建或 shader bundle 条件，不把空跑或未匹配测试记录为推理成功。依赖首次解析由 root 调度，解析出的完整 `Package.resolved` 应随交付保存。

`MyEnergyLocalAITests` 使用确定性 fake runner 和小型内存资产，不加载模型、不联网下载。用例覆盖不同模型不能并发、成功／失败释放执行名额、旧任务取消但尚未完成清理时继续拒绝新任务，以及 iPad／Watch 注册空 runner 和空下载管理器。资产用例另覆盖 hash、目录完整性、符号链接、并发与取消清理。测试使用 Swift package 的聚合 scheme；library scheme 本身不配置 Test action：

```sh
xcodebuild -scheme MyEnergyLocalAI-Package -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/MyEnergyAIProbeDerivedData -enableCodeCoverage NO -only-testing:MyEnergyLocalAITests test
```

## 许可与交付检查

模型源自 Qwen3-1.7B，许可证为 Apache 2.0。固定 LICENSE 来自 Qwen 官方 revision，作为必须校验的下载资产保留；量化模型自身 README 一并保留。runtime 的 MIT 许可与后续解析的传递依赖见 [第三方声明](THIRD_PARTY.md)。[Qwen 固定 LICENSE](https://huggingface.co/Qwen/Qwen3-1.7B/blob/70d244cc86ccca08cf5af4e1e306ecf908b1ad5e/LICENSE)、[量化发布说明](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/blob/3b1b1768f8f8cf8351c712464f906e86c2b8269e/README.md)

验收范围包括：下载大小／hash 失败、不完整目录和 symlink 拒绝、下载取消后不 ready、真实非思考模板、虚构事实生成、2,048 token 拒绝边界、无效 JSON／未知事实拒绝、生成取消和 GPU 完成、中文质量、连续生成内存／热状态，以及最低 iOS／macOS 真机条件。FoundationModels 的 availability 与 MLX 的可运行性分别报告。

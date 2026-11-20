# Apple 本地 AI 可行性

核查日期：2026-11-20，Asia/Shanghai。范围是首版“每日复盘与习惯建议”，优先使用 iPhone 本机推理，Mac 本机推理作为另一可用入口。本文只引用 Apple 官方文档、官方样例与本机 Apple SDK；没有读取账户令牌、证书或真实健康样本，没有操作 UI、运行模型、构建或执行测试。

## 首版可以接入，但必须允许模型不可用

**文档事实。** `FoundationModels` 提供 Apple Intelligence 的系统端侧文本模型；`SystemLanguageModel.default` 配合 `LanguageModelSession` 可进行生成、摘要和结构化输出。模型就绪后可以离线运行，不需要应用配置模型服务账户或 API key。模型资源由系统提供，不增加应用自身的模型包体积。[生成与会话](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)、[Apple 官方 code-along](https://developer.apple.com/videos/play/meet-with-apple/205/)

**设计建议。** 将它作为可选增强能力。记录、习惯和确定性统计继续独立工作；“本地 AI 不可用”“模型准备中”“当前语言不支持”“本次生成失败”分别显示。规则生成的文字须标成规则建议，不能用它冒充 AI 已完成。本文没有选择云模型，也没有把系统端侧模型可用作为产品前提。

## 本机 SDK 已有接口，运行条件仍未核实

2026-11-20 的只读命令结果是 Xcode **27.2，27B52**，Apple Swift **6.4.2**。iPhoneOS 与 macOS SDK 均为 **27.2**。两个 SDK 的 FoundationModels 模块都存在，声明了下列接口。这些证据证明本机有 API 声明；不证明当前 Mac 或任何 iPhone 已下载模型、符合地区条件或能成功推理。

| 接口 | 本机 27.2 SDK 声明 | 使用含义 |
| --- | --- | --- |
| `SystemLanguageModel`、`default`、`availability`、`isAvailable` | iOS 26.0、macOS 26.0、visionOS 26.0 起 | app 仍支持更旧系统时须做编译和运行时可用性保护 |
| `LanguageModelSession(model:instructions:)`、`respond(to:generating:...)` | 系统模型路径从 iOS／macOS 26.0 起 | `import FoundationModels`，异步生成，读取 `response.content` |
| `@Generable`、`@Guide` | iOS／macOS 26.0 起 | 定义 Swift 输出 schema |
| `SystemLanguageModel.supportsLocale(_:)` | iOS／macOS 26.0 起 | 同步返回 `Bool`，包含语言 fallback 判定 |
| `SystemLanguageModel.contextSize` | 可回部署到 iOS／macOS 26.0 | 27 以前的 getter 返回 4096；27 起读取实际运行时值 |
| `tokenCount(for:)` | iOS／macOS 26.4 起 | 可计算 prompt、instructions、schema、tools 或 transcript 的 token 数 |
| `LanguageModel`、`LanguageModelCapabilities` | iOS／macOS 27.0 起 | 新增自定义模型接入协议，不能套用 26 时代的能力判断 |

SDK 原始证据：[iPhoneOS 接口](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.2.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface:258)、[macOS 接口](/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk/System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface:258)。在线交叉来源：[SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)、[supportsLocale](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/supportslocale(_:))、[contextSize](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize)、[LanguageModel](https://developer.apple.com/documentation/foundationmodels/languagemodel)。SDK 链接是本机安装路径，其他机器上不一定存在。

**平台边界。** `SystemLanguageModel` 在本机 SDK 明确标记 `watchOS`、`tvOS` unavailable。27 中 `LanguageModelSession` 有 watchOS 接口，不表示 Watch 能运行 Apple 系统端侧模型。Apple 当前兼容表也把 Watch 的 AFM Core／Core Advanced 都列为不支持。[模型与设备兼容表](https://developer.apple.com/documentation/foundationmodels/detecting-available-apple-foundation-models)

**设计建议。** 原有 iOS 17／macOS 14／watchOS 10 的基础功能最低版本可保留，AI provider 只在 iOS／macOS 26 及以上创建，Watch 显示已有结果或明确的未生成状态。是否提高整个 app 的最低版本属于独立产品决定。

## 可用性需要逐次检查

`isAvailable` 只是布尔快捷值。要给用户可操作的说明，应检查 `model.availability`；SDK 当前有 `.available` 和 `.unavailable(reason)`，不可用原因包含下表三项。原因枚举需要保留未知分支。[availability 与原因](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason)、[Apple 官方可用性样例](https://developer.apple.com/documentation/foundationmodels/adding-intelligent-app-features-with-generative-models)

| 系统状态 | 已核实含义 | 建议产品行为 |
| --- | --- | --- |
| `.available` | 系统目前可接受请求 | 继续检查输出语言，再生成；仍处理生成阶段错误 |
| `.deviceNotEligible` | 设备不符合 Apple Intelligence 条件 | 说明此设备当前无法使用系统本地 AI；不要仅凭此原因断言是某种芯片或某个地区 |
| `.appleIntelligenceNotEnabled` | 系统未启用 Apple Intelligence | 对 26 系统解释设置要求；避免在 27 上持续提示用户寻找已经不存在的关闭开关 |
| `.modelNotReady` | 模型资源尚不可用 | 显示准备中与稍后重试，不把它当成 app 安装失败或模型永久不支持 |
| 未知原因 | 后续系统新增原因或未覆盖情形 | 保留基础功能，允许用户重试 |

Apple 明确说明模型下载会受网络、电量和系统负载等因素影响；系统升级也可能更新模型资源。应用不能把 `.modelNotReady` 解释成“下载了某个百分比”。[modelNotReady](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason/modelnotready)、[可用性处理](https://developer.apple.com/documentation/foundationmodels/detecting-available-apple-foundation-models)

**版本差异。** Apple 当前文档说明：26 系统可能需要用户开启 Apple Intelligence；在 iOS／iPadOS／macOS／visionOS 27 及以后，Apple Intelligence 默认开启且不能关闭。旧的 `appleIntelligenceNotEnabled` 枚举仍存在于 27.2 SDK，兼容层仍需处理，UI 文案须区分系统版本。[不可用原因处理的版本说明](https://developer.apple.com/documentation/foundationmodels/detecting-available-apple-foundation-models)

## 支持中文不代表中国大陆可用

Apple Support 当前页面发布于 **2026-11-05**。对 iPhone，它列出 iPhone 15 Pro／Pro Max、iPhone 16 及后续受支持机型等；Mac 包括 M1 及后续机型，以及 MacBook Neo（A18 Pro）。设备／Siri 语言需要匹配且受支持，存储空间也会影响条件。简体和繁体中文在支持语言之列，具体功能仍随地区、语言和平台变化。[设备、语言、存储条件](https://support.apple.com/en-us/121115)

同一官方页仍明确：**中国大陆购买的受支持设备目前无法使用 Apple Intelligence；大陆境外购买的设备，若人在中国大陆且 Apple 账户国家或地区也设为中国大陆，目前同样无法使用。** 因此，不能向大陆用户承诺“升级到 26／27 就能运行”。本文没有根据媒体、测试版消息或未来发布计划推定限制已经解除，也不建议通过改账户地区来解决产品依赖。[中国大陆条件](https://support.apple.com/zh-cn/121115)

语言必须单独检查。Apple 建议使用 `supportsLocale(_:)` 而不是简单匹配 `supportedLanguages`，因为前者考虑语言 fallback。即便设备界面是中文，也不能跳过该判定。[语言检查方法](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/supportslocale(_:))

**待验证。** 本轮没有检查用户设备购买地区、账户地区、系统模型状态或实际语言；不保存这些个人条件的具体值。未来验收只记录必要条件和“通过／未通过”，不记录账户标识。

## 离线推理和上下文长度各有条件

**文档事实。** 系统端侧模型可以离线推理，但模型首次下载和系统更新后的资源准备与“已经就绪后的离线请求”是两件事。使用者工具若自行访问网络，也不因模型在本地就变成离线。本功能不注册网络工具。[端侧模型的离线性质](https://developer.apple.com/videos/play/wwdc2025/286/)、[模型资源准备](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason/modelnotready)

Apple 当前上下文管理文档写明系统端侧模型为 **4096 tokens／session**。它计入 instructions、全部 prompts、schema、tools 的定义／输入／输出，以及所有模型响应。中文通常约一字一个 token，因此“4096 tokens”不能换成“可输入4096字”。本机 27.2 SDK 又提供动态的 `contextSize` getter，产品应读取运行时值，按实际模型预算，不把 4K 写成对所有后续模型的承诺。[上下文管理](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)、[contextSize](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize)

**设计建议。** 每次每日复盘新建 session，只传当天的精力／心情、习惯完成情况及必要的简短事实，不传全部历史或原始健康样本。先做确定性摘要，保留缺失状态。初版可先将自由备注限制为 600 个字符，并限制两条建议；600 是应用的保守起始预算，不是 Apple 的输入上限。26.4 及以上可用 `tokenCount(for:)` 计算输入与 schema 成本，并为输出留空间；26.0–26.3 维持短输入且处理超限。字符数上限本身不能保证 token 不超限。

## 结构化输出仍须核对内容

`@Generable` 定义输出类型，`@Guide` 可限制数组个数或数值范围；`session.respond(to:generating:)` 返回该类型。系统 guided generation 采用 constrained sampling，提供符合 schema 的结构，不等于事实、建议或语义正确。[Generable 与 guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)

**设计建议。** 输出只含短复盘、至多两条可选习惯建议和引用的输入事实 ID。代码核对事实 ID 确实在本次输入中、建议非空且不过长。分数、完成率、时长和缺失状态由确定性代码计算；模型只改写已经提供的事实。精力、心情与身体参考保持独立，不从 HRV 推断情绪，不生成诊断、疾病风险或治疗建议。结构或内容校验未通过时保留原记录，并显示本次复盘未完成。

## 最小 Native provider 草图

以下是 API 形状草图，**未编译、未运行**。正式实现仍需项目现有协议、取消／并发、输入预算及错误映射；框架调用路径有官方样例支持。[官方生成样例](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)、[官方结构化输出样例](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)

```swift
#if canImport(FoundationModels) && !os(watchOS) && !os(tvOS)
import Foundation
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct DailyReflectionDraft {
    var summary: String
    @Guide(.maximumCount(2))
    var suggestions: [String]
    var evidenceIDs: [String]
}

@available(iOS 26.0, macOS 26.0, *)
enum NativeReflectionError: Error {
    case deviceNotEligible
    case intelligenceNotEnabled
    case modelNotReady
    case unknownAvailability
    case unsupportedLocale
}

@available(iOS 26.0, macOS 26.0, *)
actor NativeReflectionProvider {
    // 每次调用创建独立会话；外层仍需限制并发任务数。
    func generate(
        preparedFacts: String,
        outputLocale: Locale
    ) async throws -> DailyReflectionDraft {
        try Task.checkCancellation()
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw NativeReflectionError.deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            throw NativeReflectionError.intelligenceNotEnabled
        case .unavailable(.modelNotReady):
            throw NativeReflectionError.modelNotReady
        case .unavailable:
            throw NativeReflectionError.unknownAvailability
        }
        guard model.supportsLocale(outputLocale) else {
            throw NativeReflectionError.unsupportedLocale
        }
        // 外层先完成敏感字段筛选、事实编号和 token 预算。
        let session = LanguageModelSession(
            model: model,
            instructions: """
            只根据输入事实写简短的每日复盘和至多两条可选习惯建议。
            输出使用 \(outputLocale.identifier) 对应的语言。
            保留缺失与不确定状态。不得推断疾病、情绪成因或给出治疗意见。
            evidenceIDs 只能使用输入中已有的事实编号。
            """
        )
        let response = try await session.respond(
            to: preparedFacts,
            generating: DailyReflectionDraft.self
        )
        try Task.checkCancellation()
        // 返回后仍由外层校验内容、事实编号和当前数据空间。
        return response.content
    }
}
#endif
```

错误映射须按 OS 版本覆盖。在本机 27.2 SDK，`LanguageModelSession.GenerationError` 从 27 起 deprecated；新接口包含 `LanguageModelError.contextSizeExceeded`、`guardrailViolation`、`refusal`、`unsupportedLanguageOrLocale`、`timeout` 等，资源错误为 `SystemLanguageModel.Error.assetsUnavailable`，并发错误为 `LanguageModelSession.Error.concurrentRequests`。支持 26 的实现要同时处理旧错误；不能只根据旧博客里的 `GenerationError` 编写最新分支。[27 的 LanguageModelError](https://developer.apple.com/documentation/foundationmodels/languagemodelerror)、[旧错误的迁移说明](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror)、[本机 SDK 旧错误与重命名](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.2.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface:3718)

## 自定义模型要按 26 和 27 分开判断

**26 系统。** 自定义 adapter 是对特定系统模型版本的适配，不是把任意 GGUF／其他权重交给 `SystemLanguageModel`。Apple 文档要求每个 adapter 匹配单个系统模型版本；正式分发需要专用 entitlement。当前 adapter toolkit 页面注明 26.0.0 是最后版本，**不兼容 OS 27 及以后**；本机 SDK 的 `SystemLanguageModel(adapter:)` 也在 27 obsoleted。[Apple adapter 工具与限制](https://developer.apple.com/apple-intelligence/foundation-models-adapter/)、[本机 SDK adapter 初始化声明](/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.2.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface:391)

**27 系统。** 当前官方 `LanguageModel` 协议允许将自定义模型桥接进同一 session API。Apple 官方 `coreai-models` 提供 `CoreAILanguageModel`，可加载按平台导出的本地资源，要求 iOS／macOS 27、Xcode 27 及以后。应用需要另行提供模型、tokenizer 和相关资源；这不代表 FoundationModels 内置了任意第三方权重加载器。[LanguageModel 协议](https://developer.apple.com/documentation/foundationmodels/languagemodel)、[Apple 官方 Core AI 接入说明](https://developer.apple.com/documentation/foundationmodels/running-a-core-ai-model-in-a-foundation-models-session)、[Apple 官方 coreai-models 仓库](https://github.com/apple/coreai-models)

自定义模型的 `.guidedGeneration`、`.toolCalling` 等能力须检查 `capabilities`。能力不足时框架可以拒绝分派并抛 `unsupportedCapability`；不能因为仍调用 `respond(generating:)` 就承诺任意模型都有系统模型相同的结构约束。[LanguageModelCapabilities](https://developer.apple.com/documentation/foundationmodels/languagemodelcapabilities)

**设计建议。** 首版先接系统模型并交付明确的不可用状态。自带模型需要另立工作包，核实模型许可、中文质量、各端包体／存储／内存／功耗及具体设备覆盖。本轮未下载、挑选或集成权重，也没有把自定义模型当成已解决中国大陆可用性的路径。

## iPhone 优先需要应用明确编排

**文档事实。** `SystemLanguageModel` 是调用所在设备上的系统模型。Apple 保证每台设备仅有系统选择的一个模型版本／variant，app 不能指定下载另一个系统 variant。[模型 variant 与版本](https://developer.apple.com/documentation/foundationmodels/detecting-available-apple-foundation-models)

**设计推断。** FoundationModels 的上述 API 不提供“自动将 iPhone 请求转发给 Mac”的承诺。优先在 iPhone 本地生成；Mac 在自身符合条件时本地生成。两端可使用相同 provider 契约。若后续要求 iPhone 调用家中 Mac 推理，需要另行设计发现、配对、加密、用户授权、请求过期与返回结果隔离，不能悄悄把健康上下文发送到 Mac 或既有云服务。没有可达的 Mac 时，不宣称已经完成回退。Watch／iPad 显示结果的传输也沿用已授权的数据范围。

## 验收要分别留下证据

| 层次 | 可验证内容 | 本轮结果 |
| --- | --- | --- |
| 官方资料与 SDK | 平台最低版本、状态枚举、签名、27 接口变化 | 已核实；命令与 SDK 路径见上文 |
| 单元层 | 注入 provider，覆盖可用、各不可用原因、语言不支持、超长输入、取消、失败、未知状态 | 未运行；此类测试只能验证应用逻辑 |
| 构建层 | iOS／macOS 26 可用性保护、Watch 排除、27 新旧错误处理 | 未构建 |
| 本机真实模型 | 经用户授权后检查当前 Mac 的 availability、语言与一条合成输入实际生成 | 未运行；SDK 存在不能替代 |
| iPhone 真实模型 | 记录设备／OS 必要条件、实际可用性与合成输入结构化响应 | 未运行；模拟器不替代真机 |
| 离线 | 已完成模型准备后，断网用合成输入成功生成；资源尚未就绪时正确降级 | 未运行 |
| 数据与质量 | 缺失不补造、事实 ID 合法、无医学判断、跨空间／删除后的晚到结果丢弃 | 设计要求，未验收 |
| Mac 回退 | 明确是在 Mac 自身生成，或独立验证过配对本地通道、超时和设备离线 | 未实现／未验收 |

后续测试只使用清楚标记的合成事实；日志仅记录状态、耗时和必要计数，不记录 prompt、生成全文、健康原始数据或账户标识。模型、OS 与语言会变化，提示词和质量样例需要随版本复核。[Apple 模型版本管理](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)

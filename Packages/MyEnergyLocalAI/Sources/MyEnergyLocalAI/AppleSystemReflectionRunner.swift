import Foundation
import MyEnergyCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 只使用系统本机模型；不选择 Private Cloud Compute 或外部推理服务。
public actor AppleSystemReflectionRunner: LocalAIRunner {
  public nonisolated let executor: LocalAIExecutor
  private var isGenerating = false

  public init(role: LocalAIDeviceRole, deviceID: String) {
    self.executor = LocalAIExecutor(id: "\(deviceID).apple", role: role, modelID: "apple.system",
      modelName: "Apple 系统本机模型", isRemote: false)
  }

  public func availability() async -> LocalAIAvailability {
    guard executor.role == .iPhone || executor.role == .mac else { return .unavailable("本设备不承接模型推理。") }
    guard !isGenerating else { return .unavailable("本设备正在处理上一项复盘。") }
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      let model = SystemLanguageModel.default
      switch model.availability {
      case .available:
        guard model.supportsLocale(Locale(identifier: "zh-Hans")) else {
          return .unavailable("系统本机模型当前不支持所需的中文。")
        }
        return .ready
      case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible: return .unavailable("deviceNotEligible：设备不满足系统模型要求。")
        case .appleIntelligenceNotEnabled: return .unavailable("Apple Intelligence 尚未启用或当前地区不可用。")
        case .modelNotReady: return .unavailable("系统模型尚未就绪。")
        @unknown default: return .unavailable("系统本机模型当前不可用。")
        }
      }
    }
    #endif
    return .unavailable("系统模型需要 iOS 26 或 macOS 26 及受支持设备。")
  }

  public func reflect(_ request: DailyReflectionRequest) async throws -> DailyReflectionResult {
    try Task.checkCancellation()
    try request.validated()
    if case .unavailable(let reason) = await availability() { throw LocalAIError.unavailable(reason) }
    guard !isGenerating else { throw LocalAIError.generationFailed("本设备已经开始另一项复盘。") }
    isGenerating = true
    defer { isGenerating = false }
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      do {
        // 每次新建 session，禁止上次用户记录进入下一次请求。
        let session = LanguageModelSession(model: SystemLanguageModel.default,
          instructions: DailyReflectionPrompt.instructions)
        let response = try await session.respond(to: DailyReflectionPrompt.userPrompt(for: request),
          generating: SystemReflectionDraft.self, options: GenerationOptions(maximumResponseTokens: 512))
        try Task.checkCancellation()
        let content = response.content
        let draft = try DailyReflectionDraft(overview: content.overview,
          observations: content.observations.map { DailyReflectionObservation(text: $0.text, factIDs: $0.factIDs) },
          suggestions: content.suggestions.map {
            DailyHabitSuggestion(title: $0.title, detail: $0.detail, factIDs: $0.factIDs)
          }).validated(for: request.input)
        try ChineseReflectionValidation.validate(draft)
        return try DailyReflectionResult(requestID: request.id, inputDigest: request.input.digest,
          executor: executor, generatedAt: Date(), draft: draft).validated(for: request)
      } catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        if let error = error as? LocalAIError { throw error }
        throw LocalAIError.generationFailed("系统本机模型未能完成本次复盘，请重试。")
      }
    }
    #endif
    throw LocalAIError.generationFailed("系统模型在生成开始后不可用，请重新发起复盘。")
  }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct SystemReflectionObservation {
  @Guide(description: "只依据本次事实写一条简短中文观察。") var text: String
  @Guide(description: "引用本次已有事实 ID，至少一项，不得编造。") var factIDs: [String]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct SystemHabitSuggestion {
  @Guide(description: "中文的可选习惯建议标题。") var title: String
  @Guide(description: "中文的低负担小行动，不提供医疗判断。") var detail: String
  @Guide(description: "引用本次已有事实 ID，至少一项，不得编造。") var factIDs: [String]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct SystemReflectionDraft {
  @Guide(description: "简短中文概述，只根据本次记录。") var overview: String
  @Guide(description: "零至三条有事实依据的中文观察。", .maximumCount(3))
  var observations: [SystemReflectionObservation]
  @Guide(description: "零至两条可选的小习惯建议。", .maximumCount(2))
  var suggestions: [SystemHabitSuggestion]
}
#endif

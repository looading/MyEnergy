import Foundation
import Metal
@preconcurrency import MLX
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import MyEnergyCore
@preconcurrency import Tokenizers

public struct MLXReflectionMetrics: Codable, Sendable {
  public let thinkingDisabled: Bool
  public let inputTokens: Int
  public let outputTokens: Int
  public let elapsedSeconds: Double
  public let peakActiveMemoryBytes: Int
}

/// 每次请求创建新 KV cache；actor 只缓存无用户会话的权重和分词器。
public actor MLXReflectionRunner: LocalAIRunner {
  public nonisolated let executor: LocalAIExecutor
  private let assets: QwenModelAssetStore
  private var context: ModelContext?
  private var isGenerating = false
  private var metrics: MLXReflectionMetrics?
  public static let maximumInputTokens = 2_048
  public static let maximumOutputTokens = 448

  public init(role: LocalAIDeviceRole, deviceID: String, assets: QwenModelAssetStore) {
    self.assets = assets
    self.executor = LocalAIExecutor(id: "\(deviceID).qwen", role: role,
      modelID: QwenAssetManifest.modelID, modelName: "Qwen3 1.7B · 4-bit", isRemote: false)
  }

  public func availability() async -> LocalAIAvailability {
    guard executor.role == .iPhone || executor.role == .mac else { return .unavailable("本设备不承接模型推理。") }
    #if targetEnvironment(simulator)
    return .unavailable("模拟器不作为离线模型推理设备，请使用 iPhone 真机或 Apple silicon Mac。")
    #else
    #if os(macOS) && !arch(arm64)
    return .unavailable("离线模型当前只支持 Apple silicon Mac。")
    #else
    guard MTLCreateSystemDefaultDevice() != nil else { return .unavailable("当前设备没有可用的 Metal GPU。") }
    guard !isGenerating else { return .unavailable("本设备正在处理上一项复盘。") }
    guard ProcessInfo.processInfo.thermalState != .serious,
          ProcessInfo.processInfo.thermalState != .critical else { return .unavailable("设备温度较高，请稍后重试。") }
    guard case .ready = await assets.status() else { return .unavailable("请先主动下载并校验离线模型。") }
    return .ready
    #endif
    #endif
  }

  public func reflect(_ request: DailyReflectionRequest) async throws -> DailyReflectionResult {
    try Task.checkCancellation()
    try request.validated()
    let plan = try SmallModelReflectionPlan(input: request.input)
    guard plan.stages.reduce(0, { $0 + $1.maximumOutputTokens }) <= Self.maximumOutputTokens else {
      throw LocalAIError.generationFailed("小模型分段配置超过总输出预算。")
    }
    if case .unavailable(let reason) = await availability() { throw LocalAIError.unavailable(reason) }
    // availability 跨 actor 等待期间可能已有另一次请求开始；不并发使用同一份权重。
    guard !isGenerating else { throw LocalAIError.generationFailed("本设备已经开始另一项复盘。") }
    isGenerating = true
    metrics = nil
    defer {
      isGenerating = false
      // generate 已同步 GPU，局部 KV 已释放；清掉空闲缓存，不保存用户上下文。
      GPU.clearCache()
    }
    do {
      _ = try await loadedContext()
      try Task.checkCancellation()
      let started = Date()
      let generated = try await plan.run { stage in
        try await self.generate(stage)
      }
      try Task.checkCancellation()
      metrics = MLXReflectionMetrics(thinkingDisabled: true, inputTokens: generated.inputTokens,
        outputTokens: generated.outputTokens, elapsedSeconds: Date().timeIntervalSince(started),
        peakActiveMemoryBytes: GPU.peakMemory)
      return try DailyReflectionResult(requestID: request.id, inputDigest: request.input.digest,
        executor: executor, generatedAt: Date(), draft: generated.draft).validated(for: request)
    } catch {
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      if let error = error as? LocalAIError { throw error }
      // 上游错误可能含路径或生成片段，不直接显示或记录。
      throw LocalAIError.generationFailed("离线模型未能完成本次复盘，请重试。")
    }
  }

  public func lastMetrics() -> MLXReflectionMetrics? { metrics }

  /// 只读取经过校验的本地文件；不调用 Hub snapshot、远程 model ID 或自动下载。
  private func loadedContext() async throws -> ModelContext {
    if let context { return context }
    let directory = try await assets.verifiedDirectory()
    let configurationData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
    let configuration = try JSONDecoder().decode(Qwen3Configuration.self, from: configurationData)
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: configurationData)
    guard base.modelType == "qwen3" else { throw LocalAIError.generationFailed("离线模型配置不符合固定模型。") }
    let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
    try Task.checkCancellation()
    // 缓冲池有界；不通过提高 iOS 进程内存上限来掩盖设备限制。
    GPU.set(cacheLimit: 32 * 1_024 * 1_024)
    let model = Qwen3Model(configuration)
    try loadWeights(modelDirectory: directory, model: model, perLayerQuantization: base.perLayerQuantization)
    let loaded = ModelContext(configuration: .init(directory: directory,
      extraEOSTokens: ["<|im_end|>", "<|endoftext|>"]), model: model,
      processor: StandInUserInputProcessor(), tokenizer: tokenizer)
    self.context = loaded
    return loaded
  }

  private func generate(_ stage: SmallModelStageRequest) throws -> SmallModelGeneratedText {
    try ensureGenerationCanContinue()
    guard let context else { throw LocalAIError.generationFailed("离线模型尚未完成加载。") }
    let messages: [[String: any Sendable]] = [
      ["role": "system", "content": stage.instructions],
      ["role": "user", "content": stage.userPrompt]
    ]
    let tokens = try context.tokenizer.applyChatTemplate(messages: messages, chatTemplate: nil,
      addGenerationPrompt: true, truncation: false, maxLength: nil, tools: nil,
      additionalContext: ["enable_thinking": false])
    // 验证真实模板分支，不能仅在展示时剥除模型生成的思考内容。
    let rendered = context.tokenizer.decode(tokens: tokens)
    guard rendered.contains(stage.instructions), rendered.contains(stage.userPrompt) else {
      throw LocalAIError.generationFailed("离线模型模板未完整保留本段系统指令与用户资料。")
    }
    guard rendered.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n") else {
      throw LocalAIError.generationFailed("离线模型的非思考模板验证失败。")
    }
    guard !tokens.isEmpty, tokens.count <= Self.maximumInputTokens else {
      throw LocalAIError.invalidInput("本次事实超过离线模型 2,048 token 输入预算，请减少当天记录范围。")
    }
    try ensureGenerationCanContinue()
    let parameters = GenerateParameters(maxTokens: stage.maximumOutputTokens,
      temperature: 0.2, topP: 0.8, prefillStepSize: 256)
    let input = LMInput(tokens: MLXArray(tokens))
    defer { Stream().synchronize() }
    let iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
    let stopIDs = Set(["<|im_end|>", "<|endoftext|>"].compactMap { context.tokenizer.convertTokenToId($0) })
    var output = [Int]()
    var endedWithEOS = false
    for token in iterator {
      try ensureGenerationCanContinue()
      if token == context.tokenizer.eosTokenId || stopIDs.contains(token) {
        endedWithEOS = true
        break
      }
      output.append(token)
      if output.count >= stage.maximumOutputTokens { break }
    }
    try ensureGenerationCanContinue()
    guard endedWithEOS else { throw LocalAIError.generationFailed("小模型分段未在 token 预算内正常结束。") }
    let text = context.tokenizer.decode(tokens: output)
    guard text.utf8.count <= 16 * 1_024 else { throw LocalAIError.invalidOutput("模型返回内容过长。") }
    return SmallModelGeneratedText(text: text, inputTokens: tokens.count, outputTokens: output.count, endedWithEOS: endedWithEOS)
  }

  private func ensureGenerationCanContinue() throws {
    try Task.checkCancellation()
    let thermalState = ProcessInfo.processInfo.thermalState
    guard thermalState != .serious, thermalState != .critical else {
      throw LocalAIError.generationFailed("设备温度较高，已停止本次生成。")
    }
  }
}

enum ChineseReflectionValidation {
  static func validate(_ draft: DailyReflectionDraft) throws {
    let fields = [draft.overview] + draft.observations.map(\.text)
      + draft.suggestions.flatMap { [$0.title, $0.detail] }
    guard fields.allSatisfy({ text in text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } }) else {
      throw LocalAIError.invalidOutput("本次生成未按要求使用中文，请重试。")
    }
  }
}

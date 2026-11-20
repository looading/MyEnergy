import Foundation

/// 手机优先、同类设备系统模型优先；开始执行后的失败不自动改派。
public enum LocalAIRouter {
  public static func generate(_ request: DailyReflectionRequest, runners: [any LocalAIRunner]) async throws -> DailyReflectionResult {
    try Task.checkCancellation()
    try request.validated()
    guard !request.input.facts.isEmpty else {
      throw LocalAIError.invalidInput("当天还没有可供复盘的事实，请先记下一项精力、习惯或手动睡眠。")
    }
    let eligible = runners.enumerated().filter { _, runner in
      runner.executor.role == .iPhone || runner.executor.role == .mac
    }.sorted { left, right in
      let leftRank = rank(left.element.executor)
      let rightRank = rank(right.element.executor)
      if leftRank != rightRank { return leftRank < rightRank }
      return left.offset < right.offset
    }
    var reasons: [String] = []
    for (_, runner) in eligible {
      try Task.checkCancellation()
      let executor = runner.executor
      let label = "\(executor.role == .iPhone ? "iPhone" : "Mac") · \(executor.modelName)"
      let availability = await runner.availability()
      try Task.checkCancellation()
      if case .unavailable(let reason) = availability {
        reasons.append("\(label)：\(reason.isEmpty ? "暂未就绪" : String(reason.prefix(500)))")
        continue
      }
      do {
        let result = try await runner.reflect(request)
        try Task.checkCancellation()
        try result.validated(for: request)
        guard result.executor == executor else {
          throw LocalAIError.invalidOutput("返回的执行设备或模型与本次选定执行器不一致。")
        }
        return result
      } catch LocalAIError.unavailable(let reason) {
        try Task.checkCancellation()
        reasons.append("\(label)：\(reason.isEmpty ? "暂未就绪" : String(reason.prefix(500)))")
      } catch {
        // 远端状态不明、输出错误、执行失败以及 CancellationError 都保留原类型。
        try Task.checkCancellation()
        throw error
      }
    }
    try Task.checkCancellation()
    let reason = reasons.isEmpty
      ? "没有已授权且就绪的 iPhone 或 Mac 执行器；iPad 和 Watch 首版不执行模型。"
      : reasons.joined(separator: "\n")
    throw LocalAIError.unavailable(reason)
  }

  private static func rank(_ executor: LocalAIExecutor) -> Int {
    let deviceRank = executor.role == .iPhone ? 0 : 2
    return deviceRank + (executor.modelID.hasPrefix("apple.") ? 0 : 1)
  }
}

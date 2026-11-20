import Foundation
import MyEnergyCore

/// 一个原生注册实例内的所有模型和调用入口共用一个执行名额，不排队、不提前释放取消中的任务。
actor LocalAIExecutionGate {
  private var lease: UUID?
  static let busyReason = "本设备正在处理上一项复盘，或等待其取消清理完成。"

  func isOccupied() -> Bool { lease != nil }

  func acquire() throws -> UUID {
    try Task.checkCancellation()
    guard lease == nil else { throw LocalAIError.unavailable(Self.busyReason) }
    let acquired = UUID()
    lease = acquired
    return acquired
  }

  func release(_ acquired: UUID) {
    guard lease == acquired else { return }
    lease = nil
  }
}

/// 本机 UI 与远端 Hub 都使用注册的这个包装器，因此 Apple 和 MLX 也不能同时开始。
struct LeasedLocalAIRunner: LocalAIRunner {
  let base: any LocalAIRunner
  let gate: LocalAIExecutionGate
  var executor: LocalAIExecutor { base.executor }

  func availability() async -> LocalAIAvailability {
    guard !(await gate.isOccupied()) else { return .unavailable(LocalAIExecutionGate.busyReason) }
    return await base.availability()
  }

  func reflect(_ request: DailyReflectionRequest) async throws -> DailyReflectionResult {
    try Task.checkCancellation()
    try request.validated()
    let acquired = try await gate.acquire()
    do {
      try Task.checkCancellation()
      let result = try await base.reflect(request)
      try Task.checkCancellation()
      // base 返回意味着其 KV／GPU defer 清理已完成，之后才释放执行名额。
      await gate.release(acquired)
      return result
    } catch {
      // 必须等待释放完成再把失败交回调用方，避免下一请求与取消清理交叠。
      await gate.release(acquired)
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      throw error
    }
  }
}

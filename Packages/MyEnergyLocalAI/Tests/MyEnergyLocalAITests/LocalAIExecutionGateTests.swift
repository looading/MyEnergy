import Foundation
import MyEnergyCore
import MyEnergyPlatform
@testable import MyEnergyLocalAI
import Testing

struct LocalAIExecutionGateTests {
  @Test
  func differentModelsShareOneExecutionLeaseAndSuccessReleasesIt() async throws {
    let gate = LocalAIExecutionGate()
    let firstBase = ControlledRunner(modelID: "apple.system")
    let secondBase = ImmediateRunner(modelID: "qwen3.0.6b.4bit")
    let first = LeasedLocalAIRunner(base: firstBase, gate: gate)
    let second = LeasedLocalAIRunner(base: secondBase, gate: gate)
    let request = fixtureRequest()
    let operation = Task { try await first.reflect(request) }
    await firstBase.waitUntilStarted()

    await expectUnavailable { try await second.reflect(request) }
    #expect(await secondBase.invocationCount() == 0)
    #expect(await second.availability() == .unavailable(LocalAIExecutionGate.busyReason))
    #expect(await gate.isOccupied())

    await firstBase.finish()
    _ = try await operation.value
    #expect(!(await gate.isOccupied()))
    _ = try await second.reflect(request)
    #expect(await secondBase.invocationCount() == 1)
    #expect(!(await gate.isOccupied()))
  }

  @Test
  func generationFailureReleasesLeaseBeforeReturning() async throws {
    let gate = LocalAIExecutionGate()
    let failingBase = ImmediateRunner(modelID: "apple.system", fails: true)
    let nextBase = ImmediateRunner(modelID: "qwen3.0.6b.4bit")
    let failing = LeasedLocalAIRunner(base: failingBase, gate: gate)
    let next = LeasedLocalAIRunner(base: nextBase, gate: gate)
    do {
      _ = try await failing.reflect(fixtureRequest())
      Issue.record("预期原样传播生成失败。")
    } catch LocalAIError.generationFailed(let reason) {
      #expect(reason == "确定性失败")
    } catch {
      Issue.record("生成失败被改变为其他错误。")
    }
    #expect(!(await gate.isOccupied()))
    _ = try await next.reflect(fixtureRequest())
    #expect(await nextBase.invocationCount() == 1)
  }

  @Test
  func cancellationHoldsLeaseUntilOldBaseActuallyFinishesCleanup() async throws {
    let gate = LocalAIExecutionGate()
    let oldBase = ControlledRunner(modelID: "qwen3.0.6b.4bit")
    let nextBase = ImmediateRunner(modelID: "apple.system")
    let old = LeasedLocalAIRunner(base: oldBase, gate: gate)
    let next = LeasedLocalAIRunner(base: nextBase, gate: gate)
    let operation = Task { try await old.reflect(fixtureRequest()) }
    await oldBase.waitUntilStarted()
    operation.cancel()

    // Fake 暂不响应取消，模拟 GPU／KV 尚在收尾；取消信号本身不能释放名额。
    await expectUnavailable { try await next.reflect(fixtureRequest()) }
    #expect(await nextBase.invocationCount() == 0)
    #expect(await gate.isOccupied())

    await oldBase.finish()
    do {
      _ = try await operation.value
      Issue.record("预期取消直接传播 CancellationError。")
    } catch is CancellationError {
    } catch {
      Issue.record("取消被改变为其他错误。")
    }
    #expect(!(await gate.isOccupied()))
    _ = try await next.reflect(fixtureRequest())
    #expect(await nextBase.invocationCount() == 1)
  }

  @Test
  @MainActor
  func remoteOnlyDevicesRegisterNeitherRunnersNorDownloadAssets() {
    for role in [LocalAIDeviceRole.iPad, .watch] {
      let registry = LocalAIRegistry()
      NativeLocalAI.register(role: role, deviceID: "fixture", registry: registry)
      #expect(registry.runners.isEmpty)
      #expect(registry.modelAssets == nil)
    }
  }

  private func expectUnavailable(_ action: () async throws -> DailyReflectionResult) async {
    do {
      _ = try await action()
      Issue.record("已有模型执行时不得启动另一模型。")
    } catch LocalAIError.unavailable(let reason) {
      #expect(reason == LocalAIExecutionGate.busyReason)
    } catch {
      Issue.record("忙碌必须在开始前返回 unavailable。")
    }
  }
}

/// 只有测试显式 finish 才退出；不把 Task.cancel 当作底层工作已清理的证据。
private actor ControlledRunner: LocalAIRunner {
  nonisolated let executor: LocalAIExecutor
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var completion: CheckedContinuation<Void, Never>?

  init(modelID: String) { executor = fixtureExecutor(modelID) }

  func availability() async -> LocalAIAvailability { .ready }

  func reflect(_ request: DailyReflectionRequest) async throws -> DailyReflectionResult {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { completion = $0 }
    try Task.checkCancellation()
    return fixtureResult(request, executor: executor)
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func finish() {
    completion?.resume()
    completion = nil
  }
}

private actor ImmediateRunner: LocalAIRunner {
  nonisolated let executor: LocalAIExecutor
  private let fails: Bool
  private var count = 0

  init(modelID: String, fails: Bool = false) {
    self.executor = fixtureExecutor(modelID)
    self.fails = fails
  }

  func availability() async -> LocalAIAvailability { .ready }

  func reflect(_ request: DailyReflectionRequest) async throws -> DailyReflectionResult {
    count += 1
    if fails { throw LocalAIError.generationFailed("确定性失败") }
    return fixtureResult(request, executor: executor)
  }

  func invocationCount() -> Int { count }
}

private func fixtureExecutor(_ modelID: String) -> LocalAIExecutor {
  LocalAIExecutor(id: "fixture.\(modelID)", role: .mac, modelID: modelID, modelName: "测试模型", isRemote: false)
}

private func fixtureRequest() -> DailyReflectionRequest {
  DailyReflectionRequest(input: DailyReflectionInput(dayKey: "2026-11-20", timeZoneIdentifier: "Asia/Shanghai",
    facts: [DailyReflectionFact(id: "energy_summary", statement: "虚构主观精力记录。")], missingData: [],
    entryCount: 1, habitCount: 0, manualSleepCount: 0))
}

private func fixtureResult(_ request: DailyReflectionRequest, executor: LocalAIExecutor) -> DailyReflectionResult {
  DailyReflectionResult(requestID: request.id, inputDigest: request.input.digest, executor: executor,
    draft: DailyReflectionDraft(overview: "仅供并发回归的虚构结果。", observations: [], suggestions: []))
}

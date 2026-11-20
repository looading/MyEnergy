#if os(iOS) || os(macOS)
import Combine
import Foundation
import MyEnergyCore
@testable import MyEnergyPlatform
@preconcurrency import Network
import Testing

/// 只使用临时 loopback 端口和合成事实，不广播 Bonjour、不读取账户或运行模型。
@Suite("Local AI TLS-PSK loopback", .serialized)
struct LocalAINetworkTests {
  @Test @MainActor func matchingIdentityDiscoversAndRunsWithVerifiedRemoteMetadata() async throws {
    let fixture = try LoopbackAIHarness(mode: .immediate, role: .iPhone)
    defer { fixture.stop() }
    let endpoint = try await fixture.start()
    let runners = try await networkDeadline("authenticated capability exchange") { [client = fixture.client, identity = fixture.identity] in
      await client.remoteRunners(at: [endpoint], identity: identity, timeout: 2)
    }
    let remote = try #require(runners.first)
    #expect(runners.count == 1)
    #expect(remote.executor.isRemote)
    #expect(remote.executor.role == .iPhone)
    #expect(remote.executor.id.hasSuffix(".\(fixture.runner.executor.id)"))
    #expect(remote.executor.modelID == fixture.runner.executor.modelID)
    #expect(remote.executor.modelName == fixture.runner.executor.modelName)

    let request = loopbackRequest()
    let result = try await networkDeadline("authenticated reflection response") { try await remote.reflect(request) }
    #expect(try result.validated(for: request) == result)
    #expect(result.executor == remote.executor)
    #expect(result.requestID == request.id)
    #expect(result.inputDigest == request.input.digest)
    #expect(result.draft.observations.first?.factIDs == ["energy_1"])
    #expect(result.draft.overview.contains("合成测试"))
    #expect(await fixture.probe.invocationCount == 1)
    #expect(await fixture.probe.returnedResultCount == 1)
  }

  @Test @MainActor func incorrectKeyOrNamespaceCannotDiscoverOrInvokeRunner() async throws {
    let fixture = try LoopbackAIHarness(mode: .immediate)
    defer { fixture.stop() }
    let endpoint = try await fixture.start()
    let incorrectKey = try LocalAIIdentity(namespace: fixture.identity.namespace, preSharedKey: Data(repeating: 0xB8, count: 32))
    let incorrectNamespace = try LocalAIIdentity(namespace: fixture.identity.namespace + ".other", preSharedKey: fixture.identity.preSharedKey)
    for identity in [incorrectKey, incorrectNamespace] {
      let runners = try await networkDeadline("rejected TLS-PSK identity") { [client = fixture.client] in
        await client.remoteRunners(at: [endpoint], identity: identity, timeout: 1)
      }
      #expect(runners.isEmpty)
    }
    #expect(await fixture.probe.invocationCount == 0)
    #expect(await fixture.probe.returnedResultCount == 0)
  }

  @Test @MainActor func cancellingClientRequestCancelsServerWorkWithoutLateResult() async throws {
    let fixture = try LoopbackAIHarness(mode: .waitForCancellation)
    defer { fixture.stop() }
    let remote = try await fixture.remoteRunner()
    let request = loopbackRequest()
    let inFlight = Task { try await remote.reflect(request) }
    defer { inFlight.cancel() }
    let started = try await nextNetworkEvent(fixture.probe.startedEvents, name: "server model start")
    #expect(started == request.id)

    inFlight.cancel()
    do {
      _ = try await networkTaskValue(inFlight, name: "cancelled client request")
      Issue.record("Cancelled client returned a successful result")
    } catch { #expect(error is CancellationError) }
    let cancelled = try await nextNetworkEvent(fixture.probe.cancelledEvents, name: "server model cancellation")
    #expect(cancelled == request.id)
    #expect(await fixture.probe.invocationCount == 1)
    #expect(await fixture.probe.cancellationCount == 1)
    #expect(await fixture.probe.returnedResultCount == 0)
  }

  @Test @MainActor func stoppingReceiverCancelsItsRunnerAndRejectsPendingSuccess() async throws {
    let fixture = try LoopbackAIHarness(mode: .waitForCancellation)
    defer { fixture.stop() }
    let remote = try await fixture.remoteRunner()
    let request = loopbackRequest()
    let inFlight = Task { try await remote.reflect(request) }
    defer { inFlight.cancel() }
    _ = try await nextNetworkEvent(fixture.probe.startedEvents, name: "server model start before stop")

    fixture.server.stop()
    #expect(!fixture.server.isReceiving)
    #expect(fixture.server.listeningPort == nil)
    let cancelled = try await nextNetworkEvent(fixture.probe.cancelledEvents, name: "server stop cancellation")
    #expect(cancelled == request.id)
    do {
      _ = try await networkTaskValue(inFlight, name: "disconnected client response")
      Issue.record("Stopped server produced a late successful result")
    } catch {
      if let local = error as? LocalAIError {
        guard case .remoteUncertain = local else {
          Issue.record("A request already started on the stopped server must remain uncertain")
          return
        }
      } else { #expect(error is CancellationError) }
    }
    #expect(await fixture.probe.cancellationCount == 1)
    #expect(await fixture.probe.returnedResultCount == 0)
  }

  @Test @MainActor func busyReceiverDoesNotRunASecondRequestConcurrently() async throws {
    let fixture = try LoopbackAIHarness(mode: .waitForCancellation)
    defer { fixture.stop() }
    let remote = try await fixture.remoteRunner()
    let first = loopbackRequest()
    let inFlight = Task { try await remote.reflect(first) }
    defer { inFlight.cancel() }
    _ = try await nextNetworkEvent(fixture.probe.startedEvents, name: "first request start")

    do {
      _ = try await networkDeadline("busy request rejection") { try await remote.reflect(loopbackRequest()) }
      Issue.record("Busy receiver unexpectedly ran a second model request")
    } catch LocalAIError.unavailable(let message) {
      #expect(message.contains("另一份复盘"))
    }
    #expect(await fixture.probe.invocationCount == 1)
    inFlight.cancel()
    _ = try await nextNetworkEvent(fixture.probe.cancelledEvents, name: "busy fixture cleanup cancellation")
    do { _ = try await networkTaskValue(inFlight, name: "busy fixture client cleanup") }
    catch { #expect(error is CancellationError) }
    #expect(await fixture.probe.returnedResultCount == 0)
  }

  @Test @MainActor func invalidEvidenceReturnedByRunnerIsNeverAcceptedAcrossNetwork() async throws {
    let fixture = try LoopbackAIHarness(mode: .invalidEvidence)
    defer { fixture.stop() }
    let remote = try await fixture.remoteRunner()
    do {
      _ = try await networkDeadline("invalid evidence rejection") { try await remote.reflect(loopbackRequest()) }
      Issue.record("Unrecognized fact IDs were accepted in a network response")
    } catch LocalAIError.generationFailed { }
    #expect(await fixture.probe.invocationCount == 1)
    #expect(await fixture.probe.returnedResultCount == 1)
  }
}

@MainActor
private final class LoopbackAIHarness {
  let probe: LoopbackAIProbe
  let identity: LocalAIIdentity
  let runner: LoopbackFixtureRunner
  let registry: LocalAIRegistry
  let server: LocalAINetworkHub
  let client: LocalAINetworkHub

  init(mode: LoopbackRunnerMode, role: LocalAIDeviceRole = .mac) throws {
    let testProbe = LoopbackAIProbe()
    let testIdentity = try LocalAIIdentity(namespace: "fixture.loopback.\(UUID().uuidString)", preSharedKey: Data(repeating: 0xA7, count: 32))
    let testRunner = LoopbackFixtureRunner(executor: .init(id: "fixture-local-executor", role: role,
      modelID: "fixture.loopback-model", modelName: "Synthetic network fixture", isRemote: false), mode: mode, probe: testProbe)
    let testRegistry = LocalAIRegistry()
    testRegistry.register(runners: [testRunner], modelAssets: nil)
    probe = testProbe
    identity = testIdentity
    runner = testRunner
    registry = testRegistry
    server = LocalAINetworkHub(registry: testRegistry, loopbackOnly: true)
    client = LocalAINetworkHub(registry: LocalAIRegistry(), loopbackOnly: true)
  }

  func start() async throws -> NWEndpoint {
    let events = AsyncStream<UInt16>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let subscription = server.$isReceiving.sink { [server] ready in
      if ready, let port = server.listeningPort { events.continuation.yield(port) }
    }
    defer { subscription.cancel(); events.continuation.finish() }
    server.configure(identity: identity, allowReceiving: true)
    let value = try await nextNetworkEvent(events.stream, name: "loopback listener readiness")
    let port = try #require(NWEndpoint.Port(rawValue: value))
    return .hostPort(host: "127.0.0.1", port: port)
  }

  func remoteRunner() async throws -> any LocalAIRunner {
    let endpoint = try await start()
    let runners = try await networkDeadline("fixture capability exchange") { [client, identity] in
      await client.remoteRunners(at: [endpoint], identity: identity, timeout: 2)
    }
    #expect(runners.count == 1)
    return try #require(runners.first)
  }

  func stop() { server.stop(); client.stop() }
}

private enum LoopbackRunnerMode: Sendable { case immediate, waitForCancellation, invalidEvidence }

/// 显式的合成执行器，只验证真实网络路径，不声称进行模型推理。
private struct LoopbackFixtureRunner: LocalAIRunner {
  let executor: LocalAIExecutor
  let mode: LoopbackRunnerMode
  let probe: LoopbackAIProbe

  func availability() async -> LocalAIAvailability { .ready }

  func reflect(_ request: DailyReflectionRequest) async throws -> DailyReflectionResult {
    try request.validated()
    await probe.didStart(request.id)
    do {
      if case .waitForCancellation = mode {
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        for await _ in gate.stream { }
        try Task.checkCancellation()
        throw LocalAIError.generationFailed("Synthetic cancellation gate ended without cancellation")
      }
      try Task.checkCancellation()
      let factID: String
      if case .invalidEvidence = mode { factID = "not-in-this-input" } else { factID = "energy_1" }
      let result = DailyReflectionResult(requestID: request.id, inputDigest: request.input.digest, executor: executor,
        draft: .init(overview: "这是合成测试事实的网络复盘，不是真实模型生成。",
          observations: [.init(text: "合成记录包含一次精力自评。", factIDs: [factID])], suggestions: []))
      await probe.didReturnResult()
      return result
    } catch is CancellationError {
      await probe.didCancel(request.id)
      throw CancellationError()
    }
  }
}

private actor LoopbackAIProbe {
  nonisolated let startedEvents: AsyncStream<UUID>
  nonisolated let cancelledEvents: AsyncStream<UUID>
  private let starts: AsyncStream<UUID>.Continuation
  private let cancellations: AsyncStream<UUID>.Continuation
  private(set) var invocationCount = 0
  private(set) var cancellationCount = 0
  private(set) var returnedResultCount = 0

  init() {
    let started = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let cancelled = AsyncStream<UUID>.makeStream(bufferingPolicy: .bufferingNewest(8))
    startedEvents = started.stream
    starts = started.continuation
    cancelledEvents = cancelled.stream
    cancellations = cancelled.continuation
  }

  func didStart(_ id: UUID) { invocationCount += 1; starts.yield(id) }
  func didCancel(_ id: UUID) { cancellationCount += 1; cancellations.yield(id) }
  func didReturnResult() { returnedResultCount += 1 }
}

private enum LoopbackNetworkTestError: Error { case timedOut(String), eventStreamEnded(String) }

private func loopbackRequest() -> DailyReflectionRequest {
  let input = DailyReflectionInput(dayKey: "2026-11-20", timeZoneIdentifier: "GMT",
    facts: [.init(id: "energy_1", statement: "合成测试记录的主观精力为60/100。")],
    missingData: ["这是合成事实，不包含真实个人信息。"], entryCount: 1, habitCount: 0, manualSleepCount: 0)
  return .init(createdAt: Date(), input: input)
}

private func nextNetworkEvent<T: Sendable>(_ stream: AsyncStream<T>, name: String) async throws -> T {
  try await networkDeadline(name) {
    var iterator = stream.makeAsyncIterator()
    guard let value = await iterator.next() else { throw LoopbackNetworkTestError.eventStreamEnded(name) }
    return value
  }
}

private func networkTaskValue<T: Sendable>(_ task: Task<T, any Error>, name: String) async throws -> T {
  try await networkDeadline(name) {
    try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }
}

private func networkDeadline<T: Sendable>(_ name: String, operation: @escaping @Sendable () async throws -> T) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(8))
      throw LoopbackNetworkTestError.timedOut(name)
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else { throw CancellationError() }
    return result
  }
}
#endif

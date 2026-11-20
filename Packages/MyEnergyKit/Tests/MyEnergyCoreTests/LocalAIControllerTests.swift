#if !os(watchOS)
import Combine
import Foundation
import MyEnergyCore
import MyEnergyPlatform
@testable import MyEnergyUI
import Testing

@Suite("Local AI page lifecycle", .serialized)
struct LocalAIControllerTests {
  @Test @MainActor func changedFactsCancelActiveRequestAndRejectItsLateResult() async throws {
    let fixture = try LocalAIPageFixture()
    defer { fixture.cleanup() }
    await fixture.model.load()
    fixture.model.snapshot.entries = [try EnergyEntry(energy: 35, occurredAt: Date().addingTimeInterval(-60))]
    fixture.controller.appear()
    let originalDigest = fixture.controller.input?.digest
    let operation = try #require(fixture.controller.generate())
    await fixture.runner.waitUntilStarted()
    #expect(fixture.controller.isGenerating)

    fixture.model.snapshot.entries[0].energy = 72
    #expect(!fixture.controller.isGenerating)
    #expect(fixture.controller.input?.digest != originalDigest)
    #expect(fixture.controller.result == nil)
    await fixture.runner.release()
    await operation.value
    #expect(fixture.controller.result == nil)
    #expect(!fixture.controller.isGenerating)
  }

  @Test @MainActor func closingPageRejectsLateResultAndReopeningDoesNotGenerate() async throws {
    let fixture = try LocalAIPageFixture()
    defer { fixture.cleanup() }
    await fixture.model.load()
    fixture.model.snapshot.entries = [try EnergyEntry(energy: 60, occurredAt: Date().addingTimeInterval(-60))]
    fixture.controller.appear()
    let operation = try #require(fixture.controller.generate())
    await fixture.runner.waitUntilStarted()
    fixture.controller.disappear()
    await fixture.runner.release()
    await operation.value

    #expect(fixture.controller.result == nil)
    #expect(!fixture.controller.isGenerating)
    #expect(!fixture.controller.networkHub.isReceiving)
    fixture.controller.appear()
    #expect(fixture.controller.result == nil)
    #expect(!fixture.controller.isGenerating)
    #expect(await fixture.runner.requestCount == 1)
  }

  @Test @MainActor func excludedNoteChangeKeepsResultWhileIdentityChangeClearsIt() async throws {
    let fixture = try LocalAIPageFixture()
    defer { fixture.cleanup() }
    await fixture.model.load()
    fixture.model.snapshot.entries = [try EnergyEntry(energy: 55, note: "fixture original",
      occurredAt: Date().addingTimeInterval(-60))]
    fixture.controller.appear()
    await fixture.runner.release()
    let operation = try #require(fixture.controller.generate())
    await operation.value
    let result = try #require(fixture.controller.result)

    fixture.model.snapshot.entries[0].note = "fixture private edit"
    #expect(fixture.controller.result == result)
    #expect(fixture.controller.input?.digest == result.inputDigest)
    fixture.account.fingerprint = "different-fixture-identity"
    #expect(fixture.controller.result == nil)
    #expect(!fixture.controller.allowsSending)
    #expect(!fixture.controller.allowsReceiving)
  }

  @Test @MainActor func emptyFactsCannotGenerateAndAnonymousCannotGrantNetworkAccess() async throws {
    let fixture = try LocalAIPageFixture()
    defer { fixture.cleanup() }
    await fixture.model.load()
    fixture.controller.appear()
    #expect(fixture.controller.input?.facts.isEmpty == true)
    #expect(fixture.controller.input?.missingData.isEmpty == false)
    #expect(!fixture.controller.canGenerate)
    #expect(fixture.controller.generate() == nil)
    fixture.controller.setAllowsSending(true)
    fixture.controller.setAllowsReceiving(true)
    #expect(!fixture.controller.allowsSending)
    #expect(!fixture.controller.allowsReceiving)
    #expect(!fixture.controller.networkHub.isReceiving)
    #expect(await fixture.runner.requestCount == 0)
  }

  @Test @MainActor func sessionExpiryKeepsResultProducedEntirelyOnThisDevice() async throws {
    let fixture = try LocalAIPageFixture()
    defer { fixture.cleanup() }
    await fixture.model.load()
    fixture.model.snapshot.entries = [try EnergyEntry(energy: 50, occurredAt: Date().addingTimeInterval(-60))]
    let accountID = UUID().uuidString
    func session(expiresAt: Double) throws -> AccountSession {
      let data = try JSONSerialization.data(withJSONObject: ["accountID": accountID,
        "token": "fixture-only-not-a-real-token", "expiresAt": expiresAt, "mode": "development"])
      return try JSONDecoder().decode(AccountSession.self, from: data)
    }
    fixture.account.session = try session(expiresAt: Date().timeIntervalSince1970 + 3_600)
    fixture.controller.appear()
    await fixture.runner.release()
    let operation = try #require(fixture.controller.generate())
    await operation.value
    let result = try #require(fixture.controller.result)

    fixture.account.session = try session(expiresAt: 1)
    fixture.controller.refreshContext()
    #expect(fixture.controller.result == result)
    #expect(!fixture.controller.canUseCrossDevice)
    #expect(fixture.controller.canGenerate)
    #expect(!fixture.controller.networkHub.isReceiving)
  }

  @Test @MainActor func cancellingRejectedDownloadDoesNotCancelAnotherPagesOwnedDownload() async throws {
    let assets = SharedLocalAIPageAssets()
    let fixture = try LocalAIPageFixture(assets: assets)
    defer { fixture.cleanup() }
    await fixture.model.load()
    // B 页先缓存未下载；A 开始之后，B 仍可能显示可下载按钮。
    fixture.controller.appear()
    var events = assets.events.makeAsyncIterator()
    while await events.next() != .statusRead {}
    let owner = Task { try await assets.download(progress: { _ in }) }
    defer { owner.cancel() }
    while await events.next() != .ownerStarted {}

    fixture.controller.downloadModel()
    // fake 已作出拒绝 B 的决定，但在 throw 前挂起，确保 UI catch 尚未执行。
    while await events.next() != .attemptRejected {}
    let states = AsyncStream.makeStream(of: Bool.self)
    let observation = fixture.controller.$isCancellingDownload.sink { states.continuation.yield($0) }
    defer { observation.cancel(); states.continuation.finish() }
    fixture.controller.cancelDownload()
    #expect(fixture.controller.isCancellingDownload)
    await assets.releaseRejectedAttempt()
    var sawCancellation = false
    for await cancelling in states.stream {
      if cancelling { sawCancellation = true }
      else if sawCancellation { break }
    }

    #expect(await assets.globalCancellationCount == 0)
    #expect(await assets.ownerIsActive)
    #expect(!fixture.controller.isCancellingDownload)
    await assets.finishOwner()
    try await owner.value
    #expect(await assets.ownerCompleted)
    #expect(await assets.status() == .ready(351))
  }
}

@MainActor
private final class LocalAIPageFixture {
  let directory: URL
  let suite: String
  let preferences: UserDefaults
  let model: AppModel
  let account: AccountController
  let runner: DeferredLocalAIPageRunner
  let registry: LocalAIRegistry
  let controller: LocalAIController

  init(assets: (any LocalAIModelAssetsManaging)? = nil) throws {
    let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let testSuite = "MyEnergy.LocalAIPageTests.\(UUID().uuidString)"
    let testPreferences = try #require(UserDefaults(suiteName: testSuite))
    let url = testDirectory.appendingPathComponent("records.json")
    let testModel = AppModel(storageURL: url, healthClient: NoLocalAIPageHealth(), preferences: testPreferences)
    let testAccount = AccountController(secrets: LocalAIPageSecrets(), preferences: testPreferences, anonymousRecordsURL: url)
    let testRunner = DeferredLocalAIPageRunner()
    let testRegistry = LocalAIRegistry()
    testRegistry.register(runners: [testRunner], modelAssets: assets)
    directory = testDirectory
    suite = testSuite
    preferences = testPreferences
    model = testModel
    account = testAccount
    runner = testRunner
    registry = testRegistry
    controller = LocalAIController(model: testModel, registry: testRegistry, account: testAccount)
  }

  func cleanup() {
    controller.disappear()
    preferences.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
}

/// 故意忽略任务取消，验证控制器自身拒绝晚到结果。
private actor DeferredLocalAIPageRunner: LocalAIRunner {
  nonisolated let executor = LocalAIExecutor(id: "fixture-mac", role: .mac,
    modelID: "fixture.local", modelName: "Fixture model", isRemote: false)
  private(set) var requestCount = 0
  private var released = false
  private var waiting: CheckedContinuation<Void, Never>?
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []

  func availability() async -> LocalAIAvailability { .ready }

  func reflect(_ request: DailyReflectionRequest) async throws -> DailyReflectionResult {
    requestCount += 1
    let started = startedWaiters
    startedWaiters.removeAll()
    started.forEach { $0.resume() }
    if !released {
      await withCheckedContinuation { waiting = $0 }
    }
    return DailyReflectionResult(requestID: request.id, inputDigest: request.input.digest, executor: executor,
      draft: DailyReflectionDraft(overview: "这是合成记录的测试复盘。", observations: [], suggestions: []))
  }

  func waitUntilStarted() async {
    if requestCount > 0 { return }
    await withCheckedContinuation { startedWaiters.append($0) }
  }

  func release() {
    released = true
    waiting?.resume()
    waiting = nil
  }
}

@MainActor
private final class LocalAIPageSecrets: AccountSecretsStore {
  private var values: [String: Data] = [:]
  func read(key: String) throws -> Data? { values[key] }
  func write(_ data: Data, key: String) throws { values[key] = data }
  func delete(key: String) throws { values.removeValue(forKey: key) }
}

@MainActor
private final class NoLocalAIPageHealth: AppHealthClient {
  var isAvailable: Bool { false }
  func requestReadAccess() async throws {}
  func fetchReport(now: Date) async throws -> HealthReport { throw LocalAIError.unavailable("fixture") }
}

/// 共享资产的全局取消会中断 A；B 的拒绝回调用独立门闩控制。
private actor SharedLocalAIPageAssets: LocalAIModelAssetsManaging {
  enum Event: Equatable, Sendable { case statusRead, ownerStarted, attemptRejected }
  nonisolated let events: AsyncStream<Event>
  private let eventContinuation: AsyncStream<Event>.Continuation
  private let ownerFinish: AsyncStream<Void>
  private let ownerFinishContinuation: AsyncStream<Void>.Continuation
  private let rejectedRelease: AsyncStream<Void>
  private let rejectedReleaseContinuation: AsyncStream<Void>.Continuation
  private var state: LocalAIModelAssetState = .notDownloaded
  private var globallyCancelled = false
  private(set) var globalCancellationCount = 0
  private(set) var ownerIsActive = false
  private(set) var ownerCompleted = false

  init() {
    let events = AsyncStream.makeStream(of: Event.self)
    self.events = events.stream
    eventContinuation = events.continuation
    let owner = AsyncStream.makeStream(of: Void.self)
    ownerFinish = owner.stream
    ownerFinishContinuation = owner.continuation
    let rejection = AsyncStream.makeStream(of: Void.self)
    rejectedRelease = rejection.stream
    rejectedReleaseContinuation = rejection.continuation
  }

  func status() async -> LocalAIModelAssetState {
    eventContinuation.yield(.statusRead)
    return state
  }

  func download(progress: @escaping @Sendable (Double) -> Void) async throws {
    if ownerIsActive {
      eventContinuation.yield(.attemptRejected)
      for await _ in rejectedRelease { break }
      throw LocalAIError.generationFailed("fixture download already owned by A")
    }
    ownerIsActive = true
    state = .downloading(0.2)
    progress(0.2)
    eventContinuation.yield(.ownerStarted)
    for await _ in ownerFinish { break }
    try Task.checkCancellation()
    guard !globallyCancelled else { throw CancellationError() }
    ownerIsActive = false
    ownerCompleted = true
    state = .ready(351)
    progress(1)
  }

  func cancelDownload() async {
    globalCancellationCount += 1
    globallyCancelled = true
    ownerFinishContinuation.finish()
  }

  func releaseRejectedAttempt() { rejectedReleaseContinuation.finish() }
  func finishOwner() { ownerFinishContinuation.yield(()); ownerFinishContinuation.finish() }
}
#endif

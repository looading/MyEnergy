import Foundation
import MyEnergyCore
@testable import MyEnergyLocalAI
import Testing

struct QwenModelAssetStoreTests {
  @Test
  func completeSmallDownloadIsVerifiedAndCanBeReopenedWithoutNetwork() async throws {
    let fixture = AssetFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    #expect(await store.status() == .notDownloaded)
    try await store.download { _ in }
    #expect(await store.status() == .ready(3))
    let directory = try await store.verifiedDirectory()
    #expect(try Data(contentsOf: directory.appendingPathComponent("weights.bin")) == Data("abc".utf8))
    #expect(!fixture.partialDirectoriesExist())

    // 重启后的 ready 也必须走真实目录和 hash 验证，不能依赖前一实例的内存状态。
    let reopened = fixture.store(transport: UnexpectedAssetTransport())
    #expect(await reopened.status() == .ready(3))
    #expect(try await reopened.verifiedDirectory() == directory)
  }

  @Test(arguments: AssetDamage.allCases)
  func damagedDirectoryNeverReportsReady(_ damage: AssetDamage) async throws {
    let fixture = AssetFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    try await store.download { _ in }
    let directory = try await store.verifiedDirectory()
    try fixture.damage(damage, directory: directory)

    // 同一实例已有 ready 缓存，目录变化后也必须失效；新实例不能提前 ready。
    #expect(await store.status() == .notDownloaded)
    let reopened = fixture.store(transport: UnexpectedAssetTransport())
    #expect(await reopened.status() == .notDownloaded)
    do {
      _ = try await reopened.verifiedDirectory()
      Issue.record("损坏资产不得暴露为可推理目录。")
    } catch LocalAIError.unavailable {
    } catch {
      Issue.record("损坏资产必须在推理前明确不可用。")
    }
  }

  @Test(arguments: [AssetDamage.wrongSize, .wrongHash])
  func corruptedDownloadCannotActivateAndCleansStaging(_ damage: AssetDamage) async throws {
    let fixture = AssetFixture()
    defer { fixture.remove() }
    let payload = Data((damage == .wrongSize ? "abcd" : "abd").utf8)
    let store = fixture.store(transport: MemoryAssetTransport(payload: payload))
    do {
      try await store.download { _ in }
      Issue.record("长度或 hash 不符合固定清单时不得启用。")
    } catch LocalAIError.generationFailed {
    } catch {
      Issue.record("下载校验失败应有明确的失败结果。")
    }
    await expectNotReady(store)
    #expect(!FileManager.default.fileExists(atPath: fixture.modelDirectory.path))
    #expect(!fixture.partialDirectoriesExist())
    #expect(await fixture.store(transport: UnexpectedAssetTransport()).status() == .notDownloaded)
  }

  @Test
  func explicitCancelWaitsForTransportAndNeverLeavesAnEnabledModel() async throws {
    let fixture = AssetFixture()
    defer { fixture.remove() }
    let transport = ControlledAssetTransport()
    let store = fixture.store(transport: transport)
    let download = Task { try await store.download { _ in } }
    await transport.started.wait()
    let cancellation = Task { await store.cancelDownload() }
    await transport.cancellationObserved.wait()

    // 已有正确字节且进度已报满，但真实传输尚未退出，不能因此 ready。
    await expectNotReady(store)
    #expect(!FileManager.default.fileExists(atPath: fixture.modelDirectory.path))
    transport.finish.signal()
    await cancellation.value
    await expectCancelled(download)
    await expectNotReady(store)
    #expect(!fixture.partialDirectoriesExist())
    #expect(await fixture.store(transport: UnexpectedAssetTransport()).status() == .notDownloaded)

    // 同一实例取消后可重试；不能残留 activeDownload 或错误的 ready 状态。
    try await store.download { _ in }
    #expect(await store.status() == .ready(3))
  }

  @Test
  func cancellingCallerAlsoPreventsActivationAndRemovesPartialFiles() async throws {
    let fixture = AssetFixture()
    defer { fixture.remove() }
    let transport = ControlledAssetTransport()
    let store = fixture.store(transport: transport)
    let download = Task { try await store.download { _ in } }
    await transport.started.wait()
    download.cancel()
    await transport.cancellationObserved.wait()
    await expectNotReady(store)
    transport.finish.signal()
    await expectCancelled(download)
    #expect(await store.status() == .notDownloaded)
    #expect(!FileManager.default.fileExists(atPath: fixture.modelDirectory.path))
    #expect(!fixture.partialDirectoriesExist())
  }

  @Test
  func concurrentDownloadsStartOnlyOneTransport() async throws {
    let fixture = AssetFixture()
    defer { fixture.remove() }
    let transport = SingleStartAssetTransport()
    let store = fixture.store(transport: transport)
    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<2 {
        group.addTask {
          do { try await store.download { _ in }; return true }
          catch { return false }
        }
      }
      await transport.started.wait()
      let rejected = await group.next()
      #expect(rejected == false)
      #expect(await transport.invocationCount() == 1)
      transport.finish.signal()
      let completed = await group.next()
      #expect(completed == true)
    }
    #expect(await store.status() == .ready(3))
    #expect(!fixture.partialDirectoriesExist())
  }

  @Test
  func anotherStoreDownloadRefreshesPreviouslyNotDownloadedState() async throws {
    let fixture = AssetFixture()
    defer { fixture.remove() }
    let observer = fixture.store(transport: UnexpectedAssetTransport())
    #expect(await observer.status() == .notDownloaded)
    let downloader = fixture.store()
    try await downloader.download { _ in }
    #expect(await observer.status() == .ready(3))
    // 已识别其他实例的完整提交，再点击下载也不得进入网络传输。
    try await observer.download { _ in }
    #expect(await observer.status() == .ready(3))
  }

  @Test(arguments: AssetCancellation.allCases)
  func cancelledStoreCannotDeleteAnotherStoresLaterCommit(_ mode: AssetCancellation) async throws {
    let fixture = AssetFixture()
    defer { fixture.remove() }
    let transport = ControlledAssetTransport()
    let workerExited = AssetTestSignal()
    let resumeOuter = AssetTestSignal()
    let cancelledStore = fixture.store(transport: transport, afterWorkerExit: {
      workerExited.signal()
      await resumeOuter.wait()
    })
    let cancelledDownload = Task { try await cancelledStore.download { _ in } }
    await transport.started.wait()
    let explicitCancellation: Task<Void, Never>?
    if mode == .caller {
      cancelledDownload.cancel()
      explicitCancellation = nil
    } else {
      explicitCancellation = Task { await cancelledStore.cancelDownload() }
    }
    await transport.cancellationObserved.wait()
    transport.finish.signal()
    // 此时 A 已释放跨实例文件锁，但外层 catch 尚未恢复。
    await workerExited.wait()
    if let explicitCancellation { await explicitCancellation.value }
    let succeedingStore = fixture.store()
    try await succeedingStore.download { _ in }
    #expect(await succeedingStore.status() == .ready(3))

    resumeOuter.signal()
    await expectCancelled(cancelledDownload)
    #expect(await succeedingStore.status() == .ready(3))
    #expect(await cancelledStore.status() == .ready(3))
    #expect(await fixture.store(transport: UnexpectedAssetTransport()).status() == .ready(3))
    #expect(try Data(contentsOf: fixture.modelDirectory.appendingPathComponent("weights.bin")) == Data("abc".utf8))
  }

  @Test
  func cancellationAfterAtomicCommitKeepsVerifiedAssets() async throws {
    let fixture = AssetFixture()
    defer { fixture.remove() }
    let committed = AssetTestSignal()
    let resumeOuter = AssetTestSignal()
    let store = fixture.store(afterWorkerExit: {
      committed.signal()
      await resumeOuter.wait()
    })
    let operation = Task { try await store.download { _ in } }
    await committed.wait()
    operation.cancel()
    resumeOuter.signal()
    await expectCancelled(operation)
    #expect(await store.status() == .ready(3))
    #expect(await fixture.store(transport: UnexpectedAssetTransport()).status() == .ready(3))
  }

  @Test
  func publicInitializerKeepsProductionManifestEvenWhenSmallFixtureClaimsItsRevision() async throws {
    let fixture = AssetFixture()
    defer { fixture.remove() }
    let testStore = fixture.store()
    try await testStore.download { _ in }
    let original = try await testStore.verifiedDirectory()
    let productionNamed = fixture.root.appendingPathComponent(QwenAssetManifest.revision, isDirectory: true)
    try FileManager.default.moveItem(at: original, to: productionNamed)
    try Data(QwenAssetManifest.revision.utf8)
      .write(to: productionNamed.appendingPathComponent("verified-revision.txt"))

    let publicStore = QwenModelAssetStore(rootDirectory: fixture.root)
    #expect(await publicStore.status() == .notDownloaded)
  }

  private func expectNotReady(_ store: QwenModelAssetStore) async {
    if case .ready = await store.status() { Issue.record("尚未验证启用或已取消的资产不得 ready。") }
  }

  private func expectCancelled(_ task: Task<Void, any Error>) async {
    do {
      try await task.value
      Issue.record("取消下载必须传播 CancellationError。")
    } catch is CancellationError {
    } catch {
      Issue.record("取消不能被改写为成功或普通下载错误。")
    }
  }
}

enum AssetDamage: String, CaseIterable, Sendable {
  case missingFile, wrongSize, wrongHash, symbolicAsset, symbolicDirectory, extraFile, wrongMarker, symbolicMarker
}

enum AssetCancellation: String, CaseIterable, Sendable {
  case caller, store
}

private struct AssetFixture: Sendable {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyEnergyAssetTests-\(UUID().uuidString)", isDirectory: true)
  // SHA-256("abc") 的独立标准测试向量，避免用被测校验函数生成期望值。
  let specification = ModelAssetSpecification(revision: "fixture-pinned-revision", assets: [
    QwenAssetManifest.Asset(name: "weights.bin", bytes: 3,
      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      url: URL(string: "https://unused.invalid/weights.bin")!)
  ])

  var modelDirectory: URL { root.appendingPathComponent(specification.revision, isDirectory: true) }

  func store(transport: any ModelAssetTransport = MemoryAssetTransport(payload: Data("abc".utf8)),
             afterWorkerExit: (@Sendable () async -> Void)? = nil) -> QwenModelAssetStore {
    QwenModelAssetStore(rootDirectory: root, specification: specification, transport: transport, afterWorkerExit: afterWorkerExit)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func partialDirectoriesExist() -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.contains { $0.hasPrefix(".partial-") }
  }

  func damage(_ damage: AssetDamage, directory: URL) throws {
    let file = directory.appendingPathComponent("weights.bin")
    let marker = directory.appendingPathComponent("verified-revision.txt")
    switch damage {
    case .missingFile: try FileManager.default.removeItem(at: file)
    case .wrongSize: try Data("abcd".utf8).write(to: file, options: .atomic)
    case .wrongHash: try Data("abd".utf8).write(to: file, options: .atomic)
    case .symbolicAsset:
      let outside = root.appendingPathComponent("outside.bin")
      try FileManager.default.moveItem(at: file, to: outside)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
    case .symbolicDirectory:
      let outside = root.appendingPathComponent("outside-model", isDirectory: true)
      try FileManager.default.moveItem(at: directory, to: outside)
      try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
    case .extraFile: try Data("unexpected".utf8).write(to: directory.appendingPathComponent("extra.bin"))
    case .wrongMarker:
      try Data(String(repeating: "x", count: specification.revision.utf8.count).utf8).write(to: marker, options: .atomic)
    case .symbolicMarker:
      let outside = root.appendingPathComponent("outside-marker.txt")
      try FileManager.default.moveItem(at: marker, to: outside)
      try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: outside)
    }
  }
}

private struct MemoryAssetTransport: ModelAssetTransport {
  let payload: Data

  func download(_ asset: QwenAssetManifest.Asset, to destination: URL,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
    try payload.write(to: destination)
    progress(Int64(payload.count))
  }
}

private struct UnexpectedAssetTransport: ModelAssetTransport {
  func download(_ asset: QwenAssetManifest.Asset, to destination: URL,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
    Issue.record("本用例不得进入任何下载传输。")
    throw AssetFailure.invalidDownload
  }
}

/// 写完正确字节后仍保持传输活跃；取消要先通知测试，再等待显式收尾。
private struct ControlledAssetTransport: ModelAssetTransport {
  let started = AssetTestSignal()
  let cancellationObserved = AssetTestSignal()
  let finish = AssetTestSignal()

  func download(_ asset: QwenAssetManifest.Asset, to destination: URL,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
    try Data("abc".utf8).write(to: destination)
    progress(3)
    started.signal()
    await withTaskCancellationHandler {
      await finish.wait()
    } onCancel: {
      cancellationObserved.signal()
    }
  }
}

/// 若实现错误地启动第二个传输，立即退出该传输，保证测试可报告计数错误而非卡在双重等待。
private actor SingleStartAssetTransport: ModelAssetTransport {
  nonisolated let started = AssetTestSignal()
  nonisolated let finish = AssetTestSignal()
  private var count = 0

  func download(_ asset: QwenAssetManifest.Asset, to destination: URL,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
    count += 1
    guard count == 1 else { throw AssetFailure.invalidDownload }
    try Data("abc".utf8).write(to: destination)
    progress(3)
    started.signal()
    await finish.wait()
  }

  func invocationCount() -> Int { count }
}

private final class AssetTestSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var signalled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { continuation in
      let resumeNow = lock.withLock {
        if signalled { return true }
        waiters.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func signal() {
    let pending = lock.withLock {
      signalled = true
      let pending = waiters
      waiters.removeAll()
      return pending
    }
    for waiter in pending { waiter.resume() }
  }
}

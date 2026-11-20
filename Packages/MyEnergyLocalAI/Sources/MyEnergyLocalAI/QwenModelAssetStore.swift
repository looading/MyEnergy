import CryptoKit
import Darwin
import Foundation
import MyEnergyCore

/// 只有模块内部的回归测试可替换清单和字节传输；公开初始化始终绑定固定 Qwen 资产。
struct ModelAssetSpecification: Sendable {
  let revision: String
  let assets: [QwenAssetManifest.Asset]
  var totalBytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }

  static let production = ModelAssetSpecification(revision: QwenAssetManifest.revision, assets: QwenAssetManifest.assets)
}

protocol ModelAssetTransport: Sendable {
  func download(_ asset: QwenAssetManifest.Asset, to destination: URL,
                progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// 模型资产与用户记录分开保存；只有固定清单全部校验通过后才会原子启用。
public actor QwenModelAssetStore: LocalAIModelAssetsManaging {
  private let rootDirectory: URL
  private let modelDirectory: URL
  private let specification: ModelAssetSpecification
  private let transport: any ModelAssetTransport
  private let afterWorkerExit: (@Sendable () async -> Void)?
  private var currentState: LocalAIModelAssetState?
  private var activeID: UUID?
  private var activeDownload: Task<Void, any Error>?
  private var activeCancelled = false
  private var verifiedFingerprints: [String: AssetFingerprint] = [:]
  private static let markerName = "verified-revision.txt"

  public init(rootDirectory: URL? = nil) {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let root = rootDirectory ?? support.appendingPathComponent("MyEnergy/LocalAI", isDirectory: true)
    self.rootDirectory = root.standardizedFileURL
    self.modelDirectory = root.appendingPathComponent(QwenAssetManifest.revision, isDirectory: true).standardizedFileURL
    self.specification = .production
    self.transport = URLSessionModelAssetTransport()
    self.afterWorkerExit = nil
  }

  init(rootDirectory: URL, specification: ModelAssetSpecification, transport: any ModelAssetTransport,
       afterWorkerExit: (@Sendable () async -> Void)? = nil) {
    self.rootDirectory = rootDirectory.standardizedFileURL
    self.modelDirectory = rootDirectory.appendingPathComponent(specification.revision, isDirectory: true).standardizedFileURL
    self.specification = specification
    self.transport = transport
    self.afterWorkerExit = afterWorkerExit
  }

  public func status() async -> LocalAIModelAssetState {
    checkedStatus()
  }

  private func checkedStatus() -> LocalAIModelAssetState {
    if let currentState, case .downloading = currentState { return currentState }
    let previousState = currentState
    do {
      // 初次 ready 必须建立真实 hash 证据；已验证且元数据未变的文件可复用缓存。
      try checkDirectory(modelDirectory, verifyHashes: true)
      currentState = .ready(specification.totalBytes)
    } catch {
      verifiedFingerprints.removeAll()
      if let previousState, case .failed = previousState { currentState = previousState }
      else { currentState = .notDownloaded }
    }
    return currentState ?? .notDownloaded
  }

  public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
    try Task.checkCancellation()
    guard activeDownload == nil else { throw LocalAIError.generationFailed("模型已经在下载，请等待或取消。") }
    // 检查与设置 activeDownload 之间不 await，防止两个调用都越过空闲检查。
    if case .ready = checkedStatus() {
      do {
        _ = try verifiedDirectory()
        progress(1)
        return
      } catch { currentState = .notDownloaded }
    }
    let id = UUID()
    activeID = id
    activeCancelled = false
    verifiedFingerprints.removeAll()
    currentState = .downloading(0)
    progress(0)
    let task = Task { try await self.performDownload(id: id, progress: progress) }
    activeDownload = task
    defer {
      if activeID == id { activeID = nil; activeDownload = nil }
    }
    do {
      let outcome = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
      // 内部测试在 worker 已释放文件锁后控制外层恢复时序；公开入口不设置这个 hook。
      if let afterWorkerExit { await afterWorkerExit() }
      try outcome.get()
      try Task.checkCancellation()
      guard !activeCancelled, !task.isCancelled else { throw CancellationError() }
      currentState = .ready(specification.totalBytes)
      progress(1)
    } catch {
      if error is CancellationError || Task.isCancelled {
        verifiedFingerprints.removeAll()
        currentState = nil
        // 提交后取消保留完整资产；取消中的调用不强制重新 hash，由下一次状态查询完成。
        if !Task.isCancelled { _ = checkedStatus() }
        throw CancellationError()
      }
      currentState = .failed("模型下载或校验失败，请检查网络后重试。")
      throw LocalAIError.generationFailed("模型下载或校验失败，未启用本次文件。")
    }
  }

  public func cancelDownload() async {
    guard let activeDownload, let cancelledID = activeID else { return }
    activeCancelled = true
    currentState = .notDownloaded
    activeDownload.cancel()
    // 等待原任务关闭 URLSession 并清理临时目录后，才允许开始新的下载。
    _ = try? await activeDownload.value
    // worker 退出后只刷新状态，不删除已解锁的共享最终目录；其中可能是另一实例的提交。
    guard activeID == cancelledID else { return }
    verifiedFingerprints.removeAll()
    currentState = nil
    if !Task.isCancelled { _ = checkedStatus() }
  }

  /// 推理只取这个本地目录；首次使用重新校验全部文件，不允许回到 Hub 拉取。
  public func verifiedDirectory() throws -> URL {
    guard activeDownload == nil else { throw LocalAIError.unavailable("离线模型仍在下载。") }
    do {
      try checkDirectory(modelDirectory, verifyHashes: true)
      currentState = .ready(specification.totalBytes)
      return modelDirectory
    } catch {
      verifiedFingerprints.removeAll()
      currentState = .notDownloaded
      throw LocalAIError.unavailable("离线模型尚未下载，或文件校验未通过。")
    }
  }

  private func performDownload(id: UUID, progress: @escaping @Sendable (Double) -> Void) async throws {
    try prepareRoot()
    // 同一台机器的应用和探针也不能同时启用／替换同一个模型目录。
    let descriptor = Darwin.open(rootDirectory.appendingPathComponent(".download.lock").path,
      O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw AssetFailure.invalidDirectory }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      throw AssetFailure.invalidDirectory
    }
    defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    let staging = rootDirectory.appendingPathComponent(".partial-\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    try excludeFromBackup(staging)
    defer { try? FileManager.default.removeItem(at: staging) }
    var completedBytes: Int64 = 0
    for asset in specification.assets {
      try Task.checkCancellation()
      guard validName(asset.name) else { throw AssetFailure.invalidAsset }
      let destination = staging.appendingPathComponent(asset.name)
      let base = completedBytes
      let totalBytes = specification.totalBytes
      try await transport.download(asset, to: destination) { bytes in
        let fraction = Double(base + bytes) / Double(totalBytes)
        Task { await self.advance(id: id, fraction: fraction, progress: progress) }
      }
      try Task.checkCancellation()
      try verify(asset, at: destination, hash: true)
      completedBytes += asset.bytes
      advance(id: id, fraction: Double(completedBytes) / Double(specification.totalBytes), progress: progress)
    }
    try Data(specification.revision.utf8).write(to: staging.appendingPathComponent(Self.markerName), options: .atomic)
    try checkDirectory(staging, verifyHashes: false)
    try Task.checkCancellation()
    // staging 与最终目录同处一个文件系统，目录 rename 是启用时的唯一提交点。
    if FileManager.default.fileExists(atPath: modelDirectory.path) {
      try FileManager.default.removeItem(at: modelDirectory)
    }
    try FileManager.default.moveItem(at: staging, to: modelDirectory)
    // staging 已排除备份，rename 保留该属性；提交后不再 await 或执行可能失败的步骤。
  }

  private func advance(id: UUID, fraction: Double, progress: @Sendable (Double) -> Void) {
    guard activeID == id, let currentState, case .downloading(let previous) = currentState else { return }
    let value = min(0.999, max(previous, fraction))
    guard value > previous else { return }
    self.currentState = .downloading(value)
    progress(value)
  }

  private func prepareRoot() throws {
    guard rootDirectory.isFileURL else { throw AssetFailure.invalidDirectory }
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    let rootAttributes = try FileManager.default.attributesOfItem(atPath: rootDirectory.path)
    guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else { throw AssetFailure.invalidDirectory }
    try excludeFromBackup(rootDirectory)
  }

  private func checkDirectory(_ directory: URL, verifyHashes: Bool) throws {
    // URL 会缓存资源属性；目录被替换为符号链接后必须读取当前文件系统类型。
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory else {
      throw AssetFailure.invalidDirectory
    }
    let actualNames = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    let expectedNames = Set(specification.assets.map(\.name) + [Self.markerName])
    guard actualNames == expectedNames else { throw AssetFailure.invalidAsset }
    let marker = directory.appendingPathComponent(Self.markerName)
    let markerAttributes = try FileManager.default.attributesOfItem(atPath: marker.path)
    guard markerAttributes[.type] as? FileAttributeType == .typeRegular,
          (markerAttributes[.size] as? NSNumber)?.int64Value == Int64(specification.revision.utf8.count),
          try String(contentsOf: marker, encoding: .utf8) == specification.revision else {
      throw AssetFailure.invalidAsset
    }
    for asset in specification.assets {
      guard validName(asset.name) else { throw AssetFailure.invalidAsset }
      try verify(asset, at: directory.appendingPathComponent(asset.name), hash: verifyHashes)
    }
  }

  private func verify(_ asset: QwenAssetManifest.Asset, at url: URL, hash: Bool) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.size] as? NSNumber)?.int64Value == asset.bytes else { throw AssetFailure.invalidAsset }
    guard hash else { return }
    let fingerprint = try AssetFingerprint(url: url)
    if fingerprint.modificationDate != nil, fingerprint.fileNumber != nil,
       verifiedFingerprints[asset.name] == fingerprint { return }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      try Task.checkCancellation()
      hasher.update(data: chunk)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == asset.sha256, try AssetFingerprint(url: url) == fingerprint else { throw AssetFailure.invalidAsset }
    verifiedFingerprints[asset.name] = fingerprint
  }

  private func validName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
      && specification.assets.contains { $0.name == name }
  }

  private func excludeFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var target = url
    try target.setResourceValues(values)
  }

  /// 文件替换或内容时间变化后重新计算 hash，不把进程内缓存当作修改后文件的证据。
  private struct AssetFingerprint: Equatable {
    let length: Int64
    let modificationDate: Date?
    let fileNumber: UInt64?

    init(url: URL) throws {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      length = (attributes[.size] as? NSNumber)?.int64Value ?? -1
      modificationDate = attributes[.modificationDate] as? Date
      fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
  }
}

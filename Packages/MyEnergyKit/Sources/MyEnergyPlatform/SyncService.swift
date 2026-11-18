import Foundation
import MyEnergyCore

public struct SyncResult: Sendable {
  public let snapshot: AppSnapshot
  public let conflicts: [MergeConflict]
  public let revision: Int
  public var completed: Bool { conflicts.isEmpty }
}
private struct SyncBaseline: Codable {
  let accountID: String
  let snapshot: AppSnapshot
}

/// 比较最后确认的共同版本，保留独立变更并将真实冲突交回界面。
public actor SyncService {
  private let client: AccountClient
  private let session: AccountSession
  private let key: Data
  private let baselineURL: URL
  private var isSyncing = false

  public init(baseURL: URL, session: AccountSession, key: Data, baselineURL: URL) throws {
    self.client = try AccountClient(baseURL: baseURL)
    guard key.count == 32 else { throw VaultError.invalidKey }
    self.session = session
    self.key = key
    self.baselineURL = baselineURL
  }

  public func synchronize(local: AppSnapshot, resolving: ConflictSide? = nil) async throws -> SyncResult {
    guard !isSyncing else { throw VaultError.busy }
    isSyncing = true
    defer { isSyncing = false }
    let local = try local.validated()
    let base = try loadBaseline()
    for _ in 0..<3 {
      let remoteVault = try await client.fetchVault(session: session)
      let remote = try remoteVault.ciphertext.map { try VaultCrypto.open($0, key: key, accountID: session.accountID) } ?? AppSnapshot()
      let result = SnapshotMerger.merge(base: base, local: local, remote: remote)
      if !result.conflicts.isEmpty && resolving == nil {
        return SyncResult(snapshot: result.snapshot, conflicts: result.conflicts, revision: remoteVault.revision)
      }
      let merged: AppSnapshot
      if let resolving { merged = SnapshotMerger.resolve(base: base, local: local, remote: remote, favoring: resolving) }
      else { merged = result.snapshot }
      if merged == remote {
        return SyncResult(snapshot: merged, conflicts: [], revision: remoteVault.revision)
      }
      let ciphertext = try VaultCrypto.seal(merged, key: key, accountID: session.accountID)
      do {
        let revision = try await client.uploadVault(ciphertext, expectedRevision: remoteVault.revision,
          mutationID: UUID().uuidString, session: session)
        return SyncResult(snapshot: merged, conflicts: [], revision: revision)
      } catch VaultError.revisionConflict { continue }
    }
    throw VaultError.revisionConflict
  }

  /// 调用方先成功持久化接收结果，再推进共同基线，避免磁盘失败后把旧数据当作新修改上传。
  public func acknowledgeApplied(_ result: SyncResult) throws {
    guard result.completed else { throw VaultError.revisionConflict }
    try saveBaseline(result.snapshot)
  }

  private func loadBaseline() throws -> AppSnapshot {
    guard FileManager.default.fileExists(atPath: baselineURL.path) else { return AppSnapshot() }
    let baseline = try JSONDecoder().decode(SyncBaseline.self, from: Data(contentsOf: baselineURL))
    guard baseline.accountID == session.accountID else { throw VaultError.invalidResponse }
    return try baseline.snapshot.validated()
  }
  private func saveBaseline(_ snapshot: AppSnapshot) throws {
    let data = try JSONEncoder().encode(SyncBaseline(accountID: session.accountID, snapshot: snapshot))
    try PrivateFile.write(data, to: baselineURL)
  }
}

enum PrivateFile {
  static func write(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var directoryURL = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directoryURL.setResourceValues(values)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    #if os(iOS) || os(watchOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    #endif
    var fileURL = url
    try fileURL.setResourceValues(values)
  }
}

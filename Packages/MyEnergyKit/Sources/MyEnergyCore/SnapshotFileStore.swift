import Foundation

/// 串行访问快照文件；解码失败不会改写或删除原始文件。
public actor SnapshotFileStore {
  private let url: URL

  public init(url: URL) { self.url = url }

  public func load() throws -> AppSnapshot {
    guard url.isFileURL else { throw SnapshotValidationError.invalidValue("存储地址必须为本地文件。") }
    guard FileManager.default.fileExists(atPath: url.path) else { return AppSnapshot() }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(AppSnapshot.self, from: data).validated()
  }

  /// 校验后先写入同目录临时文件并设置保护属性，再以原子替换发布新快照。
  public func save(_ snapshot: AppSnapshot) throws {
    let checked = try snapshot.validated()
    guard url.isFileURL else { throw SnapshotValidationError.invalidValue("存储地址必须为本地文件。") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(checked)
    let manager = FileManager.default
    let directory = url.deletingLastPathComponent()
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    var temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? manager.removeItem(at: temporary) }
    var options: Data.WritingOptions = [.atomic]
    #if os(iOS) || os(watchOS) || os(tvOS)
    options.insert(.completeFileProtectionUntilFirstUserAuthentication)
    #endif
    try data.write(to: temporary, options: options)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    var resources = URLResourceValues()
    resources.isExcludedFromBackup = true
    try temporary.setResourceValues(resources)
    if manager.fileExists(atPath: url.path) {
      _ = try manager.replaceItemAt(url, withItemAt: temporary, options: [.usingNewMetadataOnly])
    } else {
      try manager.moveItem(at: temporary, to: url)
    }
  }

  public func delete() throws {
    guard url.isFileURL else { throw SnapshotValidationError.invalidValue("存储地址必须为本地文件。") }
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}

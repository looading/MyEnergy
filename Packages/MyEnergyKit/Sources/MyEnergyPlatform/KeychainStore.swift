import Foundation
import Security

public enum KeychainStoreError: Error, LocalizedError, Sendable {
  case invalidKey
  case unexpectedData
  case status(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .invalidKey: "安全存储的项目名称无效。"
    case .unexpectedData: "安全存储返回了无法读取的数据。"
    case .status(let status): "安全存储操作未完成（系统状态 \(status)）。"
    }
  }
}

/// 使用系统加密钥匙串，不输出敏感值。Mac 本地 Debug 使用独立的登录钥匙串空间。
public enum KeychainStore {
  #if os(macOS) && DEBUG
  private static let service = "app.myenergy.local-development.v1"
  public static let backendDescription = "本地开发使用此 Mac 的系统登录钥匙串，与正式签名版本分开，不启用 iCloud 密钥同步。"
  #else
  private static let service = "app.myenergy.secure-store.v1"
  public static let backendDescription = "使用当前设备的系统数据保护钥匙串，不启用 iCloud 密钥同步。"
  #endif

  public static func read(key: String) throws -> Data? {
    var query = try baseQuery(key: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
    guard let data = item as? Data else { throw KeychainStoreError.unexpectedData }
    return data
  }

  public static func write(_ data: Data, key: String) throws {
    let query = try baseQuery(key: key)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw KeychainStoreError.status(update) }
    let status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let retry = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      guard retry == errSecSuccess else { throw KeychainStoreError.status(retry) }
    } else if status != errSecSuccess {
      throw KeychainStoreError.status(status)
    }
  }

  public static func delete(key: String) throws {
    let status = SecItemDelete(try baseQuery(key: key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStoreError.status(status) }
  }

  private static func baseQuery(key: String) throws -> [String: Any] {
    guard !key.isEmpty, key.utf8.count <= 512 else { throw KeychainStoreError.invalidKey }
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecAttrSynchronizable as String: false
    ]
    #if os(macOS)
    #if DEBUG
    // 未签名 Debug 没有数据保护钥匙串所需的 access-group entitlement。
    // 仅在这个构建路径使用 macOS 登录钥匙串；其他平台及 Release 继续使用数据保护实现。
    query[kSecUseDataProtectionKeychain as String] = false
    #else
    query[kSecUseDataProtectionKeychain as String] = true
    #endif
    #endif
    return query
  }
}

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

/// 令牌和密钥仅保存在当前设备，不进入可同步 Keychain，也不输出敏感值。
public enum KeychainStore {
  private static let service = "app.myenergy.secure-store.v1"

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
    query[kSecUseDataProtectionKeychain as String] = true
    #endif
    return query
  }
}

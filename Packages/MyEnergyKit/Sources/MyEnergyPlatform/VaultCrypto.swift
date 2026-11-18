import CryptoKit
import Foundation
import MyEnergyCore

public enum VaultError: LocalizedError, Sendable {
  case invalidKey, unableToDecrypt, invalidServer, busy, invalidResponse, sessionExpired, revisionConflict
  case server(String)
  public var errorDescription: String? {
    switch self {
    case .invalidKey: "恢复密钥格式不正确，需要 32 字节的 Base64 密钥。"
    case .unableToDecrypt: "无法解密。请使用这个账号原有的恢复密钥，记录尚未被替换。"
    case .invalidServer: "服务地址需要使用 HTTPS；本机开发可使用 http://127.0.0.1。"
    case .busy: "正在同步，请稍后再试。"
    case .invalidResponse: "同步服务返回了无法识别的数据。"
    case .sessionExpired: "登录已失效，请重新登录。此设备的记录仍然保留。"
    case .revisionConflict: "其他设备正在更新，请稍后重试。"
    case .server(let code): "同步未完成（\(code)）。本机记录仍然保留。"
    }
  }
}

public enum VaultCrypto {
  public static func generateKey() -> Data {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
  }
  public static func parseRecoveryKey(_ text: String) throws -> Data {
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else {
      throw VaultError.invalidKey
    }
    return data
  }
  public static func fingerprint(_ key: Data) -> String {
    SHA256.hash(data: key).prefix(6).map { String(format: "%02x", $0) }.joined()
  }
  public static func seal(_ snapshot: AppSnapshot, key: Data, accountID: String) throws -> String {
    guard key.count == 32 else { throw VaultError.invalidKey }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let plaintext = try encoder.encode(snapshot.validated())
    let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: Data(accountID.utf8))
    guard let combined = box.combined else { throw VaultError.invalidResponse }
    return combined.base64EncodedString()
  }
  public static func open(_ ciphertext: String, key: Data, accountID: String) throws -> AppSnapshot {
    guard key.count == 32 else { throw VaultError.invalidKey }
    do {
      guard ciphertext.utf8.count <= 1_400_000, let data = Data(base64Encoded: ciphertext) else { throw VaultError.unableToDecrypt }
      let box = try AES.GCM.SealedBox(combined: data)
      let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(accountID.utf8))
      return try JSONDecoder().decode(AppSnapshot.self, from: plaintext).validated()
    } catch { throw VaultError.unableToDecrypt }
  }
}

import Foundation
import MyEnergyCore
import MyEnergyPlatform
import Testing

@Test func encryptedVaultRoundTripsAndAuthenticatesAccount() throws {
  let key = VaultCrypto.generateKey()
  let snapshot = AppSnapshot(entries: [try EnergyEntry(energy: 62, mood: .good, note: "a private note")])
  let cipher = try VaultCrypto.seal(snapshot, key: key, accountID: "account-a")
  #expect(!cipher.contains("private"))
  #expect(try VaultCrypto.open(cipher, key: key, accountID: "account-a") == snapshot)
  #expect(throws: (any Error).self) { try VaultCrypto.open(cipher, key: key, accountID: "account-b") }
  #expect(throws: (any Error).self) { try VaultCrypto.open(cipher, key: VaultCrypto.generateKey(), accountID: "account-a") }
}

@Test func encryptedVaultRejectsTamperingAndBadRecoveryKeys() throws {
  let key = VaultCrypto.generateKey()
  var bytes = Data(base64Encoded: try VaultCrypto.seal(AppSnapshot(), key: key, accountID: "a")) ?? Data()
  #expect(bytes.count > 28)
  if let last = bytes.indices.last { bytes[last] ^= 1 }
  #expect(throws: (any Error).self) { try VaultCrypto.open(bytes.base64EncodedString(), key: key, accountID: "a") }
  #expect(throws: (any Error).self) { try VaultCrypto.parseRecoveryKey("not-a-key") }
  #expect(try VaultCrypto.parseRecoveryKey(key.base64EncodedString()) == key)
}

@Test func syncRequiresHTTPSOutsideLoopback() throws {
  for value in ["http://example.com", "file:///tmp/server", "https://user:secret@example.com"] {
    let url = try #require(URL(string: value))
    #expect(throws: (any Error).self) { try AccountClient(baseURL: url) }
  }
  _ = try AccountClient(baseURL: #require(URL(string: "http://127.0.0.1:8787")))
  _ = try AccountClient(baseURL: #require(URL(string: "https://sync.example.com")))
}

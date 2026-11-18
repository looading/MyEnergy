#if !os(watchOS)
import CryptoKit
import Foundation
import MyEnergyCore
import MyEnergyPlatform
@testable import MyEnergyUI
import Testing

/// 使用真实本机开发服务；安全存储、偏好及所有记录文件均限定在独立测试空间。
@Suite("Local account controller lifecycle", .serialized)
struct LocalAccountControllerTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"] != nil))
  @MainActor func loginCreateSyncRestoreAndLogoutPreserveAnonymousRecords() async throws {
    let fixture = try LocalAccountFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    await model.load()
    #expect(await model.saveEntry(energy: 31, mood: .neutral, note: "Anonymous fixture", occurredAt: Date()))
    let anonymous = model.snapshot

    let session = try await fixture.login()
    #expect(session.isDevelopment)
    #expect(model.snapshot == AppSnapshot())
    #expect(model.storageURL == fixture.accountURL(session.accountID))
    #expect(!fixture.controller.canSync)
    #expect(fixture.preferences.string(forKey: "MyEnergy.server") == fixture.address)
    #expect(try await fixture.client.fetchVault(session: session).ciphertext == nil)

    await fixture.controller.createKey()
    let key = try #require(fixture.secrets.values[fixture.vaultKey(session.accountID)])
    #expect(key.count == 32)
    #expect(fixture.controller.canSync)
    #expect(fixture.controller.fingerprint == VaultCrypto.fingerprint(key))
    #expect(await model.saveEntry(energy: 73, mood: .good, note: "Account fixture", occurredAt: Date()))
    await fixture.controller.synchronize(model: model)
    let account = model.snapshot
    let remote = try await fixture.client.fetchVault(session: session)
    #expect(remote.revision == 1)
    #expect(try VaultCrypto.open(#require(remote.ciphertext), key: key, accountID: session.accountID) == account)
    #expect(FileManager.default.fileExists(atPath: fixture.baselineURL(session.accountID).path))

    let reopenedModel = fixture.makeModel()
    await reopenedModel.load()
    #expect(reopenedModel.snapshot == anonymous)
    let reopened = fixture.makeController()
    await reopened.restore(model: reopenedModel)
    #expect(reopened.session?.accountID == session.accountID)
    #expect(reopened.canSync)
    #expect(reopened.fingerprint == VaultCrypto.fingerprint(key))
    #expect(reopenedModel.snapshot == account)
    await reopened.synchronize(model: reopenedModel)
    #expect(reopened.message.contains("已完成本轮同步"))

    await reopened.signOut(model: reopenedModel)
    #expect(reopened.session == nil)
    #expect(!reopened.canSync)
    #expect(reopened.fingerprint.isEmpty)
    #expect(reopenedModel.storageURL == fixture.anonymousURL)
    #expect(reopenedModel.snapshot == anonymous)
    #expect(fixture.secrets.values[fixture.sessionKey] == nil)
    #expect(fixture.secrets.values[fixture.vaultKey(session.accountID)] == key)
    #expect(try await SnapshotFileStore(url: fixture.accountURL(session.accountID)).load() == account)
    try await expectSessionRevoked(fixture.client, session: session)

    let signedOut = fixture.makeController()
    await signedOut.restore(model: reopenedModel)
    #expect(signedOut.session == nil)
    #expect(reopenedModel.snapshot == anonymous)
    await signedOut.login(model: reopenedModel, development: true)
    #expect(signedOut.session?.accountID == session.accountID)
    #expect(signedOut.canSync)
    #expect(reopenedModel.snapshot == account)
    await signedOut.deleteAccount(model: reopenedModel)
    #expect(signedOut.session == nil)
    #expect(fixture.secrets.values.isEmpty)
    #expect(reopenedModel.snapshot == anonymous)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"] != nil))
  @MainActor func accountSpacesStaySeparateUntilAnonymousRecordsAreExplicitlyImported() async throws {
    let fixture = try LocalAccountFixture()
    defer { fixture.cleanup() }
    let model = fixture.model
    await model.load()
    #expect(await model.saveEntry(energy: 22, mood: nil, note: "Anonymous fixture", occurredAt: Date()))
    let anonymous = model.snapshot
    let first = try await fixture.login()
    await fixture.controller.createKey()
    #expect(await model.saveEntry(energy: 61, mood: .good, note: "First account fixture", occurredAt: Date()))
    let firstSnapshot = model.snapshot
    await fixture.controller.signOut(model: model)
    #expect(model.snapshot == anonymous)

    let secondName = "c-" + UUID().uuidString
    fixture.controller.developmentName = secondName
    await fixture.controller.login(model: model, development: true)
    let second = try #require(fixture.controller.session)
    #expect(second.accountID != first.accountID)
    #expect(model.snapshot == AppSnapshot())
    #expect(!fixture.controller.canSync)
    await fixture.controller.createKey()
    await fixture.controller.importLocalRecords(model: model)
    #expect(model.snapshot == anonymous)
    await fixture.controller.synchronize(model: model)
    let secondKey = try #require(fixture.secrets.values[fixture.vaultKey(second.accountID)])
    let secondRemote = try await fixture.client.fetchVault(session: second)
    #expect(try VaultCrypto.open(#require(secondRemote.ciphertext), key: secondKey, accountID: second.accountID) == anonymous)
    await fixture.controller.signOut(model: model)

    let firstAgain = try await fixture.login()
    #expect(firstAgain.accountID == first.accountID)
    #expect(model.snapshot == firstSnapshot)
    #expect(fixture.controller.canSync)
    await fixture.controller.synchronize(model: model)
    let firstKey = try #require(fixture.secrets.values[fixture.vaultKey(first.accountID)])
    let firstRemote = try await fixture.client.fetchVault(session: firstAgain)
    #expect(try VaultCrypto.open(#require(firstRemote.ciphertext), key: firstKey, accountID: first.accountID) == firstSnapshot)
    await fixture.controller.deleteAccount(model: model)
    #expect(model.snapshot == anonymous)
    #expect(!FileManager.default.fileExists(atPath: fixture.accountURL(first.accountID).deletingLastPathComponent().path))
    #expect(FileManager.default.fileExists(atPath: fixture.accountURL(second.accountID).path))

    fixture.controller.developmentName = secondName
    await fixture.controller.login(model: model, development: true)
    #expect(fixture.controller.session?.accountID == second.accountID)
    #expect(model.snapshot == anonymous)
    #expect(fixture.controller.fingerprint == VaultCrypto.fingerprint(secondKey))
    await fixture.controller.deleteAccount(model: model)
    #expect(try await SnapshotFileStore(url: fixture.anonymousURL).load() == anonymous)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"] != nil))
  @MainActor func verifiedRecoveryKeyReplacesRacingLocalKeyWithoutDiscardingUnsyncedRecords() async throws {
    let source = try LocalAccountFixture()
    let receiver = try LocalAccountFixture(accountName: source.accountName)
    defer { source.cleanup(); receiver.cleanup() }
    await source.model.load()
    await receiver.model.load()
    let session = try await source.login()
    await source.controller.createKey()
    let sourceKey = try #require(source.secrets.values[source.vaultKey(session.accountID)])
    #expect(await source.model.saveEntry(energy: 54, mood: nil, note: "Source fixture", occurredAt: Date()))

    let receivingSession = try await receiver.login()
    #expect(receivingSession.accountID == session.accountID)
    // 两端均在服务仍为空时创建密钥，模拟首次建立同步空间时的竞争。
    await receiver.controller.createKey()
    let wrongKey = try #require(receiver.secrets.values[receiver.vaultKey(session.accountID)])
    #expect(wrongKey != sourceKey)
    await receiver.controller.synchronize(model: receiver.model)
    let baseline = receiver.baselineURL(session.accountID)
    let oldBaseline = try Data(contentsOf: baseline)
    #expect(await receiver.model.saveEntry(energy: 86, mood: .good, note: "Unsynced fixture", occurredAt: Date()))
    let unsynced = receiver.model.snapshot
    await source.controller.synchronize(model: source.model)

    await receiver.controller.synchronize(model: receiver.model)
    #expect(receiver.controller.message == VaultError.unableToDecrypt.localizedDescription)
    #expect(receiver.model.snapshot == unsynced)
    #expect(try Data(contentsOf: baseline) == oldBaseline)
    receiver.controller.recoveryInput = VaultCrypto.generateKey().base64EncodedString()
    await receiver.controller.importKey()
    #expect(receiver.controller.message == VaultError.unableToDecrypt.localizedDescription)
    #expect(!receiver.controller.recoveryInput.isEmpty)
    #expect(receiver.secrets.values[receiver.vaultKey(session.accountID)] == wrongKey)
    #expect(try Data(contentsOf: baseline) == oldBaseline)

    receiver.controller.recoveryInput = sourceKey.base64EncodedString()
    await receiver.controller.importKey()
    #expect(receiver.controller.recoveryInput.isEmpty)
    #expect(receiver.controller.fingerprint == VaultCrypto.fingerprint(sourceKey))
    #expect(receiver.secrets.values[receiver.vaultKey(session.accountID)] == sourceKey)
    #expect(!FileManager.default.fileExists(atPath: baseline.path))
    #expect(receiver.model.snapshot == unsynced)
    await receiver.controller.synchronize(model: receiver.model)
    let combinedIDs = Set(source.model.snapshot.entries.map(\.id) + unsynced.entries.map(\.id))
    #expect(Set(receiver.model.snapshot.entries.map(\.id)) == combinedIDs)
    #expect(receiver.controller.conflictCount == 0)
    await source.controller.synchronize(model: source.model)
    #expect(source.model.snapshot == receiver.model.snapshot)
    await source.controller.createKey()
    #expect(source.secrets.values[source.vaultKey(session.accountID)] == sourceKey)
    #expect(source.controller.message.contains("已有加密记录"))
    await source.controller.deleteAccount(model: source.model)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"] != nil))
  @MainActor func emptyAccountDeletionNeedsNeitherVaultKeyNorExistingAccountDirectory() async throws {
    let fixture = try LocalAccountFixture()
    defer { fixture.cleanup() }
    await fixture.model.load()
    #expect(await fixture.model.saveEntry(energy: 42, mood: nil, note: "Anonymous fixture", occurredAt: Date()))
    let anonymous = fixture.model.snapshot
    let session = try await fixture.login()
    let otherSession = try await fixture.client.signInDevelopment(accountName: fixture.accountName)
    let accountDirectory = fixture.accountURL(session.accountID).deletingLastPathComponent()
    #expect(!FileManager.default.fileExists(atPath: accountDirectory.path))
    #expect(!fixture.controller.canSync)
    await fixture.controller.deleteAccount(model: fixture.model)
    #expect(fixture.controller.session == nil)
    #expect(fixture.controller.fingerprint.isEmpty)
    #expect(fixture.secrets.values.isEmpty)
    #expect(fixture.model.storageURL == fixture.anonymousURL)
    #expect(fixture.model.snapshot == anonymous)
    #expect(!FileManager.default.fileExists(atPath: accountDirectory.path))
    try await expectSessionRevoked(fixture.client, session: otherSession)
    let fresh = try await fixture.client.signInDevelopment(accountName: fixture.accountName)
    #expect(fresh.accountID != session.accountID)
    let freshVault = try await fixture.client.fetchVault(session: fresh)
    #expect(freshVault.revision == 0)
    #expect(freshVault.ciphertext == nil)
    try await fixture.client.deleteAccount(session: fresh)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"] != nil))
  @MainActor func unavailableServicePreservesLocalFilesAndAllowsLocalLogout() async throws {
    let online = try LocalAccountFixture()
    // 端口 0 不提供服务，强制产生真实连接失败；不终止或修改共享的开发服务。
    let offline = try LocalAccountFixture(address: "http://127.0.0.1:0", accountName: online.accountName)
    defer { online.cleanup(); offline.cleanup() }
    await online.model.load()
    let session = try await online.login()
    await online.controller.createKey()
    #expect(await online.model.saveEntry(energy: 65, mood: nil, note: "Account fixture", occurredAt: Date()))
    await online.controller.synchronize(model: online.model)
    let key = try #require(online.secrets.values[online.vaultKey(session.accountID)])

    await offline.model.load()
    #expect(await offline.model.saveEntry(energy: 28, mood: nil, note: "Anonymous fixture", occurredAt: Date()))
    let anonymous = offline.model.snapshot
    await offline.controller.login(model: offline.model, development: true)
    #expect(offline.controller.session == nil)
    #expect(offline.model.snapshot == anonymous)
    #expect(offline.secrets.values.isEmpty)
    #expect(offline.preferences.string(forKey: "MyEnergy.server") == nil)

    // 将已签发会话放进测试安全存储，覆盖重启后暂时离线的账号恢复路径。
    try offline.secrets.write(JSONEncoder().encode(session), key: offline.sessionKey)
    try offline.secrets.write(key, key: offline.vaultKey(session.accountID))
    try await SnapshotFileStore(url: offline.accountURL(session.accountID)).save(online.model.snapshot)
    try Data(contentsOf: online.baselineURL(session.accountID)).write(to: offline.baselineURL(session.accountID))
    await offline.controller.restore(model: offline.model)
    #expect(offline.controller.session?.accountID == session.accountID)
    #expect(offline.controller.canSync)
    #expect(await offline.model.saveEntry(energy: 81, mood: .good, note: "Offline fixture", occurredAt: Date()))
    let retained = offline.model.snapshot
    let records = try Data(contentsOf: offline.model.storageURL)
    let baseline = try Data(contentsOf: offline.baselineURL(session.accountID))
    let savedSecrets = offline.secrets.values
    await offline.controller.synchronize(model: offline.model)
    #expect(!offline.controller.isBusy)
    #expect(offline.controller.session?.accountID == session.accountID)
    #expect(offline.model.snapshot == retained)
    #expect(try Data(contentsOf: offline.model.storageURL) == records)
    #expect(try Data(contentsOf: offline.baselineURL(session.accountID)) == baseline)
    #expect(offline.secrets.values == savedSecrets)

    await offline.controller.deleteAccount(model: offline.model)
    #expect(offline.controller.session?.accountID == session.accountID)
    #expect(offline.controller.canSync)
    #expect(offline.model.snapshot == retained)
    #expect(try Data(contentsOf: offline.model.storageURL) == records)
    #expect(offline.secrets.values == savedSecrets)
    await offline.controller.signOut(model: offline.model)
    #expect(offline.controller.session == nil)
    #expect(!offline.controller.canSync)
    #expect(offline.model.snapshot == anonymous)
    #expect(offline.model.storageURL == offline.anonymousURL)
    #expect(offline.controller.message.contains("服务暂不可达"))
    #expect(offline.secrets.values[offline.sessionKey] == nil)
    #expect(offline.secrets.values[offline.vaultKey(session.accountID)] == key)
    #expect(try await SnapshotFileStore(url: offline.accountURL(session.accountID)).load() == retained)
    // 本地退出不声称离线撤销已成功，原服务仍能辨认该会话。
    #expect(try await online.client.fetchVault(session: session).revision == 1)
    await online.controller.deleteAccount(model: online.model)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"] != nil))
  @MainActor func failedAccountActivationKeepsCurrentSpaceAndSavedSessionTogether() async throws {
    let fixture = try LocalAccountFixture()
    defer { fixture.cleanup() }
    await fixture.model.load()
    #expect(await fixture.model.saveEntry(energy: 39, mood: nil, note: "Anonymous fixture", occurredAt: Date()))
    let anonymous = fixture.model.snapshot
    let brokenName = "c-" + UUID().uuidString
    let brokenSession = try await fixture.client.signInDevelopment(accountName: brokenName)
    let brokenURL = fixture.accountURL(brokenSession.accountID)
    try FileManager.default.createDirectory(at: brokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let corrupt = Data("invalid account fixture".utf8)
    try corrupt.write(to: brokenURL)

    fixture.controller.developmentName = brokenName
    await fixture.controller.login(model: fixture.model, development: true)
    #expect(fixture.controller.session == nil)
    #expect(!fixture.controller.canSync)
    #expect(fixture.model.storageURL == fixture.anonymousURL)
    #expect(fixture.model.snapshot == anonymous)
    #expect(fixture.secrets.values[fixture.sessionKey] == nil)
    #expect(try Data(contentsOf: brokenURL) == corrupt)

    let goodSession = try await fixture.login()
    await fixture.controller.createKey()
    #expect(await fixture.model.saveEntry(energy: 77, mood: .good, note: "Good account fixture", occurredAt: Date()))
    let goodSnapshot = fixture.model.snapshot
    let savedSession = fixture.secrets.values[fixture.sessionKey]
    fixture.controller.developmentName = brokenName
    await fixture.controller.login(model: fixture.model, development: true)
    #expect(fixture.controller.session?.accountID == goodSession.accountID)
    #expect(fixture.controller.canSync)
    #expect(fixture.model.storageURL == fixture.accountURL(goodSession.accountID))
    #expect(fixture.model.snapshot == goodSnapshot)
    #expect(fixture.secrets.values[fixture.sessionKey] == savedSession)
    await fixture.controller.synchronize(model: fixture.model)
    #expect(fixture.controller.message.contains("已完成本轮同步"))
    #expect(try await fixture.client.fetchVault(session: goodSession).revision == 1)
    await fixture.controller.deleteAccount(model: fixture.model)
    try await fixture.client.deleteAccount(session: brokenSession)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"] != nil))
  @MainActor func logoutSwitchFailureRestoresSavedSessionAndKeepsAccountOpen() async throws {
    let fixture = try LocalAccountFixture()
    defer { fixture.cleanup() }
    await fixture.model.load()
    #expect(await fixture.model.saveEntry(energy: 34, mood: nil, note: "Anonymous fixture", occurredAt: Date()))
    let anonymous = fixture.model.snapshot
    let session = try await fixture.login()
    await fixture.controller.createKey()
    #expect(await fixture.model.saveEntry(energy: 71, mood: .good, note: "Account fixture", occurredAt: Date()))
    let account = fixture.model.snapshot
    let savedSession = fixture.secrets.values[fixture.sessionKey]
    let fingerprint = fixture.controller.fingerprint
    let corrupt = Data("anonymous file changed after preflight".utf8)
    fixture.secrets.beforeDelete = { key in
      if key == fixture.sessionKey { try corrupt.write(to: fixture.anonymousURL) }
    }
    await fixture.controller.signOut(model: fixture.model)
    #expect(fixture.controller.session?.accountID == session.accountID)
    #expect(fixture.controller.canSync)
    #expect(fixture.controller.fingerprint == fingerprint)
    #expect(fixture.model.storageURL == fixture.accountURL(session.accountID))
    #expect(fixture.model.snapshot == account)
    #expect(fixture.secrets.values[fixture.sessionKey] == savedSession)
    #expect(try Data(contentsOf: fixture.anonymousURL) == corrupt)
    // 切换失败不撤销远端会话，也不将账号文件覆盖到匿名空间。
    #expect(try await fixture.client.fetchVault(session: session).revision == 0)

    fixture.secrets.beforeDelete = nil
    try await SnapshotFileStore(url: fixture.anonymousURL).save(anonymous)
    await fixture.controller.signOut(model: fixture.model)
    #expect(fixture.controller.session == nil)
    #expect(fixture.model.snapshot == anonymous)
    #expect(try await SnapshotFileStore(url: fixture.accountURL(session.accountID)).load() == account)
    _ = try await fixture.login()
    await fixture.controller.deleteAccount(model: fixture.model)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"] != nil))
  @MainActor func restoreKeepsBusyAndPinsEndpointAcrossActivationSuspension() async throws {
    let fixture = try LocalAccountFixture()
    let remote = try LocalAccountFixture(accountName: fixture.accountName)
    defer { fixture.cleanup(); remote.cleanup() }
    await fixture.model.load()
    let session = try await fixture.login()
    await fixture.controller.createKey()
    #expect(await fixture.model.saveEntry(energy: 63, mood: nil, note: "Account fixture", occurredAt: Date()))
    await fixture.controller.synchronize(model: fixture.model)
    let before = fixture.model.snapshot
    let reopenedModel = fixture.makeModel()
    await reopenedModel.load()
    let gate = AccountActivationGate()
    let restoring = fixture.makeController(activationPrepared: { await gate.pause() })
    let task = Task { @MainActor in await restoring.restore(model: reopenedModel) }
    await gate.waitUntilReached()
    #expect(restoring.isBusy)
    #expect(restoring.session == nil)
    #expect(reopenedModel.storageURL == fixture.anonymousURL)
    // 复现旧版恢复过程中可改动地址、并再次登录的窗口；UI 现在由 isBusy 禁用。
    let otherAddress = "http://127.0.0.1:0"
    restoring.serverAddress = otherAddress
    await restoring.login(model: reopenedModel, development: true)
    #expect(restoring.isBusy)
    #expect(restoring.session == nil)
    gate.release()
    await task.value
    #expect(!restoring.isBusy)
    #expect(restoring.serverAddress == fixture.address)
    #expect(restoring.session?.accountID == session.accountID)
    #expect(restoring.canSync)
    #expect(reopenedModel.storageURL == fixture.accountURL(session.accountID))
    #expect(reopenedModel.snapshot == before)
    let otherScope = SHA256.hash(data: Data(otherAddress.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    #expect(fixture.secrets.values["session.\(otherScope)"] == nil)
    #expect(fixture.secrets.values["vault.\(otherScope).\(session.accountID)"] == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.storageRoot.appendingPathComponent("accounts/\(otherScope)").path))

    // 远端变更来自另一套独立本地文件和基线，避免两个模型共享同一设备的基线。
    await remote.model.load()
    let remoteSession = try await remote.login()
    #expect(remoteSession.accountID == session.accountID)
    let key = try #require(fixture.secrets.values[fixture.vaultKey(session.accountID)])
    remote.controller.recoveryInput = key.base64EncodedString()
    await remote.controller.importKey()
    await remote.controller.synchronize(model: remote.model)
    #expect(remote.model.snapshot == before)
    #expect(await remote.model.saveEntry(energy: 48, mood: nil, note: "Remote update fixture", occurredAt: Date()))
    await remote.controller.synchronize(model: remote.model)
    await restoring.synchronize(model: reopenedModel)
    #expect(restoring.message.contains("已完成本轮同步"))
    #expect(reopenedModel.snapshot == remote.model.snapshot)
    #expect(FileManager.default.fileExists(atPath: fixture.baselineURL(session.accountID).path))
    await restoring.deleteAccount(model: reopenedModel)
  }

  private func expectSessionRevoked(_ client: AccountClient, session: AccountSession) async throws {
    do {
      _ = try await client.fetchVault(session: session)
      Issue.record("The service accepted a revoked test session")
    } catch VaultError.sessionExpired {
      // 由实际开发服务返回 401，确认本地退出或删除的服务端效果。
    }
  }
}

@MainActor
private final class LocalAccountFixture {
  let root: URL
  let suite: String
  let address: String
  let accountName: String
  let preferences: UserDefaults
  let secrets: MemoryAccountSecretsStore
  let client: AccountClient
  let model: AppModel
  let controller: AccountController

  var anonymousURL: URL { root.appendingPathComponent("anonymous/records.json") }
  var storageRoot: URL { root.appendingPathComponent("account-stores", isDirectory: true) }
  var serverScope: String {
    SHA256.hash(data: Data(address.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
  }
  var sessionKey: String { "session.\(serverScope)" }
  func vaultKey(_ accountID: String) -> String { "vault.\(serverScope).\(accountID)" }
  func accountURL(_ accountID: String) -> URL {
    storageRoot.appendingPathComponent("accounts/\(serverScope)/\(accountID)/records.json")
  }
  func baselineURL(_ accountID: String) -> URL {
    accountURL(accountID).deletingLastPathComponent().appendingPathComponent("sync-base.json")
  }

  init(address: String? = nil, accountName: String = "c-" + UUID().uuidString) throws {
    let testAddress = try #require(address ?? ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"])
    let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MyEnergy.AccountTests.\(UUID().uuidString)")
    let testSuite = "MyEnergy.AccountTests.\(UUID().uuidString)"
    let testPreferences = try #require(UserDefaults(suiteName: testSuite))
    let testSecrets = MemoryAccountSecretsStore()
    self.address = testAddress
    self.accountName = accountName
    root = testRoot
    suite = testSuite
    preferences = testPreferences
    secrets = testSecrets
    client = try AccountClient(baseURL: #require(URL(string: testAddress)))
    let anonymous = testRoot.appendingPathComponent("anonymous/records.json")
    model = AppModel(storageURL: anonymous, healthClient: UnavailableAccountTestHealthClient(), preferences: testPreferences)
    controller = AccountController(secrets: testSecrets, preferences: testPreferences, anonymousRecordsURL: anonymous,
      storageRoot: testRoot.appendingPathComponent("account-stores", isDirectory: true))
    controller.serverAddress = testAddress
    controller.developmentName = accountName
  }

  func makeModel() -> AppModel {
    AppModel(storageURL: anonymousURL, healthClient: UnavailableAccountTestHealthClient(), preferences: preferences)
  }

  func makeController(activationPrepared: (@MainActor () async -> Void)? = nil) -> AccountController {
    let value = AccountController(secrets: secrets, preferences: preferences,
      anonymousRecordsURL: anonymousURL, storageRoot: storageRoot, activationPrepared: activationPrepared)
    value.serverAddress = address
    value.developmentName = accountName
    return value
  }

  func login() async throws -> AccountSession {
    controller.developmentName = accountName
    await controller.login(model: model, development: true)
    return try #require(controller.session)
  }

  func cleanup() {
    secrets.beforeDelete = nil
    try? FileManager.default.removeItem(at: root)
    preferences.removePersistentDomain(forName: suite)
  }
}

@MainActor
private final class AccountActivationGate {
  private var reached = false
  private var waiting: CheckedContinuation<Void, Never>?
  private var paused: CheckedContinuation<Void, Never>?

  func pause() async {
    reached = true
    waiting?.resume()
    waiting = nil
    await withCheckedContinuation { paused = $0 }
  }

  func waitUntilReached() async {
    if reached { return }
    await withCheckedContinuation { waiting = $0 }
  }

  func release() {
    paused?.resume()
    paused = nil
  }
}

@MainActor
private final class MemoryAccountSecretsStore: AccountSecretsStore {
  var values: [String: Data] = [:]
  var beforeDelete: ((String) throws -> Void)?
  func read(key: String) throws -> Data? { values[key] }
  func write(_ data: Data, key: String) throws { values[key] = data }
  func delete(key: String) throws { try beforeDelete?(key); values.removeValue(forKey: key) }
}

@MainActor
private final class UnavailableAccountTestHealthClient: AppHealthClient {
  let isAvailable = false
  func requestReadAccess() async throws {}
  func fetchReport(now: Date) async throws -> HealthReport { throw VaultError.invalidResponse }
}
#endif

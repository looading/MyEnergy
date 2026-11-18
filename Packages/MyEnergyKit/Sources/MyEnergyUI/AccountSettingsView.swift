#if !os(watchOS)
import Foundation
import SwiftUI
import CryptoKit
import MyEnergyCore
import MyEnergyPlatform

/// 账号生命周期只依赖这三个安全存储操作，测试可使用独立的内存实现。
@MainActor
protocol AccountSecretsStore {
  func read(key: String) throws -> Data?
  func write(_ data: Data, key: String) throws
  func delete(key: String) throws
}

private struct KeychainAccountSecretsStore: AccountSecretsStore {
  func read(key: String) throws -> Data? { try KeychainStore.read(key: key) }
  func write(_ data: Data, key: String) throws { try KeychainStore.write(data, key: key) }
  func delete(key: String) throws { try KeychainStore.delete(key: key) }
}

@MainActor
final class AccountController: ObservableObject {
  static let shared = AccountController()
  @Published var session: AccountSession?
  @Published var serverAddress: String
  @Published var developmentName = "myenergy-demo"
  @Published var recoveryInput = ""
  @Published var revealedRecoveryKey: String?
  @Published var message = "未登录，记录只保存在此设备。"
  @Published var isBusy = false
  @Published var conflictCount = 0
  @Published var fingerprint = ""
  private let apple = AppleSignInCoordinator()
  private let secrets: any AccountSecretsStore
  private let preferences: UserDefaults
  private let anonymousRecordsURL: URL
  private let storageRoot: URL
  private let activationPrepared: (@MainActor () async -> Void)?
  private var service: SyncService?
  private var key: Data?
  private var restored = false
  var canSync: Bool { session != nil && service != nil }

  convenience init() {
    self.init(secrets: KeychainAccountSecretsStore(), preferences: .standard,
      anonymousRecordsURL: AppModel.defaultStorageURL)
  }

  init(secrets: any AccountSecretsStore, preferences: UserDefaults, anonymousRecordsURL: URL, storageRoot: URL? = nil,
    activationPrepared: (@MainActor () async -> Void)? = nil) {
    self.secrets = secrets
    self.preferences = preferences
    self.anonymousRecordsURL = anonymousRecordsURL
    self.storageRoot = storageRoot ?? anonymousRecordsURL.deletingLastPathComponent()
    self.activationPrepared = activationPrepared
    serverAddress = preferences.string(forKey: "MyEnergy.server") ?? "http://127.0.0.1:8787"
  }

  private var serverScope: String {
    Self.scope(for: serverAddress)
  }
  private static func scope(for address: String) -> String {
    SHA256.hash(data: Data(address.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
  }
  private var sessionKey: String { "session.\(serverScope)" }
  private func keyName(_ accountID: String) -> String { "vault.\(serverScope).\(accountID)" }
  private func accountURL(_ accountID: String) throws -> URL {
    try accountURL(accountID, scope: serverScope)
  }
  private func accountURL(_ accountID: String, scope: String) throws -> URL {
    guard UUID(uuidString: accountID) != nil else { throw VaultError.invalidResponse }
    return storageRoot
      .appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
      .appendingPathComponent(accountID, isDirectory: true).appendingPathComponent("records.json")
  }
  private func client() throws -> AccountClient {
    guard let url = URL(string: serverAddress) else { throw VaultError.invalidServer }
    return try AccountClient(baseURL: url)
  }
  func restore(model: AppModel) async {
    guard !restored, !isBusy, !model.isDemo else { return }
    isBusy = true
    defer { isBusy = false }
    restored = true
    let restoringAddress = serverAddress
    do {
      guard let data = try secrets.read(key: sessionKey) else { return }
      let saved = try JSONDecoder().decode(AccountSession.self, from: data)
      guard !saved.isExpired else { message = "登录已到期，本机记录仍保留；请重新登录。"; return }
      try await activate(saved, model: model, address: restoringAddress)
    } catch { message = error.localizedDescription }
  }
  func login(model: AppModel, development: Bool) async {
    guard !isBusy, !model.isDemo else { return }
    isBusy = true
    defer { isBusy = false }
    let signingInAddress = serverAddress
    do {
      let client = try client()
      let loggedIn: AccountSession
      if development {
        loggedIn = try await client.signInDevelopment(accountName: developmentName)
      } else {
        let challenge = try await client.challenge()
        let credential = try await apple.obtainCredential(nonce: challenge.nonce)
        loggedIn = try await client.signInApple(identityToken: credential.identityToken, challengeID: challenge.id)
      }
      try await activate(loggedIn, model: model, address: signingInAddress)
      preferences.set(signingInAddress, forKey: "MyEnergy.server")
    } catch { message = error.localizedDescription }
  }
  private func activate(_ value: AccountSession, model: AppModel, address: String) async throws {
    // 读取目标文件会挂起；同一轮激活始终使用开始时的服务地址和安全存储命名空间。
    let scope = Self.scope(for: address)
    let savedSessionKey = "session.\(scope)"
    let target = try accountURL(value.accountID, scope: scope)
    let existingKey = try secrets.read(key: "vault.\(scope).\(value.accountID)")
    let nextService: SyncService?
    if let existingKey, existingKey.count == 32 {
      guard let url = URL(string: address) else { throw VaultError.invalidServer }
      nextService = try SyncService(baseURL: url, session: value, key: existingKey,
        baselineURL: target.deletingLastPathComponent().appendingPathComponent("sync-base.json"))
    } else { nextService = nil }
    let previousSession = try secrets.read(key: savedSessionKey)
    try secrets.write(try JSONEncoder().encode(value), key: savedSessionKey)
    await activationPrepared?()
    do { try await model.switchStorage(to: target) }
    catch {
      if let previousSession { try secrets.write(previousSession, key: savedSessionKey) }
      else { try secrets.delete(key: savedSessionKey) }
      throw error
    }
    serverAddress = address
    session = value
    conflictCount = 0
    revealedRecoveryKey = nil
    if let existingKey, existingKey.count == 32 {
      key = existingKey
      fingerprint = VaultCrypto.fingerprint(existingKey)
      service = nextService
      message = value.isDevelopment ? "本机开发账号已连接；尚未同步。此身份不是 Apple 登录。" : "已登录，账号空间已打开；尚未同步。"
    } else {
      key = nil; service = nil; fingerprint = ""
      message = "账号空间已打开。首次使用请创建密钥；已有其他设备请导入原恢复密钥。"
    }
  }
  private func makeService(session: AccountSession, key: Data) throws -> SyncService {
    let url = try accountURL(session.accountID).deletingLastPathComponent().appendingPathComponent("sync-base.json")
    return try SyncService(baseURL: client().baseURL, session: session, key: key, baselineURL: url)
  }
  func createKey() async {
    guard let session, !isBusy else { return }
    isBusy = true; defer { isBusy = false }
    do {
      let remote = try await client().fetchVault(session: session)
      guard remote.ciphertext == nil else {
        message = "此账号已有加密记录，请从原设备导入恢复密钥；不能用新密钥覆盖。"; return
      }
      try installKey(VaultCrypto.generateKey(), session: session)
      message = "密钥已保存在此设备。请主动查看并安全保留恢复密钥，再在其他设备导入。"
    } catch { message = error.localizedDescription }
  }
  func importKey() async {
    guard let session, !isBusy else { return }
    isBusy = true; defer { isBusy = false }
    do {
      let candidate = try VaultCrypto.parseRecoveryKey(recoveryInput)
      let remote = try await client().fetchVault(session: session)
      if let ciphertext = remote.ciphertext { _ = try VaultCrypto.open(ciphertext, key: candidate, accountID: session.accountID) }
      try installKey(candidate, session: session, replacingVerifiedKey: remote.ciphertext != nil)
      recoveryInput = ""
      message = "恢复密钥已验证并保存在此设备，可以同步。"
    } catch { message = error.localizedDescription }
  }
  private func installKey(_ value: Data, session: AccountSession, replacingVerifiedKey: Bool = false) throws {
    if let key, key != value {
      guard replacingVerifiedKey else { throw VaultError.server("existing_device_key_mismatch") }
      let baseline = try accountURL(session.accountID).deletingLastPathComponent().appendingPathComponent("sync-base.json")
      if FileManager.default.fileExists(atPath: baseline.path) { try FileManager.default.removeItem(at: baseline) }
    }
    try secrets.write(value, key: keyName(session.accountID))
    key = value
    fingerprint = VaultCrypto.fingerprint(value)
    service = try makeService(session: session, key: value)
    revealedRecoveryKey = nil
  }
  func revealKey() { revealedRecoveryKey = key?.base64EncodedString() }
  func synchronize(model: AppModel, resolving: ConflictSide? = nil) async {
    guard let service, !isBusy, !model.isDemo else { return }
    isBusy = true; defer { isBusy = false }
    let before = model.snapshot
    let url = model.storageURL
    do {
      message = "正在同步；此设备的记录已保留。"
      let result = try await service.synchronize(local: before, resolving: resolving)
      guard model.storageURL == url, !model.isDemo else { throw VaultError.busy }
      guard result.completed else {
        conflictCount = result.conflicts.count
        message = "发现 \(conflictCount) 条同时修改的记录。请选择冲突版本，其余变更会保留。"
        return
      }
      let concurrent = SnapshotMerger.merge(base: before, local: model.snapshot, remote: result.snapshot)
      guard concurrent.conflicts.isEmpty else {
        conflictCount = concurrent.conflicts.count
        message = "同步期间此设备也修改了相同记录，请再次同步并选择版本。"
        return
      }
      try await model.replaceSnapshot(concurrent.snapshot)
      try await service.acknowledgeApplied(result)
      conflictCount = 0
      message = concurrent.snapshot == result.snapshot
        ? "此设备已完成本轮同步 · 版本 \(result.revision)。其他设备需完成各自同步。"
        : "已接收其他设备变化；同步期间的新记录仍在本机，请再同步一次。"
    } catch { message = error.localizedDescription }
  }
  func importLocalRecords(model: AppModel) async {
    guard session != nil, !isBusy, !model.isDemo else { return }
    isBusy = true; defer { isBusy = false }
    do {
      let local = try await SnapshotFileStore(url: anonymousRecordsURL).load()
      let result = SnapshotMerger.merge(base: AppSnapshot(), local: model.snapshot, remote: local)
      guard result.conflicts.isEmpty else { throw VaultError.revisionConflict }
      try await model.replaceSnapshot(result.snapshot)
      message = "本机离线记录已合并到当前账号空间，尚未上传。"
    } catch { message = error.localizedDescription }
  }
  func signOut(model: AppModel) async {
    guard let session, !isBusy else { return }
    isBusy = true; defer { isBusy = false }
    do {
      _ = try await SnapshotFileStore(url: anonymousRecordsURL).load()
      let previousSession = try secrets.read(key: sessionKey)
      try secrets.delete(key: sessionKey)
      do { try await model.switchStorage(to: anonymousRecordsURL) }
      catch {
        if let previousSession { try secrets.write(previousSession, key: sessionKey) }
        throw error
      }
      self.session = nil; key = nil; service = nil; fingerprint = ""; revealedRecoveryKey = nil; conflictCount = 0
      do { try await client().signOut(session: session); message = "已退出，当前显示此设备的离线记录。账号记录保留在独立空间。" }
      catch { message = "已退出此设备。服务暂不可达，会话尚未撤销，将按有效期过期。" }
    } catch { message = error.localizedDescription }
  }
  func deleteAccount(model: AppModel) async {
    guard let session, !isBusy else { return }
    isBusy = true; defer { isBusy = false }
    do {
      let target = try accountURL(session.accountID)
      try await client().deleteAccount(session: session)
      self.session = nil; key = nil; service = nil; fingerprint = ""; revealedRecoveryKey = nil; conflictCount = 0
      var cleanupError: (any Error)?
      do { try secrets.delete(key: sessionKey); try secrets.delete(key: keyName(session.accountID)) }
      catch { cleanupError = error }
      do { try await model.switchStorage(to: anonymousRecordsURL) } catch { cleanupError = error }
      let directory = target.deletingLastPathComponent()
      if FileManager.default.fileExists(atPath: directory.path) {
        do { try FileManager.default.removeItem(at: directory) } catch { cleanupError = error }
      }
      message = "账号及服务端记录已删除，此设备的账号空间已清除。其他离线设备仍需联网处理撤销。"
      if cleanupError != nil { message = "服务端账号已删除且会话已失效。本机有清理步骤未完成，请退出后检查数据管理。" }
    } catch { message = error.localizedDescription }
  }
}

struct AccountSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var controller = AccountController.shared
  @State private var confirmDelete = false
  @State private var confirmKey = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("设备与同步").font(.headline)
      Text(controller.message).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
      Text(KeychainStore.backendDescription).font(.caption).foregroundStyle(.secondary)
      TextField("同步服务 HTTPS 地址", text: $controller.serverAddress)
        .textFieldStyle(.roundedBorder).disabled(controller.session != nil || controller.isBusy)
        .accessibilityLabel("同步服务地址")
      if let session = controller.session {
        Label(session.isDevelopment ? "开发账号 · 仅本机联调" : "Apple 账号", systemImage: "person.crop.circle.badge.checkmark")
        if !controller.fingerprint.isEmpty {
          Text("密钥指纹：\(controller.fingerprint)").font(.caption).textSelection(.enabled)
          Button("同步此设备") { Task { await controller.synchronize(model: model) } }
            .buttonStyle(.borderedProminent)
          Button("查看恢复密钥") { confirmKey = true }
          if let recovery = controller.revealedRecoveryKey {
            Text(recovery).font(.caption.monospaced()).textSelection(.enabled)
            Text("此密钥可解密账号记录。只向你自己的设备传递；遗失后服务无法恢复。")
              .font(.caption).foregroundStyle(.secondary)
            Button("隐藏密钥") { controller.revealedRecoveryKey = nil }
          }
        } else {
          Button("首次使用：创建恢复密钥") { Task { await controller.createKey() } }
          SecureField("已有设备的恢复密钥", text: $controller.recoveryInput).textFieldStyle(.roundedBorder)
          Button("导入并验证恢复密钥") { Task { await controller.importKey() } }
        }
        if !controller.fingerprint.isEmpty {
          DisclosureGroup("使用其他设备的恢复密钥") {
            SecureField("原设备恢复密钥", text: $controller.recoveryInput).textFieldStyle(.roundedBorder)
            Button("验证服务端记录并替换此设备密钥") { Task { await controller.importKey() } }
            Text("仅在候选密钥能解密服务端现有记录后替换，本机尚未同步的记录会保留。")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        if controller.conflictCount > 0 {
          Text("选择只处理同时修改的记录，其他设备新增内容会保留。")
            .font(.caption).foregroundStyle(.secondary)
          Button("冲突记录保留此设备版本") { Task { await controller.synchronize(model: model, resolving: .local) } }
          Button("冲突记录采用服务端版本") { Task { await controller.synchronize(model: model, resolving: .remote) } }
        }
        Button("合并此设备的离线记录") { Task { await controller.importLocalRecords(model: model) } }
        Button("退出当前账号") { Task { await controller.signOut(model: model) } }
        Button("删除账号和服务端记录", role: .destructive) { confirmDelete = true }
      } else {
        Button { Task { await controller.login(model: model, development: false) } } label: {
          Label("使用 Apple 登录", systemImage: "apple.logo")
        }.buttonStyle(.borderedProminent)
        Text("账号空间与本机离线记录分开。健康原始样本留在 Apple 健康，摘要默认不共享；需在健康连接中单独开启。")
          .font(.caption).foregroundStyle(.secondary)
        #if DEBUG
        DisclosureGroup("本机开发联调") {
          TextField("开发账号名称", text: $controller.developmentName).textFieldStyle(.roundedBorder)
          Button("连接本机开发账号") { Task { await controller.login(model: model, development: true) } }
          Text("需运行 scripts/run-server.sh。仅用于验证同步，不代表真实 Apple 登录或真机互联。")
            .font(.caption).foregroundStyle(.secondary)
        }
        #endif
      }
      if controller.isBusy { ProgressView().controlSize(.small) }
      if let devices = AppDeviceCoordinator.current { WatchTransportSettingsView(coordinator: devices) }
    }
    .disabled(model.isDemo || controller.isBusy)
    .task { await controller.restore(model: model) }
    .confirmationDialog("恢复密钥可解密全部账号记录。请在私密环境查看。", isPresented: $confirmKey) {
      Button("显示恢复密钥") { controller.revealKey() }
    }
    .confirmationDialog("删除账号会撤销所有登录并删除服务端密文。此操作无法撤销。", isPresented: $confirmDelete) {
      Button("永久删除账号", role: .destructive) { Task { await controller.deleteAccount(model: model) } }
    }
  }
}
#endif

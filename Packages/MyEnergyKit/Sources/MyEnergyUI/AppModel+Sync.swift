import Combine
import CryptoKit
import Foundation
import SwiftUI
import MyEnergyCore
import MyEnergyPlatform

/// 管理配对设备通道；账号同步由独立服务负责，不能混淆两种完成状态。
@MainActor
public final class AppDeviceCoordinator: ObservableObject {
  public static private(set) var current: AppDeviceCoordinator?
  @Published public private(set) var watchMessage = ""
  @Published public private(set) var peerConflictCount = 0
  private let model: AppModel
  private let bridge = WatchBridge()
  private var observation: AnyCancellable?
  private var storageObservation: AnyCancellable?
  private var accountObservation: AnyCancellable?
  private var accountSend: Task<Void, Never>?
  private var pendingSend: Task<Void, Never>?
  private var receiving = false
  private var started = false
  private var pendingConflict: (incoming: AppSnapshot, base: AppSnapshot, namespace: String, storageURL: URL)?

  public init(model: AppModel) { self.model = model }
  public func start() async {
    guard !started else { return }
    started = true
    Self.current = self
    await model.load()
    #if !os(watchOS)
    await AccountController.shared.restore(model: model)
    accountObservation = model.$snapshot.dropFirst().sink { [weak self] _ in self?.scheduleAccountSync() }
    scheduleAccountSync()
    #endif
    #if os(iOS) || os(watchOS)
    bridge.onError = { [weak self] error in self?.watchMessage = error.localizedDescription }
    bridge.onNamespaceChanged = { [weak self] namespace in
      guard let self else { throw WatchBridgeError.receiverUnavailable }
      #if os(watchOS)
      let url = Self.watchStorageURL(namespace: namespace)
      if self.model.storageURL != url { try await self.model.switchStorage(to: url) }
      self.model.updateCompanionHealthContext(namespace: namespace)
      self.pendingConflict = nil
      self.peerConflictCount = 0
      #endif
    }
    bridge.onAcknowledged = { [weak self] acknowledged, sentBase in
      guard let self else { throw WatchBridgeError.receiverUnavailable }
      let namespace = self.bridge.activeNamespace
      guard self.namespaceMatchesStorage(namespace) else { throw WatchBridgeError.namespaceMismatch }
      let store = SnapshotFileStore(url: Self.peerBaselineURL(namespace: namespace))
      let currentBase = try await store.load()
      // 较晚到达的旧 ACK 不能把已接收的新共同版本倒退。
      if currentBase == sentBase { try await store.save(acknowledged) }
      self.watchMessage = "配对设备已保存记录。"
    }
    bridge.onReceiveWithBase = { [weak self] incoming, senderBase in
      guard let self, !self.model.isDemo, self.model.canEdit else { throw WatchBridgeError.receiverUnavailable }
      let namespace = self.bridge.activeNamespace
      let storageURL = self.model.storageURL
      guard self.namespaceMatchesStorage(namespace) else { throw WatchBridgeError.namespaceMismatch }
      let baseStore = SnapshotFileStore(url: Self.peerBaselineURL(namespace: namespace))
      let lastReceived = try await baseStore.load()
      guard self.model.storageURL == storageURL, self.bridge.activeNamespace == namespace else { throw WatchBridgeError.namespaceMismatch }
      if lastReceived == incoming { return }
      let result = SnapshotMerger.merge(base: senderBase, local: self.model.snapshot, remote: incoming)
      guard result.conflicts.isEmpty else {
        self.pendingConflict = (incoming, senderBase, namespace, storageURL)
        self.peerConflictCount = result.conflicts.count
        self.watchMessage = "手机与手表有同时修改的记录，传输尚未确认，内容已保留。"
        throw VaultError.revisionConflict
      }
      self.receiving = true
      defer { self.receiving = false }
      try await self.model.replaceSnapshot(result.snapshot)
      try await baseStore.save(incoming)
      self.watchMessage = "已保存配对设备的记录。账号服务仍需单独同步。"
      if result.snapshot != incoming { try self.bridge.sendSnapshot(result.snapshot, base: incoming) }
    }
    do {
      try bridge.start()
      #if os(watchOS)
      let target = Self.watchStorageURL(namespace: bridge.activeNamespace)
      if model.storageURL != target { try await model.switchStorage(to: target) }
      model.updateCompanionHealthContext(namespace: bridge.activeNamespace)
      #else
      try bridge.setNamespace(Self.namespace(for: model.storageURL))
      storageObservation = model.$storageURL.dropFirst().sink { [weak self] newURL in
        guard let self else { return }
        self.pendingConflict = nil
        self.peerConflictCount = 0
        do { try self.bridge.setNamespace(Self.namespace(for: newURL)) }
        catch { self.watchMessage = error.localizedDescription }
      }
      #endif
      observation = model.$snapshot.dropFirst().sink { [weak self] _ in
        guard let self, !self.receiving else { return }
        self.pendingSend?.cancel()
        self.pendingSend = Task { @MainActor [weak self] in
          try? await Task.sleep(for: .milliseconds(250))
          guard !Task.isCancelled, let self else { return }
          await self.sendCurrent()
        }
      }
      await sendCurrent()
    } catch { watchMessage = error.localizedDescription }
    #endif
  }

  public func retry() {
    #if !os(watchOS)
    scheduleAccountSync()
    #endif
    #if os(iOS) || os(watchOS)
    bridge.retryPending()
    #endif
  }
  private func scheduleAccountSync() {
    #if !os(watchOS)
    guard !model.isDemo, AccountController.shared.canSync, !AccountController.shared.isBusy else { return }
    accountSend?.cancel()
    accountSend = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(800))
      guard !Task.isCancelled, let self, !self.model.isDemo else { return }
      await AccountController.shared.synchronize(model: self.model)
    }
    #endif
  }
  private func sendCurrent() async {
    guard model.isLoaded, !model.isDemo, !model.hasLoadFailure, !receiving else { return }
    do {
      #if os(iOS)
      try bridge.setNamespace(Self.namespace(for: model.storageURL))
      #endif
      let namespace = bridge.activeNamespace
      let url = model.storageURL
      guard namespaceMatchesStorage(namespace) else { throw WatchBridgeError.namespaceMismatch }
      let base = try await SnapshotFileStore(url: Self.peerBaselineURL(namespace: namespace)).load()
      guard !Task.isCancelled, model.storageURL == url, bridge.activeNamespace == namespace else { return }
      try bridge.sendSnapshot(model.snapshot, base: base)
      watchMessage = "已加入配对设备队列，等待对方保存确认。"
    } catch { watchMessage = error.localizedDescription }
  }
  public func resolvePeerConflict(favoring side: ConflictSide) async {
    guard let conflict = pendingConflict, model.storageURL == conflict.storageURL,
      bridge.activeNamespace == conflict.namespace, !model.isDemo else { return }
    do {
      let resolved = SnapshotMerger.resolve(base: conflict.base, local: model.snapshot,
        remote: conflict.incoming, favoring: side)
      receiving = true
      defer { receiving = false }
      try await model.replaceSnapshot(resolved)
      try await SnapshotFileStore(url: Self.peerBaselineURL(namespace: conflict.namespace)).save(conflict.incoming)
      pendingConflict = nil; peerConflictCount = 0
      try bridge.sendSnapshot(resolved, base: conflict.incoming)
      bridge.retryPending()
      watchMessage = "冲突版本已保存，等待配对设备确认。"
    } catch { watchMessage = error.localizedDescription }
  }
  private func namespaceMatchesStorage(_ namespace: String) -> Bool {
    #if os(iOS)
    return namespace == Self.namespace(for: model.storageURL)
    #elseif os(watchOS)
    return model.storageURL == Self.watchStorageURL(namespace: namespace)
    #else
    return false
    #endif
  }
  private static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
  }
  private static func namespace(for url: URL) -> String {
    if url == AppModel.defaultStorageURL { return "local-paired" }
    let accountID = url.deletingLastPathComponent().lastPathComponent
    let serverScope = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    return "account:\(serverScope):\(accountID)"
  }
  private static func watchStorageURL(namespace: String) -> URL {
    AppModel.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("watch-spaces", isDirectory: true)
      .appendingPathComponent(hash(namespace) + ".json")
  }
  private static func peerBaselineURL(namespace: String) -> URL {
    AppModel.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("watch-bases", isDirectory: true)
      .appendingPathComponent(hash(namespace) + ".json")
  }
}

public struct WatchTransportSettingsView: View {
  @ObservedObject var coordinator: AppDeviceCoordinator
  public init(coordinator: AppDeviceCoordinator) { self.coordinator = coordinator }
  public var body: some View {
    #if os(iOS) || os(watchOS)
    VStack(alignment: .leading, spacing: 10) {
      Text("配对设备传输").font(.headline)
      Text(coordinator.watchMessage.isEmpty ? "等待手机与手表建立配对通道。" : coordinator.watchMessage)
        .font(.caption).foregroundStyle(.secondary)
      if coordinator.peerConflictCount > 0 {
        Button("冲突保留此设备版本") { Task { await coordinator.resolvePeerConflict(favoring: .local) } }
        Button("冲突采用配对设备版本") { Task { await coordinator.resolvePeerConflict(favoring: .remote) } }
      }
      Button("重试配对设备传输") { coordinator.retry() }
    }
    #endif
  }
}

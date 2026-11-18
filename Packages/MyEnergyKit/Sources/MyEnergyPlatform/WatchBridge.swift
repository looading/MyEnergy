import Foundation
import MyEnergyCore

#if canImport(WatchConnectivity) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
@preconcurrency import WatchConnectivity
#endif

public enum WatchBridgeError: Error, LocalizedError, Sendable {
  case unavailable
  case invalidNamespace
  case invalidMessage
  case unsupportedVersion
  case namespaceMismatch
  case queueFull
  case receiverUnavailable
  case corruptState

  public var errorDescription: String? {
    switch self {
    case .unavailable: "当前设备没有可用的 iPhone 与 Apple Watch 配对通道。"
    case .invalidNamespace: "手表同步的数据空间无效。"
    case .invalidMessage: "手表同步消息无效或超过大小限制。"
    case .unsupportedVersion: "手表同步协议版本不兼容，请更新两端应用。"
    case .namespaceMismatch: "手表消息属于其他数据空间，已保留待原空间处理。"
    case .queueFull: "手表同步队列已满，请先完成同步或处理待确认记录。"
    case .receiverUnavailable: "手表记录接收器尚未就绪，消息将保持待确认。"
    case .corruptState: "手表同步队列无法读取，原文件已保留。"
    }
  }
}

/// 每条消息有稳定 ID；系统传输完成与产品层 ACK 是两件独立的事。
struct WatchWireMessage: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable { case snapshot, acknowledgement }
  // 为系统字典封装留出余量；较大的历史必须在应用层拆分，不能交给 WCSession 碰运气。
  static let maxBytes = 60 * 1_024
  let version: Int
  let kind: Kind
  let eventID: UUID
  let namespace: String
  let createdAt: Date
  let snapshot: AppSnapshot?
  let baseSnapshot: AppSnapshot?

  init(
    kind: Kind, eventID: UUID = UUID(), namespace: String, createdAt: Date = Date(),
    snapshot: AppSnapshot? = nil, baseSnapshot: AppSnapshot? = nil
  ) {
    version = 2
    self.kind = kind
    self.eventID = eventID
    self.namespace = namespace
    self.createdAt = createdAt
    self.snapshot = snapshot
    self.baseSnapshot = kind == .snapshot ? (baseSnapshot ?? AppSnapshot()) : baseSnapshot
  }

  static func validNamespace(_ namespace: String) -> Bool {
    !namespace.isEmpty && namespace.utf8.count <= 128
      && namespace.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
  }

  func validated() throws -> Self {
    guard version == 2 else { throw WatchBridgeError.unsupportedVersion }
    guard Self.validNamespace(namespace) else { throw WatchBridgeError.invalidNamespace }
    guard createdAt.timeIntervalSince1970.isFinite else { throw WatchBridgeError.invalidMessage }
    switch kind {
    case .snapshot:
      guard let snapshot, let baseSnapshot else { throw WatchBridgeError.invalidMessage }
      guard snapshot.entries.count + snapshot.habits.count + snapshot.checkIns.count + snapshot.deletions.count
        + baseSnapshot.entries.count + baseSnapshot.habits.count + baseSnapshot.checkIns.count
        + baseSnapshot.deletions.count <= 4_000
      else { throw WatchBridgeError.invalidMessage }
      _ = try snapshot.validated()
      _ = try baseSnapshot.validated()
    case .acknowledgement:
      guard snapshot == nil, baseSnapshot == nil else { throw WatchBridgeError.invalidMessage }
    }
    return self
  }

  func encoded() throws -> Data {
    _ = try validated()
    let data = try JSONEncoder().encode(self)
    guard data.count <= Self.maxBytes else { throw WatchBridgeError.invalidMessage }
    return data
  }

  static func decode(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= maxBytes else { throw WatchBridgeError.invalidMessage }
    return try JSONDecoder().decode(Self.self, from: data).validated()
  }
}

struct WatchNamespaceState: Codable, Equatable, Sendable {
  var outbox: [WatchWireMessage] = []
  var receivedIDs: Set<UUID> = []

  mutating func enqueueSnapshot(_ snapshot: AppSnapshot, base: AppSnapshot, namespace: String) throws {
    guard outbox.count < 128 else { throw WatchBridgeError.queueFull }
    // FIFO 保证前一条先被接收并确认；后续离线修改应以该快照为基线，既有事件保持不变。
    let causalBase = outbox.last?.snapshot ?? base
    let message = WatchWireMessage(kind: .snapshot, namespace: namespace,
      snapshot: snapshot, baseSnapshot: causalBase)
    _ = try message.encoded()
    outbox.append(message)
  }
}

struct WatchPersistentState: Codable, Equatable, Sendable {
  var version = 1
  var activeNamespace = "local-paired"
  var spaces: [String: WatchNamespaceState] = [:]

  func validated() throws -> Self {
    guard version == 1, WatchWireMessage.validNamespace(activeNamespace), spaces.count <= 32 else {
      throw WatchBridgeError.corruptState
    }
    for (namespace, state) in spaces {
      guard WatchWireMessage.validNamespace(namespace), state.outbox.count <= 128,
        state.receivedIDs.count <= 20_000 else { throw WatchBridgeError.corruptState }
      var eventIDs: Set<UUID> = []
      for event in state.outbox {
        guard event.namespace == namespace, event.kind == .snapshot,
          eventIDs.insert(event.eventID).inserted else { throw WatchBridgeError.corruptState }
        _ = try event.encoded()
      }
    }
    return self
  }
}

/// 串行处理账号空间切换，并在异步回调结束后只提交最新一代请求。
@MainActor
final class WatchNamespaceDrain {
  private struct Request {
    let namespace: String
    let generation: UUID
  }

  private var pending: Request?
  private(set) var isDraining = false
  var hasPending: Bool { pending != nil }

  func enqueue(_ namespace: String) {
    pending = Request(namespace: namespace, generation: UUID())
  }

  func drain(
    change: @MainActor (String) async throws -> Void,
    commit: @MainActor (String) throws -> Void
  ) async throws {
    guard !isDraining else { return }
    isDraining = true
    defer { isDraining = false }
    while let request = pending {
      do {
        try await change(request.namespace)
        guard pending?.generation == request.generation else { continue }
        try commit(request.namespace)
        pending = nil
      } catch {
        // 过期请求失败也不能阻止已经到达的新请求；当前请求失败则保留，等待重试。
        guard pending?.generation == request.generation else { continue }
        throw error
      }
    }
  }
}

/// 仅用于 iPhone companion 与配对手表。应用必须先合并并持久化接收的数据，成功返回后才发送 ACK。
@MainActor
public final class WatchBridge: NSObject {
  public var onReceive: ((AppSnapshot) async throws -> Void)?
  /// 优先使用发送方的因果基线进行三方合并；返回前必须完成合并结果与基线的持久化。
  public var onReceiveWithBase: ((AppSnapshot, AppSnapshot) async throws -> Void)?
  /// 参数为已确认的发送快照及其基线；回调成功并持久化出队后，才发送下一条。
  public var onAcknowledged: ((AppSnapshot, AppSnapshot) async throws -> Void)?
  public var onNamespaceChanged: ((String) async throws -> Void)?
  public var onError: ((any Error) -> Void)?
  public var activeNamespace: String { state.activeNamespace }
  public var pendingCount: Int { state.spaces[state.activeNamespace]?.outbox.count ?? 0 }

  private static let payloadKey = "myenergy.watch.v1"
  private static let namespaceKey = "myenergy.namespace.v1"
  private let outboxURL: URL
  private var state = WatchPersistentState()
  private var loaded = false
  private var receiving: Set<UUID> = []
  private var acknowledging: Set<UUID> = []
  private let namespaceDrain = WatchNamespaceDrain()
  private var namespaceRetryTask: Task<Void, Never>?
  private var namespaceRetryAttempt = 0
  #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
  private var session: WCSession?
  #endif

  public init(outboxURL: URL? = nil) {
    self.outboxURL = outboxURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MyEnergy", isDirectory: true).appendingPathComponent("watch-transport-v1.json")
    super.init()
  }

  public func start() throws {
    try loadState()
    #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    guard WCSession.isSupported() else { throw WatchBridgeError.unavailable }
    let session = WCSession.default
    self.session = session
    session.delegate = self
    session.activate()
    #else
    throw WatchBridgeError.unavailable
    #endif
  }

  /// 切换账号时保留旧空间的待确认队列，但不再发送；不会把旧事件改绑到新账号。
  public func setNamespace(_ namespace: String) throws {
    guard WatchWireMessage.validNamespace(namespace) else { throw WatchBridgeError.invalidNamespace }
    try loadState()
    guard state.activeNamespace != namespace else { return }
    var candidate = state
    candidate.activeNamespace = namespace
    if candidate.spaces[namespace] == nil {
      guard candidate.spaces.count < 32 else { throw WatchBridgeError.queueFull }
      candidate.spaces[namespace] = WatchNamespaceState()
    }
    try persist(candidate)
    #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    cancelTransfersOutsideActiveNamespace()
    publishNamespace()
    #endif
    retryPending()
  }

  /// 仅用于用户明确删除数据或账号；普通切换应使用 setNamespace 保留离线记录。
  public func discardData(in namespace: String) throws {
    guard WatchWireMessage.validNamespace(namespace) else { throw WatchBridgeError.invalidNamespace }
    try loadState()
    var candidate = state
    candidate.spaces.removeValue(forKey: namespace)
    try persist(candidate)
    #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    for transfer in session?.outstandingUserInfoTransfers ?? [] {
      guard let data = transfer.userInfo[Self.payloadKey] as? Data,
        let message = try? WatchWireMessage.decode(data), message.namespace == namespace else { continue }
      transfer.cancel()
    }
    #endif
  }

  public func sendSnapshot(_ snapshot: AppSnapshot, base: AppSnapshot = AppSnapshot()) throws {
    #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    guard WCSession.isSupported() else { throw WatchBridgeError.unavailable }
    try loadState()
    var candidate = state
    var space = candidate.spaces[candidate.activeNamespace] ?? WatchNamespaceState()
    try space.enqueueSnapshot(snapshot, base: base, namespace: candidate.activeNamespace)
    candidate.spaces[candidate.activeNamespace] = space
    try persist(candidate)
    retryPending()
    #else
    throw WatchBridgeError.unavailable
    #endif
  }

  /// 在激活、恢复可达或用户重试时调用；未取得 ACK 的事件始终保留。
  public func retryPending() {
    #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    #if os(watchOS)
    if namespaceDrain.hasPending {
      Task { @MainActor [weak self] in await self?.drainNamespaces() }
      return
    }
    #endif
    guard let session, session.activationState == .activated else { return }
    #if os(iOS)
    guard session.isPaired, session.isWatchAppInstalled else { return }
    #elseif os(watchOS)
    guard session.isCompanionAppInstalled else { return }
    #endif
    let queued = Set(session.outstandingUserInfoTransfers.compactMap { transfer -> UUID? in
      guard let data = transfer.userInfo[Self.payloadKey] as? Data,
        let message = try? WatchWireMessage.decode(data) else { return nil }
      return message.eventID
    })
    // 一次只发送队首，保持同一设备快照的顺序；下一项由 ACK 驱动。
    guard let message = state.spaces[state.activeNamespace]?.outbox.first else { return }
    do {
      let data = try message.encoded()
      if !queued.contains(message.eventID) { session.transferUserInfo([Self.payloadKey: data]) }
      if session.isReachable {
        session.sendMessageData(data, replyHandler: nil) { [weak self] error in
          Task { @MainActor in self?.onError?(error) }
        }
      }
    } catch { onError?(error) }
    #endif
  }

  private func loadState() throws {
    guard !loaded else { return }
    if FileManager.default.fileExists(atPath: outboxURL.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: outboxURL.path)
      guard let size = attributes[.size] as? NSNumber, size.intValue <= 8 * 1_024 * 1_024 else {
        throw WatchBridgeError.corruptState
      }
      do { state = try JSONDecoder().decode(WatchPersistentState.self, from: Data(contentsOf: outboxURL)).validated() }
      catch { throw WatchBridgeError.corruptState }
    }
    loaded = true
  }

  private func persist(_ candidate: WatchPersistentState) throws {
    _ = try candidate.validated()
    let data = try JSONEncoder().encode(candidate)
    guard data.count <= 8 * 1_024 * 1_024 else { throw WatchBridgeError.queueFull }
    let folder = outboxURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var protectedFolder = folder
    var exclusion = URLResourceValues()
    exclusion.isExcludedFromBackup = true
    try protectedFolder.setResourceValues(exclusion)
    #if os(iOS) || os(watchOS)
    try data.write(to: outboxURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try data.write(to: outboxURL, options: .atomic)
    #endif
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outboxURL.path)
    var protectedFile = outboxURL
    try protectedFile.setResourceValues(exclusion)
    state = candidate
  }

  /// 与 WCSession 分离的传输处理入口，使持久化和 ACK 顺序能够在无配对设备时验证。
  func processIncoming(_ data: Data) async throws {
    try loadState()
    let message = try WatchWireMessage.decode(data)
    guard message.namespace == state.activeNamespace else { throw WatchBridgeError.namespaceMismatch }
    if message.kind == .acknowledgement {
      guard !acknowledging.contains(message.eventID),
        let queued = state.spaces[message.namespace]?.outbox.first(where: { $0.eventID == message.eventID }),
        let snapshot = queued.snapshot, let base = queued.baseSnapshot else { return }
      acknowledging.insert(message.eventID)
      defer { acknowledging.remove(message.eventID) }
      try await onAcknowledged?(snapshot, base)
      guard state.activeNamespace == message.namespace else { throw WatchBridgeError.namespaceMismatch }
      // 回调期间可能切换空间、清队列或持久化其他消息；必须从最新状态构造出队结果。
      var candidate = state
      var space = candidate.spaces[message.namespace] ?? WatchNamespaceState()
      guard space.outbox.contains(where: { $0.eventID == message.eventID }) else { return }
      space.outbox.removeAll { $0.eventID == message.eventID }
      candidate.spaces[message.namespace] = space
      try persist(candidate)
      retryPending()
      return
    }
    let space = state.spaces[message.namespace] ?? WatchNamespaceState()
    if space.receivedIDs.contains(message.eventID) { try acknowledgeReceivedEvent(message); return }
    guard !receiving.contains(message.eventID) else { return }
    guard space.receivedIDs.count < 20_000 else { throw WatchBridgeError.queueFull }
    guard let snapshot = message.snapshot, let base = message.baseSnapshot else { throw WatchBridgeError.invalidMessage }
    guard onReceiveWithBase != nil || onReceive != nil else { throw WatchBridgeError.receiverUnavailable }
    receiving.insert(message.eventID)
    defer { receiving.remove(message.eventID) }
    if let onReceiveWithBase { try await onReceiveWithBase(snapshot, base) }
    else if let onReceive { try await onReceive(snapshot) }
    guard state.activeNamespace == message.namespace else { throw WatchBridgeError.namespaceMismatch }
    var candidate = state
    var updated = candidate.spaces[message.namespace] ?? WatchNamespaceState()
    updated.receivedIDs.insert(message.eventID)
    candidate.spaces[message.namespace] = updated
    try persist(candidate)
    try acknowledgeReceivedEvent(message)
  }

  private func acknowledgeReceivedEvent(_ event: WatchWireMessage) throws {
    #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    try sendAcknowledgement(for: event)
    #endif
  }

  #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
  private func receive(_ data: Data) async {
    do { try await processIncoming(data) }
    catch { onError?(error) }
  }

  private func sendAcknowledgement(for event: WatchWireMessage) throws {
    guard let session, session.activationState == .activated else { return }
    let message = WatchWireMessage(kind: .acknowledgement, eventID: event.eventID, namespace: event.namespace)
    let data = try message.encoded()
    session.transferUserInfo([Self.payloadKey: data])
    if session.isReachable {
      session.sendMessageData(data, replyHandler: nil) { [weak self] error in
        Task { @MainActor in self?.onError?(error) }
      }
    }
  }

  private func cancelTransfersOutsideActiveNamespace() {
    for transfer in session?.outstandingUserInfoTransfers ?? [] {
      guard let data = transfer.userInfo[Self.payloadKey] as? Data,
        let message = try? WatchWireMessage.decode(data), message.namespace != state.activeNamespace else { continue }
      transfer.cancel()
    }
  }

  private func publishNamespace() {
    #if os(iOS)
    guard let session, session.activationState == .activated else { return }
    do { try session.updateApplicationContext([Self.namespaceKey: state.activeNamespace]) }
    catch { onError?(error) }
    #endif
  }

  private func receiveNamespace(_ namespace: String) async {
    #if os(watchOS)
    guard WatchWireMessage.validNamespace(namespace) else { onError?(WatchBridgeError.invalidNamespace); return }
    guard namespace != state.activeNamespace || namespaceDrain.hasPending || namespaceDrain.isDraining else { return }
    namespaceRetryTask?.cancel()
    namespaceRetryTask = nil
    namespaceRetryAttempt = 0
    namespaceDrain.enqueue(namespace)
    await drainNamespaces()
    #endif
  }

  private func drainNamespaces() async {
    #if os(watchOS)
    do {
      try await namespaceDrain.drain(change: { [weak self] namespace in
        guard let self, let onNamespaceChanged = self.onNamespaceChanged else {
          throw WatchBridgeError.receiverUnavailable
        }
        try await onNamespaceChanged(namespace)
      }, commit: { [weak self] namespace in
        guard let self else { throw WatchBridgeError.receiverUnavailable }
        try self.setNamespace(namespace)
      })
      guard !namespaceDrain.hasPending else { return }
      namespaceRetryTask?.cancel()
      namespaceRetryTask = nil
      namespaceRetryAttempt = 0
      retryPending()
    } catch {
      onError?(error)
      scheduleNamespaceRetry()
    }
    #endif
  }

  private func scheduleNamespaceRetry() {
    #if os(watchOS)
    guard namespaceDrain.hasPending, namespaceRetryTask == nil else { return }
    let seconds = UInt64(1 << min(namespaceRetryAttempt, 5))
    namespaceRetryAttempt = min(namespaceRetryAttempt + 1, 5)
    namespaceRetryTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
      catch { return }
      guard let self else { return }
      self.namespaceRetryTask = nil
      await self.drainNamespaces()
    }
    #endif
  }
  #endif
}

#if canImport(WatchConnectivity) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
extension WatchBridge: WCSessionDelegate {
  public nonisolated func session(
    _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
  ) {
    let namespace = session.receivedApplicationContext["myenergy.namespace.v1"] as? String
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let error { self.onError?(error); return }
      if let namespace { await self.receiveNamespace(namespace) }
      self.cancelTransfersOutsideActiveNamespace()
      self.publishNamespace()
      self.retryPending()
    }
  }

  public nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor [weak self] in self?.retryPending() }
  }

  public nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
    Task { @MainActor [weak self] in await self?.receive(messageData) }
  }

  public nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    guard let data = userInfo["myenergy.watch.v1"] as? Data else { return }
    Task { @MainActor [weak self] in await self?.receive(data) }
  }

  public nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    guard let namespace = applicationContext["myenergy.namespace.v1"] as? String else { return }
    Task { @MainActor [weak self] in await self?.receiveNamespace(namespace) }
  }

  public nonisolated func session(
    _ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: (any Error)?
  ) {
    // 系统确认传输完成时仍保留 outbox；仅显式产品 ACK 才允许删除。
    if let error { Task { @MainActor [weak self] in self?.onError?(error) } }
  }

  #if os(iOS)
  public nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

  public nonisolated func sessionDidDeactivate(_ session: WCSession) {
    Task { @MainActor [weak self] in self?.session?.activate() }
  }

  public nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor [weak self] in self?.retryPending() }
  }
  #endif
}
#endif

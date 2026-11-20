import Combine
import CryptoKit
import Foundation
import MyEnergyCore
#if os(iOS) || os(macOS)
@preconcurrency import Network
import Security

/// 独立用途的账号密钥派生值；不得展示、广播或写入日志。
public struct LocalAIIdentity: Equatable, Sendable {
  public let namespace: String
  public let preSharedKey: Data

  public init(namespace: String, preSharedKey: Data) throws {
    guard !namespace.isEmpty, namespace.utf8.count <= 160, preSharedKey.count == 32 else {
      throw LocalAIError.unavailable("当前账号尚未准备好本地设备认证。")
    }
    self.namespace = namespace
    self.preSharedKey = preSharedKey
  }
}

private struct AICapability: Codable, Sendable {
  let executor: LocalAIExecutor
  let ready: Bool
}

private struct AIWire: Codable, Sendable {
  var version = 1
  var id: UUID
  var kind: String
  var nodeID: String?
  var modelID: String?
  var request: DailyReflectionRequest?
  var capabilities: [AICapability]?
  var result: DailyReflectionResult?
  var errorKind: String?
  var message: String?
}

/// 每个复盘页面独立持有接收器，关闭页面即撤销接收。
@MainActor
public final class LocalAINetworkHub: ObservableObject {
  @Published public private(set) var status = "跨设备推理尚未开启。"
  @Published public private(set) var isReceiving = false
  public private(set) var listeningPort: UInt16?
  private let registry: LocalAIRegistry
  private let nodeID = UUID().uuidString
  private var identity: LocalAIIdentity?
  private var listener: NWListener?
  private var generation = UUID()
  private var connections: [UUID: (NWConnection, Task<Void, Never>)] = [:]
  private var browsers: [UUID: NWBrowser] = [:]
  private var running: UUID?
  private var cache: [UUID: (String, String, DailyReflectionResult)] = [:]
  private let loopbackOnly: Bool

  public convenience init(registry: LocalAIRegistry = .shared) {
    self.init(registry: registry, loopbackOnly: false)
  }

  init(registry: LocalAIRegistry, loopbackOnly: Bool) {
    self.registry = registry
    self.loopbackOnly = loopbackOnly
  }

  public func configure(identity: LocalAIIdentity?, allowReceiving: Bool) {
    if self.identity != identity { stop(); self.identity = identity }
    guard allowReceiving else {
      stop()
      self.identity = identity
      return
    }
    guard let identity else {
      status = "跨设备接收需要当前账号已解锁的恢复密钥。"
      return
    }
    guard listener == nil else { return }
    do {
      let parameters = aiTLSParameters(identity)
      if loopbackOnly {
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      }
      let listener = try NWListener(using: parameters, on: .any)
      let epoch = generation
      if !loopbackOnly {
        listener.service = .init(name: "MyEnergy-\(nodeID.prefix(8))", type: "_myenergy-ai._tcp")
      }
      listener.stateUpdateHandler = { @Sendable [weak self, weak listener] state in
        Task { @MainActor in
          guard let self, self.generation == epoch else { return }
          switch state {
          case .ready:
            self.listeningPort = listener?.port?.rawValue
            self.isReceiving = true
            self.status = "本页正在接收同账号已授权设备的本地复盘请求。"
          case .failed:
            self.isReceiving = false
            self.listeningPort = nil
            self.status = "局域网接收尚未就绪，请检查本地网络权限后重试。"
          default: break
          }
        }
      }
      listener.newConnectionHandler = { @Sendable [weak self] connection in
        Task { @MainActor in
          guard let self, self.generation == epoch, self.connections.count < 8 else {
            connection.cancel()
            return
          }
          let id = UUID()
          let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.serve(connection, id: id, epoch: epoch)
          }
          self.connections[id] = (connection, task)
        }
      }
      self.listener = listener
      status = "正在建立经过账号密钥认证的局域网接收通道…"
      listener.start(queue: .global(qos: .userInitiated))
    } catch {
      status = "无法启动本地接收，请稍后重试。"
    }
  }

  public func stop() {
    generation = UUID()
    listener?.cancel()
    listener = nil
    for (_, (connection, task)) in connections { task.cancel(); connection.cancel() }
    connections.removeAll()
    for (_, browser) in browsers { browser.cancel() }
    browsers.removeAll()
    cache.removeAll()
    running = nil
    identity = nil
    isReceiving = false
    listeningPort = nil
    status = "跨设备接收已停止；本机推理仍可单独使用。"
  }

  public func remoteRunners(identity: LocalAIIdentity, timeout: TimeInterval = 2) async -> [any LocalAIRunner] {
    let epoch = generation
    let browser = NWBrowser(for: .bonjour(type: "_myenergy-ai._tcp", domain: nil), using: .tcp)
    let accumulator = AIDiscovery()
    let token = UUID()
    browsers[token] = browser
    browser.browseResultsChangedHandler = { @Sendable results, _ in
      Task { @MainActor in accumulator.endpoints = Array(results.prefix(8).map(\.endpoint)) }
    }
    browser.start(queue: .global(qos: .userInitiated))
    do { try await Task.sleep(nanoseconds: UInt64(max(0.1, min(timeout, 5)) * 1_000_000_000)) }
    catch { browser.cancel(); browsers.removeValue(forKey: token); return [] }
    browser.cancel()
    browsers.removeValue(forKey: token)
    guard generation == epoch, !Task.isCancelled else { return [] }
    let endpoints = accumulator.endpoints.filter {
      if case .service(let name, _, _, _) = $0 { return name != "MyEnergy-\(nodeID.prefix(8))" }
      return true
    }
    let runners = await remoteRunners(at: Array(endpoints.prefix(4)), identity: identity, timeout: timeout)
    guard generation == epoch, !Task.isCancelled else { return [] }
    status = runners.isEmpty
      ? "本次未发现已认证且模型就绪的 iPhone 或 Mac；这不表示其他设备不支持推理。"
      : "已找到 \(runners.count) 个经过账号认证的本地执行选项。"
    return runners
  }

  func remoteRunners(at endpoints: [NWEndpoint], identity: LocalAIIdentity,
    timeout: TimeInterval) async -> [any LocalAIRunner] {
    let ownNode = nodeID
    return await withTaskGroup(of: [AIRemoteRunner].self) { group in
      for endpoint in endpoints.prefix(4) {
        group.addTask {
          do {
            let hello = AIWire(id: UUID(), kind: "capabilities")
            let reply = try await aiExchange(hello, at: endpoint, identity: identity, timeout: timeout)
            guard let node = reply.nodeID, node != ownNode, node.count <= 80,
              let capabilities = reply.capabilities, capabilities.count <= 4 else { return [] }
            return capabilities.filter {
              $0.ready && ($0.executor.role == .iPhone || $0.executor.role == .mac)
                && !$0.executor.isRemote && $0.executor.id.count <= 160
                && $0.executor.modelID.count <= 160 && $0.executor.modelName.count <= 160
            }.map { AIRemoteRunner(endpoint: endpoint, identity: identity, nodeID: node, capability: $0) }
          } catch { return [] }
        }
      }
      var result: [AIRemoteRunner] = []
      for await found in group { result += found }
      return result
    }
  }

  private func serve(_ connection: NWConnection, id: UUID, epoch: UUID) async {
    defer { connection.cancel(); connections.removeValue(forKey: id) }
    do {
      try await aiWithDeadline(connection: connection, timeout: 10) {
        try await aiWaitReady(connection)
      }
      let wire = try await aiWithDeadline(connection: connection, timeout: 10) {
        try await aiReceiveWire(connection)
      }
      guard generation == epoch, identity != nil, wire.version == 1 else { return }
      if wire.kind == "capabilities" {
        var capabilities: [AICapability] = []
        for runner in registry.runners.prefix(4) where !runner.executor.isRemote {
          capabilities.append(AICapability(executor: runner.executor, ready: await runner.availability() == .ready))
        }
        guard generation == epoch else { return }
        try await aiSendWire(AIWire(id: wire.id, kind: "capabilities", nodeID: nodeID,
          capabilities: capabilities), on: connection)
        return
      }
      guard wire.kind == "reflect", let request = wire.request, let modelID = wire.modelID,
        modelID.count <= 160 else { throw LocalAIError.invalidInput("本地请求格式不正确。") }
      try request.validated()
      guard abs(request.createdAt.timeIntervalSinceNow) < 300 else {
        throw LocalAIError.invalidInput("请求已过期，请重新生成。")
      }
      if let saved = cache[request.id] {
        guard saved.0 == request.input.digest, saved.1 == modelID else {
          throw LocalAIError.invalidInput("请求标识对应了不同的输入。")
        }
        try await aiSendWire(AIWire(id: wire.id, kind: "result", nodeID: nodeID, result: saved.2), on: connection)
        return
      }
      guard running == nil else {
        try await aiSendWire(AIWire(id: wire.id, kind: "error", errorKind: "unavailable",
          message: "此设备正在处理另一份复盘，请稍后重试。"), on: connection)
        return
      }
      guard let runner = registry.runners.first(where: {
        $0.executor.modelID == modelID && !$0.executor.isRemote
      }), await runner.availability() == .ready else {
        try await aiSendWire(AIWire(id: wire.id, kind: "error", errorKind: "unavailable",
          message: "此设备的所选模型尚未就绪。"), on: connection)
        return
      }
      guard generation == epoch else { return }
      // availability 会跨 actor 挂起；回来后必须再次检查并在同一 actor turn 占用执行位。
      guard running == nil else {
        try await aiSendWire(AIWire(id: wire.id, kind: "error", errorKind: "unavailable",
          message: "此设备正在处理另一份复盘，请稍后重试。"), on: connection)
        return
      }
      let runID = UUID()
      running = runID
      defer { if running == runID { running = nil } }
      let work = Task { try await runner.reflect(request) }
      let monitor = Task {
        do { _ = try await aiReceiveChunk(connection, maximum: 1, cancelConnection: false) }
        catch {}
        if !Task.isCancelled { work.cancel() }
      }
      defer { monitor.cancel() }
      do {
        let result = try await withTaskCancellationHandler {
          try await work.value
        } onCancel: {
          work.cancel()
          connection.cancel()
        }
        monitor.cancel()
        try Task.checkCancellation()
        guard generation == epoch else { return }
        try result.validated(for: request)
        guard result.executor == runner.executor else {
          throw LocalAIError.invalidOutput("执行器返回了不一致的模型信息。")
        }
        if cache.count >= 16 { cache.removeAll() }
        cache[request.id] = (request.input.digest, modelID, result)
        try await aiSendWire(AIWire(id: wire.id, kind: "result", nodeID: nodeID, result: result), on: connection)
      } catch {
        guard generation == epoch else { return }
        let unavailable: Bool
        if case LocalAIError.unavailable = error { unavailable = true } else { unavailable = false }
        try? await aiSendWire(AIWire(id: wire.id, kind: "error",
          errorKind: unavailable ? "unavailable" : "generationFailed",
          message: unavailable ? "此设备尚未开始生成，模型当前不可用。" : "本次本地生成未完成，请重新尝试。"), on: connection)
      }
    } catch { /* 未认证、超时或无效帧直接关闭，不回显输入。 */ }
  }
}

@MainActor private final class AIDiscovery { var endpoints: [NWEndpoint] = [] }

private struct AIRemoteRunner: LocalAIRunner, @unchecked Sendable {
  // NWEndpoint 是不可变端点值；所有连接都在每次调用内单独创建。
  let endpoint: NWEndpoint
  let identity: LocalAIIdentity
  let nodeID: String
  let localExecutor: LocalAIExecutor
  let executor: LocalAIExecutor

  init(endpoint: NWEndpoint, identity: LocalAIIdentity, nodeID: String, capability: AICapability) {
    self.endpoint = endpoint
    self.identity = identity
    self.nodeID = nodeID
    localExecutor = capability.executor
    executor = LocalAIExecutor(id: "\(nodeID).\(capability.executor.id)", role: capability.executor.role,
      modelID: capability.executor.modelID, modelName: capability.executor.modelName, isRemote: true)
  }

  func availability() async -> LocalAIAvailability { .ready }

  func reflect(_ request: DailyReflectionRequest) async throws -> DailyReflectionResult {
    try Task.checkCancellation()
    try request.validated()
    let wire = AIWire(id: UUID(), kind: "reflect", modelID: localExecutor.modelID, request: request)
    let response = try await aiExchange(wire, at: endpoint, identity: identity, timeout: 90)
    if response.kind == "error" {
      if response.errorKind == "unavailable" { throw LocalAIError.unavailable(response.message ?? "设备尚未开始推理。") }
      throw LocalAIError.generationFailed(response.message ?? "配对设备未完成生成。")
    }
    guard response.kind == "result", response.nodeID == nodeID, let value = response.result,
      value.executor == localExecutor else {
      throw LocalAIError.invalidOutput("配对设备返回了不同的执行信息。")
    }
    try value.validated(for: request)
    return DailyReflectionResult(requestID: value.requestID, inputDigest: value.inputDigest,
      executor: executor, generatedAt: value.generatedAt, draft: value.draft)
  }
}

private let aiMaximumFrame = 24 * 1_024

private func aiTLSParameters(_ identity: LocalAIIdentity) -> NWParameters {
  let options = NWProtocolTLS.Options()
  let key = identity.preSharedKey.withUnsafeBytes { DispatchData(bytes: $0) }
  let labelBytes = Data(SHA256.hash(data: Data(identity.namespace.utf8))
    .map { String(format: "%02x", $0) }.joined().utf8)
  let label = labelBytes.withUnsafeBytes { DispatchData(bytes: $0) }
  sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions, key as __DispatchData, label as __DispatchData)
  // Apple TN3213：NWConnection 的 external PSK 不支持 TLS 1.3；采用官方 P2P 示例套件。
  sec_protocol_options_append_tls_ciphersuite(options.securityProtocolOptions,
    tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
  sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
  sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
  let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
  parameters.includePeerToPeer = true
  return parameters
}

private func aiExchange(_ wire: AIWire, at endpoint: NWEndpoint, identity: LocalAIIdentity,
  timeout: TimeInterval) async throws -> AIWire {
  let connection = NWConnection(to: endpoint, using: aiTLSParameters(identity))
  defer { connection.cancel() }
  let phase = AIPhase()
  do {
    return try await aiWithDeadline(connection: connection, timeout: timeout) {
      try await aiWaitReady(connection)
      try Task.checkCancellation()
      if wire.kind == "reflect" { phase.markSent() }
      try await aiSendWire(wire, on: connection)
      let reply = try await aiReceiveWire(connection)
      guard reply.id == wire.id, reply.version == 1 else {
        throw LocalAIError.invalidOutput("本地设备回复不属于当前请求。")
      }
      return reply
    }
  } catch is CancellationError { throw CancellationError() }
  catch let error as LocalAIError { throw error }
  catch {
    if phase.wasSent {
      throw LocalAIError.remoteUncertain("请求已交给配对设备，但本次未取得结果；不会同时在另一设备重复生成。")
    }
    throw LocalAIError.unavailable("本次无法联系已授权设备，请保持应用前台并检查局域网。")
  }
}

private final class AIPhase: @unchecked Sendable {
  private let lock = NSLock()
  private var sent = false
  func markSent() { lock.lock(); sent = true; lock.unlock() }
  var wasSent: Bool { lock.lock(); defer { lock.unlock() }; return sent }
}

private final class AIGate<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var result: Result<Value, any Error>?
  func install(_ value: CheckedContinuation<Value, any Error>) {
    lock.lock()
    if let result { lock.unlock(); value.resume(with: result) }
    else { continuation = value; lock.unlock() }
  }
  func finish(_ value: Result<Value, any Error>) {
    lock.lock()
    guard result == nil else { lock.unlock(); return }
    result = value
    let target = continuation
    continuation = nil
    lock.unlock()
    target?.resume(with: value)
  }
}

private func aiWithDeadline<T: Sendable>(connection: NWConnection, timeout: TimeInterval,
  operation: @escaping @Sendable () async throws -> T) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(max(0.1, min(timeout, 120)) * 1_000_000_000))
      throw URLError(.timedOut)
    }
    defer { group.cancelAll() }
    guard let value = try await group.next() else { throw CancellationError() }
    return value
  }
}

private func aiWaitReady(_ connection: NWConnection) async throws {
  let gate = AIGate<Void>()
  try await withTaskCancellationHandler {
    try Task.checkCancellation()
    try await withCheckedThrowingContinuation { continuation in
      gate.install(continuation)
      connection.stateUpdateHandler = { @Sendable state in
        switch state {
        case .ready: gate.finish(.success(()))
        case .failed(let error): gate.finish(.failure(error))
        case .cancelled: gate.finish(.failure(CancellationError()))
        default: break
        }
      }
      connection.start(queue: .global(qos: .userInitiated))
    }
  } onCancel: { gate.finish(.failure(CancellationError())); connection.cancel() }
}

private func aiSendWire(_ wire: AIWire, on connection: NWConnection) async throws {
  let body = try JSONEncoder().encode(wire)
  guard !body.isEmpty, body.count <= aiMaximumFrame else {
    throw LocalAIError.invalidInput("本地推理消息超过大小限制。")
  }
  var size = UInt32(body.count).bigEndian
  var frame = withUnsafeBytes(of: &size) { Data($0) }
  frame.append(body)
  let gate = AIGate<Void>()
  try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      gate.install(continuation)
      connection.send(content: frame, completion: .contentProcessed({ @Sendable error in
        if let error { gate.finish(.failure(error)) } else { gate.finish(.success(())) }
      }))
    }
  } onCancel: { gate.finish(.failure(CancellationError())); connection.cancel() }
}

private func aiReceiveWire(_ connection: NWConnection) async throws -> AIWire {
  let header = try await aiReceiveExactly(connection, count: 4)
  let count = Int(header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
  guard count > 0, count <= aiMaximumFrame else { throw LocalAIError.invalidInput("本地消息长度无效。") }
  let body = try await aiReceiveExactly(connection, count: count)
  return try JSONDecoder().decode(AIWire.self, from: body)
}

private func aiReceiveExactly(_ connection: NWConnection, count: Int) async throws -> Data {
  var output = Data()
  while output.count < count {
    try Task.checkCancellation()
    output.append(try await aiReceiveChunk(connection, maximum: count - output.count))
  }
  return output
}

private func aiReceiveChunk(_ connection: NWConnection, maximum: Int, cancelConnection: Bool = true) async throws -> Data {
  let gate = AIGate<Data>()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      gate.install(continuation)
      connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { @Sendable data, _, _, error in
        if let error { gate.finish(.failure(error)) }
        else if let data, !data.isEmpty { gate.finish(.success(data)) }
        else { gate.finish(.failure(URLError(.networkConnectionLost))) }
      }
    }
  } onCancel: {
    gate.finish(.failure(CancellationError()))
    if cancelConnection { connection.cancel() }
  }
}
#endif

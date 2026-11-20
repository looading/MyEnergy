#if !os(watchOS)
import Combine
import Foundation
import MyEnergyCore
import MyEnergyPlatform

struct LocalAIRunnerStatus: Identifiable, Equatable {
  let executor: LocalAIExecutor
  let availability: LocalAIAvailability?
  var id: String { "\(executor.id)|\(executor.modelID)|\(executor.isRemote)" }
}

/// 复盘只存于本页内存；数据、账号和界面代际共同约束异步结果。
@MainActor
final class LocalAIController: ObservableObject {
  @Published private(set) var input: DailyReflectionInput?
  @Published private(set) var inputError: String?
  @Published private(set) var result: DailyReflectionResult?
  @Published private(set) var message: String?
  @Published private(set) var isGenerating = false
  @Published private(set) var generationStatus = "尚未生成复盘。"
  @Published private(set) var runnerStatuses: [LocalAIRunnerStatus] = []
  @Published private(set) var assetState: LocalAIModelAssetState = .notDownloaded
  @Published private(set) var hasModelAssets = false
  @Published private(set) var isDownloading = false
  @Published private(set) var isCancellingDownload = false
  @Published private(set) var allowsSending = false
  @Published private(set) var allowsReceiving = false
  @Published private(set) var canUseCrossDevice = false
  @Published private(set) var crossDeviceExplanation = "跨设备处理默认关闭。"

  let networkHub: LocalAINetworkHub
  private let model: AppModel
  private let registry: LocalAIRegistry
  private let account: AccountController
  private var subscriptions: Set<AnyCancellable> = []
  private var activeTask: Task<Void, Never>?
  private var availabilityTask: Task<Void, Never>?
  private var assetStatusTask: Task<Void, Never>?
  private var downloadTask: Task<Void, Never>?
  private var expiryTask: Task<Void, Never>?
  private var scheduledExpiry: Double?
  private var downloadingAssets: (any LocalAIModelAssetsManaging)?
  private var downloadID: UUID?
  private var generation: UInt64 = 0
  private var availabilityGeneration: UInt64 = 0
  private var assetStatusGeneration: UInt64 = 0
  private var activeRequestID: UUID?
  private var activeUsesRemote = false
  private var scope: Scope?
  private var isVisible = false
  private var isSceneActive = true
  private var receivingIdentity: LocalAIIdentity?
  private var receivingConfigured = false

  private struct Scope: Equatable {
    let storageURL: URL
    let isDemo: Bool
    let accountID: String?
    let serverAddress: String
    let fingerprint: String
  }

  init(model: AppModel, registry: LocalAIRegistry = .shared, account: AccountController = .shared,
       networkHub: LocalAINetworkHub? = nil) {
    self.model = model
    self.registry = registry
    self.account = account
    self.networkHub = networkHub ?? LocalAINetworkHub(registry: registry)
    observeContext()
  }

  var canGenerate: Bool {
    isVisible && isSceneActive && model.isLoaded && !model.hasLoadFailure
      && !isGenerating && !(input?.facts.isEmpty ?? true)
  }

  var canReceiveOnThisDevice: Bool {
    registry.runners.contains { !$0.executor.isRemote && ($0.executor.role == .iPhone || $0.executor.role == .mac) }
  }

  func appear(sceneActive: Bool = true) {
    isVisible = true
    isSceneActive = sceneActive
    refreshContext()
    refreshAvailability()
  }

  func disappear() {
    isVisible = false
    allowsSending = false
    allowsReceiving = false
    runnerStatuses.removeAll { $0.executor.isRemote }
    invalidateGeneration(message: nil)
    availabilityGeneration &+= 1
    availabilityTask?.cancel()
    availabilityTask = nil
    assetStatusGeneration &+= 1
    assetStatusTask?.cancel()
    assetStatusTask = nil
    cancelExpiryTimer()
    cancelDownload()
    stopReceiving()
  }

  func setSceneActive(_ value: Bool) {
    guard value != isSceneActive else { return }
    isSceneActive = value
    if value {
      refreshContext()
      if isVisible { refreshAvailability() }
    } else {
      invalidateGeneration(message: "本页已暂停，返回后可重新生成。")
      cancelDownload()
      cancelExpiryTimer()
      stopReceiving()
    }
  }

  /// 也由页内时钟调用，以便跨日和系统时区变化使旧结果失效。
  func refreshContext() {
    let nextScope = currentScope()
    if let scope, scope != nextScope {
      resetPermissionsAndResult()
    }
    scope = nextScope
    rebuildInput(snapshot: model.snapshot)
    if let session = account.session, !session.expiresAt.isFinite || session.isExpired {
      revokeExpiredRemoteAuthorization()
    }
    let identity = account.localAIIdentity(for: model)
    let sessionValid = account.session.map { $0.expiresAt.isFinite && !$0.isExpired } ?? false
    canUseCrossDevice = !model.isDemo && !account.isBusy && sessionValid && identity != nil
    if model.isDemo {
      crossDeviceExplanation = "示例只在当前设备生成，不查找或发送给其他设备。"
    } else if account.isBusy {
      crossDeviceExplanation = "账号正在处理其他操作，跨设备处理暂时停止。"
    } else if identity == nil || !sessionValid {
      crossDeviceExplanation = "登录同一账号并解锁同一份加密密钥后，才可授权局域网内的 iPhone 或 Mac。未登录时仍可在本机生成。"
    } else {
      crossDeviceExplanation = "仅连接局域网内持有同一账号密钥的设备，不使用云推理。两个授权只在本页有效。"
    }
    configureReceiving()
    scheduleExpiryTimer()
  }

  func setAllowsSending(_ value: Bool) {
    refreshContext()
    guard !value || canUseCrossDevice else { return }
    guard allowsSending != value else { return }
    invalidateGeneration(message: nil)
    allowsSending = value
    runnerStatuses.removeAll { $0.executor.isRemote }
  }

  func setAllowsReceiving(_ value: Bool) {
    refreshContext()
    guard !value || (canUseCrossDevice && canReceiveOnThisDevice) else { return }
    allowsReceiving = value
    configureReceiving()
  }

  func refreshAvailability() {
    guard isVisible else { return }
    availabilityGeneration &+= 1
    let version = availabilityGeneration
    availabilityTask?.cancel()
    let runners = registry.runners
    let existing = runnerStatuses.filter { $0.executor.isRemote }
    runnerStatuses = runners.map { LocalAIRunnerStatus(executor: $0.executor, availability: nil) } + existing
    availabilityTask = Task { [weak self] in
      var checked: [LocalAIRunnerStatus] = []
      for runner in runners {
        let state = await runner.availability()
        guard !Task.isCancelled else { return }
        checked.append(LocalAIRunnerStatus(executor: runner.executor, availability: state))
      }
      guard let self, self.isVisible, self.availabilityGeneration == version else { return }
      self.runnerStatuses = checked + self.runnerStatuses.filter { $0.executor.isRemote }
      self.availabilityTask = nil
    }
    refreshAssetStatus()
  }

  @discardableResult
  func generate() -> Task<Void, Never>? {
    refreshContext()
    guard canGenerate, let input, let scope else { return nil }
    invalidateGeneration(message: nil)
    let request = DailyReflectionRequest(input: input)
    let version = generation
    activeRequestID = request.id
    isGenerating = true
    result = nil
    runnerStatuses.removeAll { $0.executor.isRemote }
    let identity = allowsSending && canUseCrossDevice ? account.localAIIdentity(for: model) : nil
    activeUsesRemote = identity != nil
    generationStatus = identity == nil ? "正在本机准备复盘…" : "正在查找已授权的 iPhone 和 Mac…"
    let localRunners = registry.runners
    activeTask = Task { [weak self] in
      guard let self else { return }
      defer { self.finishGeneration(version: version, requestID: request.id) }
      do {
        var runners = localRunners
        if let identity {
          let remote = await self.networkHub.remoteRunners(identity: identity, timeout: 2)
          try Task.checkCancellation()
          guard self.isCurrent(request, version: version, scope: scope) else {
            self.refreshContext()
            return
          }
          for runner in remote {
            let state = await runner.availability()
            try Task.checkCancellation()
            guard self.isCurrent(request, version: version, scope: scope) else {
              self.refreshContext()
              return
            }
            self.runnerStatuses.append(LocalAIRunnerStatus(executor: runner.executor, availability: state))
          }
          runners += remote
          self.generationStatus = remote.isEmpty
            ? "未发现可连接的已授权设备，正在检查本机模型…"
            : "按 iPhone、Mac 的顺序选择已就绪模型并生成…"
        }
        let generated = try await LocalAIRouter.generate(request, runners: runners)
        try Task.checkCancellation()
        guard self.isCurrent(request, version: version, scope: scope) else {
          self.refreshContext()
          return
        }
        self.result = try generated.validated(for: request)
        self.generationStatus = "本次复盘已生成，仅保留在当前页面。"
      } catch is CancellationError {
        // 主动取消或上下文失效已经同步清理界面，不让晚到回调覆盖新状态。
        if self.isCurrent(request, version: version, scope: scope) {
          self.message = "本次生成已取消，没有生成结果。"
          self.generationStatus = "本次复盘已取消。"
        }
      } catch {
        guard self.isCurrent(request, version: version, scope: scope) else { return }
        self.message = error.localizedDescription
        self.generationStatus = "本次复盘未完成，没有自动修改记录或习惯。"
      }
    }
    return activeTask
  }

  func cancelGeneration() {
    invalidateGeneration(message: "已停止等待本次复盘，旧结果不会显示。")
  }

  func downloadModel() {
    guard isVisible, isSceneActive, downloadTask == nil, !isCancellingDownload,
          let assets = registry.modelAssets else { return }
    if case .ready = assetState { return }
    if case .downloading = assetState { return }
    assetStatusGeneration &+= 1
    assetStatusTask?.cancel()
    assetStatusTask = nil
    let id = UUID()
    downloadID = id
    downloadingAssets = assets
    isDownloading = true
    assetState = .downloading(0)
    downloadTask = Task { [weak self] in
      do {
        try await assets.download { [weak self] progress in
          Task { @MainActor [weak self] in
            guard let self, self.downloadID == id else { return }
            let value = progress.isFinite ? min(1, max(0, progress)) : 0
            self.assetState = .downloading(value)
          }
        }
        try Task.checkCancellation()
        let state = await assets.status()
        guard let self, self.downloadID == id else { return }
        self.assetState = state
        self.finishDownload(id: id)
        self.refreshAvailability()
      } catch {
        guard let self, self.downloadID == id else { return }
        self.assetState = error is CancellationError ? .notDownloaded : .failed(error.localizedDescription)
        self.finishDownload(id: id)
      }
    }
  }

  func cancelDownload() {
    guard let cancellingTask = downloadTask, let assets = downloadingAssets else { return }
    assetStatusGeneration &+= 1
    assetStatusTask?.cancel()
    assetStatusTask = nil
    downloadID = nil
    cancellingTask.cancel()
    downloadTask = nil
    downloadingAssets = nil
    isDownloading = false
    isCancellingDownload = true
    Task { [weak self] in
      // store 把调用任务的取消传给其自有下载；不能取消其他页面持有的下载。
      await cancellingTask.value
      let state = await assets.status()
      guard let self else { return }
      self.assetState = state
      self.isCancellingDownload = false
      if self.isVisible { self.refreshAvailability() }
    }
  }

  private func finishDownload(id: UUID) {
    guard downloadID == id else { return }
    downloadID = nil
    downloadTask = nil
    downloadingAssets = nil
    isDownloading = false
  }

  private func refreshAssetStatus() {
    hasModelAssets = registry.modelAssets != nil
    guard !isDownloading, !isCancellingDownload, let assets = registry.modelAssets else { return }
    assetStatusGeneration &+= 1
    let version = assetStatusGeneration
    assetStatusTask?.cancel()
    assetStatusTask = Task { [weak self] in
      let state = await assets.status()
      guard !Task.isCancelled, let self, self.isVisible,
            self.assetStatusGeneration == version, !self.isDownloading, !self.isCancellingDownload else { return }
      self.assetState = state
      self.assetStatusTask = nil
    }
  }

  private func currentScope() -> Scope {
    Scope(storageURL: model.storageURL.standardizedFileURL, isDemo: model.isDemo,
      accountID: account.session?.accountID, serverAddress: account.serverAddress,
      fingerprint: account.fingerprint)
  }

  private func rebuildInput(snapshot: AppSnapshot) {
    guard model.isLoaded, !model.hasLoadFailure else {
      invalidateGeneration(message: nil)
      input = nil
      inputError = model.hasLoadFailure ? "本机记录读取失败，恢复读取后再生成复盘。" : "正在读取本机记录…"
      return
    }
    do {
      let rebuilt = try DailyReflectionInputBuilder.build(snapshot: snapshot, day: Date(), timeZone: .current)
      if let input, input.digest != rebuilt.digest {
        let hadResult = result != nil || isGenerating
        invalidateGeneration(message: hadResult ? "记录或复盘日期已改变，请根据最新事实重新生成。" : nil)
        runnerStatuses.removeAll { $0.executor.isRemote }
      }
      input = rebuilt
      inputError = nil
    } catch {
      invalidateGeneration(message: nil)
      input = nil
      inputError = error.localizedDescription
    }
  }

  private func isCurrent(_ request: DailyReflectionRequest, version: UInt64, scope: Scope) -> Bool {
    guard !Task.isCancelled, isVisible, isSceneActive, generation == version,
          activeRequestID == request.id, currentScope() == scope,
          let rebuilt = try? DailyReflectionInputBuilder.build(snapshot: model.snapshot, day: Date(), timeZone: .current)
    else { return false }
    if activeUsesRemote {
      guard allowsSending, let session = account.session, session.expiresAt.isFinite, !session.isExpired else { return false }
    }
    return rebuilt.digest == request.input.digest
  }

  private func finishGeneration(version: UInt64, requestID: UUID) {
    guard generation == version, activeRequestID == requestID else { return }
    activeTask = nil
    activeRequestID = nil
    activeUsesRemote = false
    isGenerating = false
  }

  private func invalidateGeneration(message: String?) {
    generation &+= 1
    activeTask?.cancel()
    activeTask = nil
    activeRequestID = nil
    activeUsesRemote = false
    isGenerating = false
    result = nil
    self.message = message
    generationStatus = "尚未生成复盘。"
  }

  private func resetPermissionsAndResult() {
    allowsSending = false
    allowsReceiving = false
    stopReceiving()
    invalidateGeneration(message: "数据空间或账号已改变，复盘结果和跨设备授权已清除。")
    input = nil
    runnerStatuses.removeAll { $0.executor.isRemote }
  }

  private func configureReceiving() {
    let identity = isVisible && isSceneActive && canUseCrossDevice && canReceiveOnThisDevice && allowsReceiving
      ? account.localAIIdentity(for: model) : nil
    let shouldReceive = identity != nil
    guard identity != receivingIdentity || shouldReceive != receivingConfigured else { return }
    receivingIdentity = identity
    receivingConfigured = shouldReceive
    if shouldReceive { networkHub.configure(identity: identity, allowReceiving: true) }
    else { networkHub.stop() }
  }

  private func stopReceiving() {
    networkHub.stop()
    receivingIdentity = nil
    receivingConfigured = false
  }

  private func revokeExpiredRemoteAuthorization() {
    guard allowsSending || allowsReceiving || activeUsesRemote || result?.executor.isRemote == true else { return }
    allowsSending = false
    allowsReceiving = false
    stopReceiving()
    runnerStatuses.removeAll { $0.executor.isRemote }
    let explanation = "账号会话已到期，跨设备处理已停止。可以继续使用本机模型。"
    if activeUsesRemote {
      invalidateGeneration(message: explanation)
    } else if result?.executor.isRemote == true {
      result = nil
      message = explanation
      generationStatus = "尚未生成复盘。"
    }
  }

  private func scheduleExpiryTimer() {
    guard isVisible, isSceneActive, let expiresAt = account.session?.expiresAt, expiresAt.isFinite,
          expiresAt > Date().timeIntervalSince1970 else {
      cancelExpiryTimer()
      return
    }
    guard scheduledExpiry != expiresAt || expiryTask == nil else { return }
    cancelExpiryTimer()
    scheduledExpiry = expiresAt
    expiryTask = Task { [weak self] in
      while !Task.isCancelled {
        let remaining = expiresAt - Date().timeIntervalSince1970
        if remaining <= 0 {
          guard let self else { return }
          self.expiryTask = nil
          self.scheduledExpiry = nil
          self.refreshContext()
          return
        }
        do { try await Task.sleep(nanoseconds: UInt64(min(30, remaining) * 1_000_000_000)) }
        catch { return }
      }
    }
  }

  private func cancelExpiryTimer() {
    expiryTask?.cancel()
    expiryTask = nil
    scheduledExpiry = nil
  }

  private func observeContext() {
    model.$snapshot.dropFirst().sink { [weak self] snapshot in
      self?.rebuildInput(snapshot: snapshot)
    }.store(in: &subscriptions)
    model.$storageURL.removeDuplicates().dropFirst().sink { [weak self] _ in self?.scopeWillChange() }.store(in: &subscriptions)
    model.$isDemo.removeDuplicates().dropFirst().sink { [weak self] _ in self?.scopeWillChange() }.store(in: &subscriptions)
    model.$isLoaded.dropFirst().sink { [weak self] _ in self?.enqueueContextRefresh() }.store(in: &subscriptions)
    model.$hasLoadFailure.dropFirst().sink { [weak self] _ in self?.enqueueContextRefresh() }.store(in: &subscriptions)
    account.$fingerprint.removeDuplicates().dropFirst().sink { [weak self] _ in self?.scopeWillChange() }.store(in: &subscriptions)
    account.$session.map { $0?.accountID }.removeDuplicates().dropFirst()
      .sink { [weak self] _ in self?.scopeWillChange() }.store(in: &subscriptions)
    account.$session.dropFirst().sink { [weak self] _ in self?.enqueueContextRefresh() }.store(in: &subscriptions)
    account.$serverAddress.removeDuplicates().dropFirst().sink { [weak self] _ in self?.scopeWillChange() }.store(in: &subscriptions)
    account.$isBusy.dropFirst().sink { [weak self] _ in self?.enqueueContextRefresh() }.store(in: &subscriptions)
    registry.$revision.dropFirst().sink { [weak self] _ in self?.refreshAvailability() }.store(in: &subscriptions)
  }

  private func scopeWillChange() {
    resetPermissionsAndResult()
    enqueueContextRefresh()
  }

  private func enqueueContextRefresh() {
    // @Published 在属性赋值前通知；下一个 MainActor job 才读取完整的新上下文。
    Task { @MainActor [weak self] in self?.refreshContext() }
  }
}
#endif

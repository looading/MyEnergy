import Foundation
import MyEnergyCore
import MyEnergyPlatform
@testable import MyEnergyUI
import Testing

@Suite("Watch health lifecycle", .serialized)
struct WatchHealthModelTests {
    @Test @MainActor func unsupportedDisconnectedAndDemoNeverReadAutomatically() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.load()
        fixture.client.isAvailable = false
        await model.connectHealth()
        #expect(model.healthError != nil)
        #expect(!model.healthConnected)
        fixture.client.isAvailable = true
        await model.refreshHealth()
        await model.refreshHealthIfNeeded()
        model.startDemo()
        await model.connectHealth()
        await model.refreshHealthIfNeeded()
        #expect(fixture.client.authorizationRequests == 0)
        #expect(fixture.client.queryDates.isEmpty)
    }

    @Test @MainActor func authorizationFailureNeedsExplicitRetry() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        fixture.client.authorizationError = .authorization
        await model.connectHealth()
        #expect(!model.healthConnected)
        #expect(!model.isRefreshingHealth)
        #expect(model.healthReport == nil)
        #expect(model.healthError != nil)
        await model.refreshHealthIfNeeded()
        #expect(fixture.client.authorizationRequests == 1)
        #expect(fixture.client.queryDates.isEmpty)
        fixture.client.authorizationError = nil
        await model.connectHealth()
        #expect(model.healthConnected)
        #expect(model.healthReportHasData)
        #expect(model.healthError == nil)
        #expect(fixture.client.authorizationRequests == 2)
    }

    @Test @MainActor func repeatedConnectionsDoNotDuplicateAuthorizationOrReads() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        fixture.client.pausesAuthorization = true
        fixture.client.pausesReads = true
        let connection = Task { await model.connectHealth() }
        await fixture.client.waitForAuthorizationRequests(1)
        await model.connectHealth()
        await model.refreshHealth()
        await model.refreshHealthIfNeeded()
        #expect(model.isRefreshingHealth)
        #expect(fixture.client.authorizationRequests == 1)
        #expect(fixture.client.queryDates.isEmpty)
        fixture.client.resumeAuthorization()
        await fixture.client.waitForReads(1)
        await model.connectHealth()
        await model.refreshHealth()
        await model.refreshHealthIfNeeded()
        #expect(fixture.client.queryDates.count == 1)
        fixture.client.resumeNextRead()
        await connection.value
        await model.connectHealth()
        #expect(fixture.client.authorizationRequests == 1)
        #expect(fixture.client.queryDates.count == 1)
        #expect(!model.isRefreshingHealth)
    }

    @Test @MainActor func queryFailureKeepsConnectionAndManualRetryDoesNotAuthorize() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        fixture.client.readError = .query
        await model.connectHealth()
        #expect(model.healthConnected)
        #expect(model.healthReport == nil)
        #expect(model.healthError != nil)
        #expect(!model.isRefreshingHealth)
        fixture.client.readError = nil
        await model.refreshHealth()
        #expect(model.healthReportHasData)
        #expect(model.healthError == nil)
        #expect(fixture.client.authorizationRequests == 1)
        #expect(fixture.client.queryDates.count == 2)
    }

    @Test @MainActor func failedRefreshPreservesReportAndManualRetryBypassesThrottle() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.connectHealth()
        let original = try #require(model.healthReport)
        fixture.client.readError = .query
        await model.refreshHealth()
        #expect(model.healthReport?.recovery == original.recovery)
        #expect(model.healthReport?.updatedAt == original.updatedAt)
        #expect(model.healthError != nil)
        let attemptedAt = try #require(fixture.client.queryDates.last)
        await model.refreshHealthIfNeeded(now: attemptedAt.addingTimeInterval(299))
        #expect(fixture.client.queryDates.count == 2)
        fixture.client.readError = nil
        fixture.client.report = WatchHealthFixture.report(hrv: 55)
        await model.refreshHealth()
        #expect(model.healthReport?.recovery.latestMS == 55)
        #expect(model.healthError == nil)
        #expect(fixture.client.queryDates.count == 3)
        #expect(fixture.client.authorizationRequests == 1)
    }

    @Test @MainActor func foregroundThrottleUsesLastAttemptIncludingFailure() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.connectHealth()
        let firstAttempt = try #require(fixture.client.queryDates.first)
        await model.refreshHealthIfNeeded(now: firstAttempt.addingTimeInterval(299))
        #expect(fixture.client.queryDates.count == 1)
        fixture.client.readError = .query
        await model.refreshHealthIfNeeded(now: firstAttempt.addingTimeInterval(300))
        #expect(fixture.client.queryDates.count == 2)
        #expect(model.healthError != nil)
        fixture.client.readError = nil
        await model.refreshHealthIfNeeded(now: firstAttempt.addingTimeInterval(599))
        #expect(fixture.client.queryDates.count == 2)
        await model.refreshHealthIfNeeded(now: firstAttempt.addingTimeInterval(600))
        #expect(fixture.client.queryDates.count == 3)
        #expect(fixture.client.queryDates.last == firstAttempt.addingTimeInterval(600))
        #expect(fixture.client.authorizationRequests == 1)
        #expect(model.healthError == nil)
    }

    @Test @MainActor func emptyReadIsConnectedWithoutAssumingDeniedPermission() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.load()
        fixture.client.report = HealthReport(recovery: .init(status: .unavailable),
            sourceDescription: "Explicit empty test fixture; not HealthKit data")
        await model.connectHealth()
        #expect(model.healthConnected)
        #expect(model.healthReport != nil)
        #expect(!model.healthReportHasData)
        #expect(model.healthError == nil)
        #expect(!(await model.setHealthSharing(true)))
        #expect(!model.healthSharingEnabled)
    }

    @Test @MainActor func disconnectDuringAuthorizationDiscardsLateFailure() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        fixture.client.pausesAuthorization = true
        fixture.client.authorizationError = .authorization
        let connection = Task { await model.connectHealth() }
        await fixture.client.waitForAuthorizationRequests(1)
        model.disconnectHealth()
        #expect(!model.isRefreshingHealth)
        fixture.client.resumeAuthorization()
        await connection.value
        #expect(!model.healthConnected)
        #expect(model.healthReport == nil)
        #expect(model.healthError == nil)
        #expect(fixture.client.queryDates.isEmpty)
    }

    @Test @MainActor func disconnectDuringReadDiscardsLateReport() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        fixture.client.pausesReads = true
        let connection = Task { await model.connectHealth() }
        await fixture.client.waitForReads(1)
        model.disconnectHealth()
        fixture.client.resumeNextRead()
        await connection.value
        #expect(!model.healthConnected)
        #expect(!model.isRefreshingHealth)
        #expect(model.healthReport == nil)
        #expect(model.healthError == nil)
        await model.refreshHealthIfNeeded()
        #expect(fixture.client.queryDates.count == 1)
    }

    @Test @MainActor func oldCompletionCannotEndAReconnectedRead() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        fixture.client.pausesReads = true
        let oldConnection = Task { await model.connectHealth() }
        await fixture.client.waitForReads(1)
        model.disconnectHealth()
        fixture.client.report = WatchHealthFixture.report(hrv: 63)
        let newConnection = Task { await model.connectHealth() }
        await fixture.client.waitForReads(2)
        fixture.client.resumeNextRead()
        await oldConnection.value
        #expect(model.isRefreshingHealth)
        #expect(model.healthConnected)
        #expect(model.healthReport == nil)
        fixture.client.resumeNextRead()
        await newConnection.value
        #expect(!model.isRefreshingHealth)
        #expect(model.healthReport?.recovery.latestMS == 63)
        #expect(fixture.client.authorizationRequests == 2)
    }

    @Test(arguments: [false, true]) @MainActor
    func spaceSwitchAndDemoDiscardInFlightResults(usesDemo: Bool) async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.load()
        fixture.client.pausesReads = true
        let connection = Task { await model.connectHealth() }
        await fixture.client.waitForReads(1)
        if usesDemo { model.startDemo() }
        else { try await model.switchStorage(to: fixture.folder.appendingPathComponent("next/records.json")) }
        fixture.client.resumeNextRead()
        await connection.value
        #expect(!model.healthConnected)
        #expect(!model.healthSharingEnabled)
        #expect(!model.isRefreshingHealth)
        #expect(model.healthReport == nil)
        #expect(model.healthError == nil)
    }

    @Test @MainActor func failedStorageSwitchKeepsTheCurrentReadAndContext() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.updateCompanionHealthContext(namespace: "account:development:first")
        await model.load()
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        let corrupt = fixture.folder.appendingPathComponent("corrupt.json")
        try Data("deliberately invalid snapshot".utf8).write(to: corrupt)
        fixture.client.pausesReads = true
        let connection = Task { await model.connectHealth() }
        await fixture.client.waitForReads(1)
        let previousURL = model.storageURL
        do {
            try await model.switchStorage(to: corrupt)
            Issue.record("a corrupt companion space must not be adopted")
        } catch {}
        #expect(model.storageURL == previousURL)
        #expect(model.hasHealthSharingAccountContext)
        #expect(model.isRefreshingHealth)
        fixture.client.resumeNextRead()
        await connection.value
        #expect(model.healthConnected)
        #expect(model.healthReportHasData)
    }

    @Test @MainActor func anonymousCompanionCannotShareEvenFromANondefaultFile() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        try await model.switchStorage(to: fixture.folder.appendingPathComponent("watch-spaces/anonymous.json"))
        model.updateCompanionHealthContext(namespace: "local-paired")
        await model.connectHealth()
        #expect(model.healthReportHasData)
        #expect(!model.hasHealthSharingAccountContext)
        #expect(!(await model.setHealthSharing(true)))
        #expect(model.snapshot.sharedHealthSummaries.isEmpty)
        for namespace in ["", "account", "account:scope:", "account::person", "account:scope:person:extra",
                          "account:scope:has space", "account:scope:用户", "account:scope:" + String(repeating: "x", count: 128)] {
            model.updateCompanionHealthContext(namespace: namespace)
            #expect(!model.hasHealthSharingAccountContext)
        }
    }

    @Test @MainActor func companionAccountSharingCanBeEnabledRevokedAndStoppedByNamespaceChange() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.updateCompanionHealthContext(namespace: "account:development:first")
        await model.load()
        await model.connectHealth()
        #expect(model.hasHealthSharingAccountContext)
        #expect(await model.setHealthSharing(true))
        let first = try #require(model.snapshot.sharedHealthSummaries.first)
        #expect(await model.setHealthSharing(false))
        #expect(!model.healthSharingEnabled)
        #expect(model.snapshot.sharedHealthSummaries.isEmpty)
        #expect(model.snapshot.deletions.contains { $0.entity == .healthSummary && $0.entityID == first.id.uuidString })
        #expect(await model.setHealthSharing(true))
        let sharedSnapshot = model.snapshot
        model.updateCompanionHealthContext(namespace: "account:development:first")
        #expect(model.healthConnected)
        #expect(model.healthSharingEnabled)
        model.updateCompanionHealthContext(namespace: "account:development:second")
        #expect(model.hasHealthSharingAccountContext)
        #expect(!model.healthSharingEnabled)
        #expect(!model.healthConnected)
        #expect(model.healthReport == nil)
        #expect(model.snapshot == sharedSnapshot)
        #expect(!(await model.shareLatestHealthReport()))
        model.updateCompanionHealthContext(namespace: "local-paired")
        #expect(!model.hasHealthSharingAccountContext)
    }

    @Test @MainActor func companionNamespaceChangeDiscardsInFlightRead() async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.updateCompanionHealthContext(namespace: "account:development:first")
        fixture.client.pausesReads = true
        let connection = Task { await model.connectHealth() }
        await fixture.client.waitForReads(1)
        model.updateCompanionHealthContext(namespace: "account:development:second")
        fixture.client.resumeNextRead()
        await connection.value
        #expect(!model.healthConnected)
        #expect(!model.healthSharingEnabled)
        #expect(model.healthReport == nil)
        #expect(!model.isRefreshingHealth)
    }

    @Test(arguments: [false, true]) @MainActor
    func delayedSharingConfirmationCannotChangeAnotherAccount(enabled: Bool) async throws {
        let fixture = try WatchHealthFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.updateCompanionHealthContext(namespace: "account:development:first")
        await model.load()
        await model.connectHealth()
        #expect(await model.setHealthSharing(true))
        let confirmedURL = model.storageURL

        // 在账号 A 打开确认后暂停动作调度，账号 B 启用自己的摘要后才执行旧确认。
        let (confirmation, resumeConfirmation) = AsyncStream<Void>.makeStream()
        let delayedAction = Task { @MainActor in
            for await _ in confirmation { break }
            return await model.setHealthSharing(enabled, expectedStorageURL: confirmedURL)
        }
        try await model.switchStorage(to: fixture.folder.appendingPathComponent("account-two/records.json"))
        model.updateCompanionHealthContext(namespace: "account:development:second")
        fixture.client.report = WatchHealthFixture.report(hrv: 63)
        await model.connectHealth()
        let currentURL = model.storageURL
        #expect(await model.setHealthSharing(true, expectedStorageURL: currentURL))
        let currentSnapshot = model.snapshot
        let currentDisk = try Data(contentsOf: currentURL)
        let currentHealthError = model.healthError
        let currentStorageError = model.errorMessage
        let currentSavedAt = model.lastSavedAt

        resumeConfirmation.yield(())
        resumeConfirmation.finish()
        #expect(!(await delayedAction.value))
        #expect(!(await model.setHealthSharing(false, expectedStorageURL: confirmedURL)))
        #expect(!(await model.setHealthSharing(true, expectedStorageURL: confirmedURL)))
        #expect(model.healthSharingEnabled)
        #expect(model.snapshot == currentSnapshot)
        #expect(try Data(contentsOf: currentURL) == currentDisk)
        #expect(model.healthError == currentHealthError)
        #expect(model.errorMessage == currentStorageError)
        #expect(model.lastSavedAt == currentSavedAt)
        #expect(model.healthReport?.recovery.latestMS == 63)

        let currentSummary = try #require(currentSnapshot.sharedHealthSummaries.first)
        #expect(await model.setHealthSharing(false, expectedStorageURL: currentURL))
        #expect(!model.healthSharingEnabled)
        #expect(model.snapshot.sharedHealthSummaries.isEmpty)
        #expect(model.snapshot.deletions.contains { $0.entity == .healthSummary && $0.entityID == currentSummary.id.uuidString })
        let saved = try await SnapshotFileStore(url: currentURL).load()
        #expect(saved == model.snapshot)
    }

    @Test func recoveryPresentationRechecksTheTwentyFourHourBoundary() {
        let sampledAt = Date(timeIntervalSince1970: 1_700_000_000)
        let report = RecoverySummary(status: .ready, latestMS: 42, baselineMS: 40,
            changePercent: 5, sampledAt: sampledAt, historyDays: 7)
        #expect(HealthReferencePresentation.recoveryStatus(report, now: sampledAt.addingTimeInterval(86_400)) == .ready)
        let later = sampledAt.addingTimeInterval(86_401)
        #expect(HealthReferencePresentation.recoveryStatus(report, now: later) == .stale)
        #expect(HealthReferencePresentation.recoveryText(report, now: later).contains("超过 24 小时"))
        let insufficient = RecoverySummary(status: .insufficientHistory, latestMS: 42, sampledAt: sampledAt, historyDays: 2)
        #expect(HealthReferencePresentation.recoveryText(insufficient, now: sampledAt).contains("2 个有效日"))
        #expect(HealthReferencePresentation.recoveryStatus(insufficient, now: later) == .stale)
    }

    @Test func recoveryPresentationTreatsMissingInvalidAndFutureSamplesAsUnavailable() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cases = [
            RecoverySummary(status: .ready),
            RecoverySummary(status: .ready, latestMS: 42),
            RecoverySummary(status: .ready, latestMS: .nan, sampledAt: now),
            RecoverySummary(status: .ready, latestMS: -.infinity, sampledAt: now),
            RecoverySummary(status: .ready, latestMS: 0, sampledAt: now),
            RecoverySummary(status: .ready, latestMS: 42, sampledAt: Date(timeIntervalSinceReferenceDate: .nan)),
            RecoverySummary(status: .ready, latestMS: 42, sampledAt: now.addingTimeInterval(1))
        ]
        for recovery in cases {
            #expect(HealthReferencePresentation.recoveryStatus(recovery, now: now) == .unavailable)
            #expect(HealthReferencePresentation.recoveryText(recovery, now: now).contains("暂无可显示"))
        }
        let valid = RecoverySummary(status: .insufficientHistory, latestMS: 42, sampledAt: now)
        #expect(HealthReferencePresentation.recoveryStatus(valid, now: Date(timeIntervalSinceReferenceDate: .infinity)) == .unavailable)
    }
}

@MainActor
private struct WatchHealthFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "MyEnergy.WatchHealthModelTests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let client: PausingHealthClient
    let model: AppModel

    init() throws {
        preferences = try #require(UserDefaults(suiteName: suite))
        client = PausingHealthClient(report: Self.report())
        model = AppModel(storageURL: folder.appendingPathComponent("account/records.json"),
            healthClient: client, preferences: preferences)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: folder)
        preferences.removePersistentDomain(forName: suite)
    }

    static func report(hrv: Double = 42) -> HealthReport {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        return HealthReport(recovery: .init(status: .insufficientHistory, latestMS: hrv, sampledAt: time),
            updatedAt: time, sourceDescription: "Explicit lifecycle test fixture; not HealthKit data")
    }
}

@MainActor
private final class PausingHealthClient: AppHealthClient {
    enum Failure: LocalizedError {
        case authorization, query
        var errorDescription: String? {
            switch self {
            case .authorization: "Explicit authorization failure fixture"
            case .query: "Explicit query failure fixture"
            }
        }
    }

    var isAvailable = true
    var report: HealthReport
    var authorizationError: Failure?
    var readError: Failure?
    var pausesAuthorization = false
    var pausesReads = false
    private(set) var authorizationRequests = 0
    private(set) var queryDates: [Date] = []
    private var authorizationPause: CheckedContinuation<Void, Never>?
    private var readPauses: [CheckedContinuation<Void, Never>] = []
    private var authorizationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var readWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(report: HealthReport) { self.report = report }

    func requestReadAccess() async throws {
        authorizationRequests += 1
        let error = authorizationError
        if pausesAuthorization {
            await withCheckedContinuation { continuation in
                authorizationPause = continuation
                notifyAuthorizationWaiters()
            }
        } else { notifyAuthorizationWaiters() }
        if let error { throw error }
    }

    func fetchReport(now: Date) async throws -> HealthReport {
        queryDates.append(now)
        let result = report
        let error = readError
        if pausesReads {
            await withCheckedContinuation { continuation in
                readPauses.append(continuation)
                notifyReadWaiters()
            }
        } else { notifyReadWaiters() }
        if let error { throw error }
        return result
    }

    func waitForAuthorizationRequests(_ count: Int) async {
        guard authorizationRequests < count else { return }
        await withCheckedContinuation { authorizationWaiters.append((count, $0)) }
    }

    func waitForReads(_ count: Int) async {
        guard queryDates.count < count else { return }
        await withCheckedContinuation { readWaiters.append((count, $0)) }
    }

    func resumeAuthorization() {
        let continuation = authorizationPause
        authorizationPause = nil
        continuation?.resume()
    }

    func resumeNextRead() {
        guard !readPauses.isEmpty else { Issue.record("expected a suspended health read"); return }
        readPauses.removeFirst().resume()
    }

    private func notifyAuthorizationWaiters() {
        let ready = authorizationWaiters.filter { $0.0 <= authorizationRequests }
        authorizationWaiters.removeAll { $0.0 <= authorizationRequests }
        for (_, continuation) in ready { continuation.resume() }
    }

    private func notifyReadWaiters() {
        let ready = readWaiters.filter { $0.0 <= queryDates.count }
        readWaiters.removeAll { $0.0 <= queryDates.count }
        for (_, continuation) in ready { continuation.resume() }
    }
}

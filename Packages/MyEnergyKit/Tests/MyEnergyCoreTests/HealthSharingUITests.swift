import Foundation
import MyEnergyCore
import MyEnergyPlatform
@testable import MyEnergyUI
import Testing

@Suite("Explicit health summary sharing", .serialized)
struct HealthSharingUITests {
    @Test @MainActor func readingHealthDoesNotEnableOrPublishSharing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.load()
        #expect(!model.healthSharingEnabled)
        #expect(fixture.client.authorizationRequests == 0)
        await model.connectHealth()
        #expect(model.healthReportHasData)
        #expect(!model.healthSharingEnabled)
        #expect(model.snapshot.sharedHealthSummaries.isEmpty)
        #expect(!(await model.shareLatestHealthReport()))
        #expect(fixture.client.authorizationRequests == 1)

        let anonymous = AppModel(healthClient: fixture.client, preferences: fixture.preferences)
        #expect(!anonymous.hasHealthSharingAccountContext)
        #expect(!(await anonymous.setHealthSharing(true)))
        #expect(fixture.client.authorizationRequests == 1)
    }

    @Test @MainActor func enabledRefreshKeepsIDAndRevocationPreservesOtherDevices() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.load()
        await model.connectHealth()
        #expect(await model.setHealthSharing(true))
        let first = try #require(model.snapshot.sharedHealthSummaries.first)
        fixture.client.report = Fixture.report(hrv: 57, date: first.updatedAt.addingTimeInterval(60))
        await model.refreshHealth()
        #expect(model.snapshot.sharedHealthSummaries.count == 1)
        #expect(model.snapshot.sharedHealthSummaries.first?.id == first.id)
        #expect(model.snapshot.sharedHealthSummaries.first?.recovery.latestMS == 57)

        let other = try SharedHealthSummary(sourceIdentifier: "other-device", sourceDescription: "Explicit test fixture",
            recovery: Fixture.report(hrv: 41).recovery)
        var received = model.snapshot
        received.sharedHealthSummaries.append(other)
        try await model.replaceSnapshot(received)
        #expect(await model.setHealthSharing(false))
        #expect(!model.healthSharingEnabled)
        #expect(model.snapshot.sharedHealthSummaries == [other])
        #expect(model.snapshot.deletions.contains { $0.entity == .healthSummary && $0.entityID == first.id.uuidString })

        #expect(await model.setHealthSharing(true))
        let newOwn = try #require(model.snapshot.sharedHealthSummaries.first { $0.sourceIdentifier == first.sourceIdentifier })
        #expect(newOwn.id != first.id)
        #expect(model.snapshot.sharedHealthSummaries.contains(other))
        #expect(model.snapshot.deletions.contains { $0.entity == .healthSummary && $0.entityID == first.id.uuidString })
    }

    @Test @MainActor func accountSwitchStopsSharingWithoutDeletingOldAccountSummary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.load()
        await model.connectHealth()
        #expect(await model.setHealthSharing(true))
        let oldSnapshot = model.snapshot
        let oldURL = model.storageURL
        try await model.switchStorage(to: fixture.folder.appendingPathComponent("account-two/records.json"))
        #expect(!model.healthSharingEnabled)
        #expect(!model.healthConnected)
        #expect(model.healthReport == nil)
        #expect(model.snapshot.sharedHealthSummaries.isEmpty)
        #expect(!(await model.shareLatestHealthReport()))
        let retained = try await SnapshotFileStore(url: oldURL).load()
        #expect(retained == oldSnapshot)
    }

    @Test @MainActor func demoCannotShareAndWholeDataDeletionIncludesHealthTombstones() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.load()
        await model.connectHealth()
        #expect(await model.setHealthSharing(true))
        let shared = try #require(model.snapshot.sharedHealthSummaries.first)
        let realSnapshot = model.snapshot
        model.startDemo()
        #expect(!model.healthSharingEnabled)
        #expect(model.healthReport == nil)
        #expect(!(await model.setHealthSharing(true)))
        model.exitDemo()
        #expect(model.snapshot == realSnapshot)
        #expect(!model.healthSharingEnabled)
        #expect(await model.clearAllData())
        #expect(model.snapshot.sharedHealthSummaries.isEmpty)
        #expect(model.snapshot.deletions.contains { $0.entity == .healthSummary && $0.entityID == shared.id.uuidString })
        let reloaded = try await SnapshotFileStore(url: model.storageURL).load()
        #expect(reloaded == model.snapshot)
    }

    @Test @MainActor func failedPublicationDoesNotClaimConsentOrSave() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.load()
        await model.connectHealth()
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        try Data("directory deliberately unavailable".utf8).write(to: model.storageURL.deletingLastPathComponent())
        #expect(!(await model.setHealthSharing(true)))
        #expect(!model.healthSharingEnabled)
        #expect(model.snapshot.sharedHealthSummaries.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test @MainActor func unsupportedReaderCanDisplayReceivedSummaryWithoutHealthQuery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        fixture.client.isAvailable = false
        await model.load()
        let summary = try SharedHealthSummary(sourceIdentifier: "phone-source", sourceDescription: "Explicit fixture from another device",
            recovery: Fixture.report(hrv: 46).recovery)
        try await model.replaceSnapshot(AppSnapshot(sharedHealthSummaries: [summary]))
        #expect(model.latestSharedHealthSummary == summary)
        #expect(!model.isOwnSharedHealthSummary(summary))
        #expect(!(await model.setHealthSharing(true)))
        #expect(fixture.client.authorizationRequests == 0)
        #expect(fixture.client.reads == 0)
    }
}

@MainActor
private struct Fixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "MyEnergy.HealthSharingUITests.\(UUID().uuidString)"
    let preferences: UserDefaults
    let client: FixtureHealthClient
    let model: AppModel

    init() throws {
        preferences = try #require(UserDefaults(suiteName: suite))
        client = FixtureHealthClient(report: Self.report())
        model = AppModel(storageURL: folder.appendingPathComponent("account-one/records.json"), healthClient: client, preferences: preferences)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: folder)
        preferences.removePersistentDomain(forName: suite)
    }

    static func report(hrv: Double = 42, date: Date = Date()) -> HealthReport {
        HealthReport(recovery: RecoverySummary(status: .insufficientHistory, latestMS: hrv, sampledAt: date),
            restingHeartRate: 61, sleepHours: 7.2, updatedAt: date, sourceDescription: "Explicit unit-test fixture; not HealthKit data")
    }
}

@MainActor
private final class FixtureHealthClient: AppHealthClient {
    var isAvailable = true
    var report: HealthReport
    var authorizationRequests = 0
    var reads = 0
    init(report: HealthReport) { self.report = report }
    func requestReadAccess() async throws { authorizationRequests += 1 }
    func fetchReport(now: Date) async throws -> HealthReport { reads += 1; return report }
}

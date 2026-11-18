import Foundation
import MyEnergyCore
import MyEnergyPlatform
@testable import MyEnergyUI
import Testing

@Suite("Sleep observation application behavior", .serialized)
struct SleepObservationUITests {
    private func time(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test @MainActor func manualSleepPersistsEditsAndDeletionCannotBeResurrected() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("records.json")
        let model = AppModel(storageURL: url)
        await model.load()
        let end = Date().addingTimeInterval(-3_600)
        #expect(await model.saveSleep(bedtime: end.addingTimeInterval(-7 * 3_600), wakeTime: end, note: "Self-report fixture"))
        let first = try #require(model.visibleSleepRecords.first)
        #expect(first.durationHours == 7)
        let next = AppModel(storageURL: url)
        await next.load()
        #expect(next.visibleSleepRecords == [first])
        #expect(await next.saveSleep(id: first.id, bedtime: end.addingTimeInterval(-8 * 3_600), wakeTime: end, note: "Updated fixture"))
        let updated = try #require(next.visibleSleepRecords.first)
        #expect(updated.durationHours == 8)
        #expect(await next.deleteSleep(updated))
        #expect(next.visibleSleepRecords.isEmpty)
        #expect(next.snapshot.deletions.contains { $0.entity == .sleep && $0.entityID == first.id.uuidString })
        #expect(!(await next.saveSleep(id: first.id, bedtime: first.bedtime, wakeTime: first.wakeTime)))
        #expect(!(await next.saveSleep(bedtime: Date(), wakeTime: Date().addingTimeInterval(3600))))
        #expect(next.visibleSleepRecords.isEmpty)
    }

    @Test func observationsChooseOneSourceAndLeaveMissingDaysAbsent() throws {
        let now = try time("2026-11-18T12:00:00Z")
        let start = try time("2026-11-17T22:00:00Z")
        let end = try time("2026-11-18T07:00:00Z")
        let manual = try SleepRecord(bedtime: end.addingTimeInterval(-7 * 3600), wakeTime: end, timeZoneIdentifier: "UTC")
        let health = try SleepNight(bedtime: start, wakeTime: end, asleepSeconds: 8 * 3600,
            timeZoneIdentifier: "UTC", sourceDescription: "Fixture")
        let nap = try SleepNight(bedtime: end.addingTimeInterval(3600), wakeTime: end.addingTimeInterval(7200),
            asleepSeconds: 3600, timeZoneIdentifier: "UTC", sourceDescription: "Fixture")
        let sharedNight = try SleepNight(bedtime: start, wakeTime: end, asleepSeconds: 9 * 3600,
            timeZoneIdentifier: "UTC", sourceDescription: "Other fixture")
        let shared = try SharedHealthSummary(sourceIdentifier: "other", sourceDescription: "Shared fixture",
            recovery: RecoveryAnalyzer.analyze(samples: [], now: now), updatedAt: now, sleepNight: sharedNight)
        let local = SleepObservationBuilder.build(manual: [manual], health: [nap, health], shared: [shared],
            days: 7, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(local.count == 1)
        #expect(local[0].dayKey == "2026-11-18")
        #expect(local[0].durationHours == 8)
        #expect(!local[0].isEstimated)
        let received = SleepObservationBuilder.build(manual: [manual], health: [], shared: [shared],
            days: 30, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(received.count == 1)
        #expect(received[0].durationHours == 9)
        let own = SleepObservationBuilder.build(manual: [manual], health: [], shared: [], days: 7,
            now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(own[0].durationHours == 7)
        #expect(own[0].isEstimated)
        #expect(SleepObservationBuilder.build(manual: [manual], health: [], shared: [], days: 0, now: now).isEmpty)
    }

    @Test @MainActor func demoSleepNeverOverwritesRealSleepAndClearCreatesTombstones() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("records.json")
        let model = AppModel(storageURL: url)
        await model.load()
        let end = Date().addingTimeInterval(-3600)
        #expect(await model.saveSleep(bedtime: end.addingTimeInterval(-6 * 3600), wakeTime: end))
        let real = model.snapshot
        model.startDemo()
        #expect(model.isDemo)
        #expect(!model.visibleSleepRecords.isEmpty)
        #expect(try await SnapshotFileStore(url: url).load() == real)
        model.exitDemo()
        #expect(model.snapshot == real)
        #expect(await model.clearAllData())
        #expect(model.snapshot.sleepRecords.isEmpty)
        #expect(model.snapshot.deletions.contains { $0.entity == .sleep })
    }

    @Test func completedSleepInAnotherZoneRemainsVisibleBeforeViewerMidnight() throws {
        let now = try time("2026-11-18T00:30:00Z")
        let record = try SleepRecord(bedtime: time("2026-11-17T15:30:00Z"), wakeTime: time("2026-11-17T23:30:00Z"),
            timeZoneIdentifier: "Asia/Shanghai")
        let viewerZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let observed = SleepObservationBuilder.build(manual: [record], health: [], shared: [],
            days: 7, now: now, timeZone: viewerZone)
        #expect(observed.count == 1)
        #expect(observed.first?.dayKey == "2026-11-17")
        #expect(observed.first?.timeZoneIdentifier == "Asia/Shanghai")
        #expect(observed.first?.durationHours == 8)
    }

    @Test @MainActor func localSleepHistoryRemainsLocalAndSharingSelectsOnlyLatestMainObservation() async throws {
        let folder = directory()
        let suite = "MyEnergy.SleepFixtures.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); preferences.removePersistentDomain(forName: suite) }
        let now = try time("2026-11-18T12:00:00Z")
        let first = try SleepNight(bedtime: time("2026-11-16T23:00:00Z"), wakeTime: time("2026-11-17T07:00:00Z"),
            asleepSeconds: 8 * 3600, timeZoneIdentifier: "UTC", sourceDescription: "Health fixture")
        let latest = try SleepNight(bedtime: time("2026-11-17T23:00:00Z"), wakeTime: time("2026-11-18T07:00:00Z"),
            asleepSeconds: 7 * 3600, timeZoneIdentifier: "UTC", sourceDescription: "Health fixture")
        let nap = try SleepNight(bedtime: time("2026-11-18T09:00:00Z"), wakeTime: time("2026-11-18T10:00:00Z"),
            asleepSeconds: 3600, timeZoneIdentifier: "UTC", sourceDescription: "Health fixture")
        let fake = SleepHealthClient(report: HealthReport(recovery: RecoveryAnalyzer.analyze(samples: [], now: now),
            sleepHours: 1, updatedAt: now, sourceDescription: "Health fixture", sleepHistory: [first, latest, nap]))
        let url = folder.appendingPathComponent("records.json")
        let model = AppModel(storageURL: url, healthClient: fake, preferences: preferences)
        await model.load()
        await model.connectHealth()
        #expect(!model.healthSharingEnabled)
        #expect(model.snapshot.sharedHealthSummaries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await model.setHealthSharing(true))
        let shared = try #require(model.snapshot.sharedHealthSummaries.first)
        #expect(shared.sleepNight == latest)
        #expect(shared.sleepHours == 7)
        let bytes = try Data(contentsOf: url)
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.contains("sleepHistory"))
        #expect(try await SnapshotFileStore(url: url).load().sharedHealthSummaries.count == 1)
    }
}

@MainActor private final class SleepHealthClient: AppHealthClient {
    let isAvailable = true
    let report: HealthReport
    init(report: HealthReport) { self.report = report }
    func requestReadAccess() async throws {}
    func fetchReport(now: Date) async throws -> HealthReport { report }
}

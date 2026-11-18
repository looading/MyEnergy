import Foundation
import XCTest
@testable import MyEnergyCore

final class CoreSleepTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_795_000_000)

  private func record(id: UUID = UUID(), note: String = "") throws -> SleepRecord {
    try SleepRecord(id: id, bedtime: start, wakeTime: start.addingTimeInterval(8 * 3_600),
                    timeZoneIdentifier: "Asia/Shanghai", note: note, modifiedAt: start)
  }

  private func night() throws -> SleepNight {
    try SleepNight(bedtime: start, wakeTime: start.addingTimeInterval(8 * 3_600), asleepSeconds: 7 * 3_600,
                   timeZoneIdentifier: "Asia/Shanghai", sourceDescription: "Apple 健康")
  }

  func testRecordsValidateElapsedDurationDatesTimeZoneAndGraphemeLimits() throws {
    XCTAssertEqual(try record().durationHours, 8)
    let fullDay = try SleepRecord(bedtime: start, wakeTime: start.addingTimeInterval(24 * 3_600))
    XCTAssertEqual(fullDay.durationHours, 24)
    for end in [start, start.addingTimeInterval(-1), start.addingTimeInterval(24 * 3_600 + 1)] {
      XCTAssertThrowsError(try SleepRecord(bedtime: start, wakeTime: end))
    }
    let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
    XCTAssertThrowsError(try SleepRecord(bedtime: invalid, wakeTime: start))
    XCTAssertThrowsError(try SleepRecord(bedtime: start, wakeTime: invalid))
    XCTAssertThrowsError(try SleepRecord(bedtime: start, wakeTime: start.addingTimeInterval(1), modifiedAt: invalid))
    XCTAssertThrowsError(try SleepRecord(bedtime: start, wakeTime: start.addingTimeInterval(1),
                                        timeZoneIdentifier: "Never/Exists"))
    let family = "👩‍👩‍👧‍👦"
    XCTAssertEqual(try record(note: String(repeating: family, count: 500)).note.count, 500)
    XCTAssertThrowsError(try record(note: String(repeating: family, count: 501)))
  }

  func testNightValidatesActualSleepWithoutCountingEntireBoundary() throws {
    XCTAssertEqual(try night().durationHours, 7)
    let invalidSeconds: [Double] = [0, -1, .nan, .infinity, 8 * 3_600 + 1]
    for seconds in invalidSeconds {
      XCTAssertThrowsError(try SleepNight(bedtime: start, wakeTime: start.addingTimeInterval(8 * 3_600),
                                         asleepSeconds: seconds, sourceDescription: "Apple 健康"))
    }
    XCTAssertThrowsError(try SleepNight(bedtime: start, wakeTime: start, asleepSeconds: 1, sourceDescription: "来源"))
    XCTAssertThrowsError(try SleepNight(bedtime: start, wakeTime: start.addingTimeInterval(25 * 3_600),
                                       asleepSeconds: 3_600, sourceDescription: "来源"))
    XCTAssertThrowsError(try SleepNight(bedtime: start, wakeTime: start.addingTimeInterval(3_600),
                                       asleepSeconds: 3_600, timeZoneIdentifier: "Never/Exists", sourceDescription: "来源"))
  }

  func testNightIdentityAndWakeDateUseRecordedTimeZone() throws {
    let formatter = ISO8601DateFormatter()
    let bedtime = try XCTUnwrap(formatter.date(from: "2026-11-17T16:30:00Z"))
    let wakeTime = try XCTUnwrap(formatter.date(from: "2026-11-18T00:30:00Z"))
    let utc = try SleepNight(bedtime: bedtime, wakeTime: wakeTime, asleepSeconds: 8 * 3_600,
                            timeZoneIdentifier: "GMT", sourceDescription: "Apple 健康")
    let california = try SleepNight(bedtime: bedtime, wakeTime: wakeTime, asleepSeconds: 8 * 3_600,
                                   timeZoneIdentifier: "America/Los_Angeles", sourceDescription: "Apple 健康")
    XCTAssertEqual(utc.dayKey, "2026-11-18")
    XCTAssertEqual(california.dayKey, "2026-11-17")
    XCTAssertNotEqual(utc.id, california.id)
    let differentSource = try SleepNight(bedtime: bedtime, wakeTime: wakeTime, asleepSeconds: 7 * 3_600,
                                        timeZoneIdentifier: "GMT", sourceDescription: "另一来源")
    XCTAssertEqual(utc.id, differentSource.id)
    XCTAssertEqual(try JSONDecoder().decode(SleepNight.self, from: JSONEncoder().encode(utc)), utc)
  }

  func testSchemaOneAndLegacySharedScalarDecodeWithoutInventingSleepHistory() throws {
    let legacy = Data(#"{"schemaVersion":1,"entries":[],"habits":[],"checkIns":[],"deletions":[]}"#.utf8)
    XCTAssertTrue(try JSONDecoder().decode(AppSnapshot.self, from: legacy).sleepRecords.isEmpty)
    let summary = try SharedHealthSummary(sourceIdentifier: "device", sourceDescription: "我的 iPhone",
                                         recovery: RecoverySummary(status: .unavailable), sleepHours: 8, updatedAt: start)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
    json.removeValue(forKey: "sleepNight")
    let restored = try JSONDecoder().decode(SharedHealthSummary.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(restored.sleepHours, 8)
    XCTAssertNil(restored.sleepNight)
    let shared = try SharedHealthSummary(sourceIdentifier: "device", sourceDescription: "我的 iPhone",
                                        recovery: RecoverySummary(status: .unavailable), sleepHours: 7, updatedAt: start,
                                        sleepNight: night())
    let snapshot = try AppSnapshot(sharedHealthSummaries: [shared], sleepRecords: [record()]).validated()
    XCTAssertEqual(try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
  }

  func testSnapshotsAndDecodedRecordsRejectInvalidSleep() throws {
    let valid = try record()
    XCTAssertThrowsError(try AppSnapshot(sleepRecords: [valid, valid]).validated())
    var changed = valid
    changed.wakeTime = start
    XCTAssertThrowsError(try AppSnapshot(sleepRecords: [changed]).validated())
    var recordJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
    recordJSON["note"] = String(repeating: "x", count: 501)
    XCTAssertThrowsError(try JSONDecoder().decode(SleepRecord.self, from: JSONSerialization.data(withJSONObject: recordJSON)))
    var nightJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(night())) as? [String: Any])
    nightJSON["asleepSeconds"] = 9 * 3_600
    XCTAssertThrowsError(try JSONDecoder().decode(SleepNight.self, from: JSONSerialization.data(withJSONObject: nightJSON)))
    XCTAssertThrowsError(try AppSnapshot(deletions: [DeletionRecord(entity: .sleep, entityID: "invalid")]).validated())
  }

  func testIndependentSleepEditsAndAdditionsMergeAndConflictsRespectResolution() throws {
    let original = try record()
    let base = AppSnapshot(sleepRecords: [original])
    var local = base
    local.sleepRecords[0].note = "本机备注"
    let entry = try EnergyEntry(energy: 70)
    local.entries = [entry]
    var remote = base
    let added = try record()
    remote.sleepRecords.append(added)
    let independent = SnapshotMerger.merge(base: base, local: local, remote: remote)
    XCTAssertTrue(independent.conflicts.isEmpty)
    XCTAssertEqual(independent.snapshot.sleepRecords.first(where: { $0.id == original.id })?.note, "本机备注")
    XCTAssertTrue(independent.snapshot.sleepRecords.contains(added))
    remote.sleepRecords[0].note = "远端备注"
    let conflict = SnapshotMerger.merge(base: base, local: local, remote: remote)
    XCTAssertEqual(conflict.conflicts, [MergeConflict(entity: .sleep, entityID: original.id.uuidString)])
    let resolved = SnapshotMerger.resolve(base: base, local: local, remote: remote, favoring: .remote)
    XCTAssertEqual(resolved.sleepRecords.first(where: { $0.id == original.id })?.note, "远端备注")
    XCTAssertTrue(resolved.sleepRecords.contains(added))
    XCTAssertEqual(resolved.entries, [entry])
    XCTAssertEqual(resolved.sleepRecords.map(\.id.uuidString), resolved.sleepRecords.map(\.id.uuidString).sorted())
  }

  func testSleepTombstonesBeatOfflineEditsAndCannotResurrect() throws {
    let original = try record()
    let base = AppSnapshot(sleepRecords: [original])
    let deletion = DeletionRecord(entity: .sleep, entityID: original.id.uuidString.lowercased(), deletedAt: start)
    XCTAssertEqual(deletion.entityID, original.id.uuidString)
    let local = AppSnapshot(deletions: [deletion])
    var offline = base
    offline.sleepRecords[0].note = "离线修改"
    let merged = SnapshotMerger.merge(base: base, local: local, remote: offline)
    XCTAssertTrue(merged.snapshot.sleepRecords.isEmpty)
    XCTAssertTrue(merged.conflicts.isEmpty)
    XCTAssertEqual(merged.snapshot.deletions, [deletion])
    let retried = SnapshotMerger.resolve(base: merged.snapshot, local: offline, remote: AppSnapshot(), favoring: .local)
    XCTAssertTrue(retried.sleepRecords.isEmpty)
    XCTAssertEqual(retried.deletions, [deletion])
  }
}

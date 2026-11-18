import Foundation
import Testing
@testable import MyEnergyCore

@Suite("Time zone boundaries and durable snapshots")
struct CoreDateAndStorageTests {
  @Test func explicitZonesDoNotReassignExistingCheckIns() throws {
    let date = Date(timeIntervalSince1970: 1_710_054_000) // 2024-03-10 07:00 UTC
    let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    #expect(DateRules.dayKey(for: date, timeZone: losAngeles) == "2024-03-09")
    #expect(DateRules.dayKey(for: date, timeZone: tokyo) == "2024-03-10")
    let checkIn = try HabitCheckIn(habitID: UUID(), dayKey: DateRules.dayKey(for: date, timeZone: losAngeles), isComplete: true)
    let decoded = try JSONDecoder().decode(HabitCheckIn.self, from: JSONEncoder().encode(checkIn))
    #expect(decoded.dayKey == "2024-03-09")
  }

  @Test func recentDaysUsesCalendarDaysAcrossDaylightSaving() throws {
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let date = Date(timeIntervalSince1970: 1_710_244_800) // 2024-03-12 12:00 UTC
    let days = DateRules.recentDays(count: 4, endingAt: date, timeZone: zone)
    #expect(days.map { DateRules.dayKey(for: $0, timeZone: zone) } == ["2024-03-09", "2024-03-10", "2024-03-11", "2024-03-12"])
    try #require(days.count == 4)
    #expect(days[2].timeIntervalSince(days[1]) == 23 * 3_600)
    #expect(DateRules.recentDays(count: 0, endingAt: date, timeZone: zone).isEmpty)
    #expect(DateRules.recentDays(count: -1, endingAt: date, timeZone: zone).isEmpty)
  }

  @Test func storeRoundTripsAndLeavesCorruptBytesUntouched() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyEnergyCore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snapshot.json")
    let store = SnapshotFileStore(url: url)
    #expect(try await store.load() == AppSnapshot())
    let snapshot = AppSnapshot(entries: [try EnergyEntry(energy: 73, note: "下午散步后")])
    try await store.save(snapshot)
    #expect(try await store.load() == snapshot)
    let replacement = AppSnapshot(entries: [try EnergyEntry(energy: 42)])
    try await store.save(replacement)
    #expect(try await store.load() == replacement)
    let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(excluded.isExcludedFromBackup == true)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let corrupt = Data("{corrupt bytes".utf8)
    try corrupt.write(to: url)
    await #expect(throws: (any Error).self) { try await store.load() }
    #expect(try Data(contentsOf: url) == corrupt)
    try await store.delete()
    #expect(try await store.load() == AppSnapshot())
    try await store.delete()
  }

  @Test func invalidSaveNeverReplacesExistingFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyEnergyCore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snapshot.json")
    let store = SnapshotFileStore(url: url)
    let valid = AppSnapshot(entries: [try EnergyEntry(energy: 33)])
    try await store.save(valid)
    let original = try Data(contentsOf: url)
    var invalid = valid
    invalid.entries[0].energy = 200
    await #expect(throws: (any Error).self) { try await store.save(invalid) }
    #expect(try Data(contentsOf: url) == original)
    let unknownSchema = try JSONEncoder().encode(AppSnapshot(schemaVersion: 8))
    try unknownSchema.write(to: url)
    await #expect(throws: (any Error).self) { try await store.load() }
    #expect(try Data(contentsOf: url) == unknownSchema)
  }
}

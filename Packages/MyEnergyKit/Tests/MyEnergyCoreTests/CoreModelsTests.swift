import Foundation
import Testing
@testable import MyEnergyCore

@Suite("Validated personal records")
struct CoreModelsTests {
  @Test func energyBoundsAndGraphemeLimits() throws {
    #expect(try EnergyEntry(energy: 0).energy == 0)
    #expect(try EnergyEntry(energy: 100).energy == 100)
    #expect(throws: (any Error).self) { try EnergyEntry(energy: -1) }
    #expect(throws: (any Error).self) { try EnergyEntry(energy: 101) }
    let family = "👩‍👩‍👧‍👦"
    #expect(try EnergyEntry(energy: 50, note: String(repeating: family, count: 500)).note.count == 500)
    #expect(throws: (any Error).self) { try EnergyEntry(energy: 50, note: String(repeating: "a", count: 501)) }
    #expect(try HabitDefinition(title: "  散步\n").title == "散步")
    #expect(try HabitDefinition(title: String(repeating: "走", count: 40)).title.count == 40)
    #expect(throws: (any Error).self) { try HabitDefinition(title: " \n ") }
    #expect(throws: (any Error).self) { try HabitDefinition(title: String(repeating: "走", count: 41)) }
  }

  @Test func decodedRecordsCannotBypassValidation() throws {
    let entry = try EnergyEntry(energy: 50)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    json["energy"] = 101
    let invalidEntry = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(EnergyEntry.self, from: invalidEntry) }
    json["energy"] = 50
    json["timeZoneIdentifier"] = "Never/Exists"
    let invalidZone = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(EnergyEntry.self, from: invalidZone) }
    let habit = try HabitDefinition(title: "运动")
    var habitJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(habit)) as? [String: Any])
    habitJSON["title"] = "  "
    let invalidHabit = try JSONSerialization.data(withJSONObject: habitJSON)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(HabitDefinition.self, from: invalidHabit) }
  }

  @Test func snapshotRejectsUnknownSchemaDuplicatesAndMutatedInvalidFields() throws {
    let entry = try EnergyEntry(energy: 50)
    let habit = try HabitDefinition(title: "午后散步")
    let checkIn = try HabitCheckIn(habitID: habit.id, dayKey: "2024-02-29", isComplete: true)
    #expect(throws: (any Error).self) { try AppSnapshot(schemaVersion: 2).validated() }
    #expect(throws: (any Error).self) { try AppSnapshot(entries: [entry, entry]).validated() }
    #expect(throws: (any Error).self) { try AppSnapshot(habits: [habit, habit]).validated() }
    #expect(throws: (any Error).self) { try AppSnapshot(checkIns: [checkIn, checkIn]).validated() }
    let deletion = DeletionRecord(entity: .entry, entityID: entry.id.uuidString)
    #expect(throws: (any Error).self) { try AppSnapshot(deletions: [deletion, deletion]).validated() }
    var changed = entry
    changed.note = String(repeating: "x", count: 501)
    #expect(throws: (any Error).self) { try AppSnapshot(entries: [changed]).validated() }
    let bytes = try JSONEncoder().encode(AppSnapshot(schemaVersion: 9))
    #expect(throws: (any Error).self) { try JSONDecoder().decode(AppSnapshot.self, from: bytes) }
    let duplicateBytes = try JSONEncoder().encode(AppSnapshot(entries: [entry, entry]))
    #expect(throws: (any Error).self) { try JSONDecoder().decode(AppSnapshot.self, from: duplicateBytes) }
  }

  @Test func checkInIDsStayStableAndGregorianDatesAreStrict() throws {
    let habitID = UUID()
    let first = try HabitCheckIn(habitID: habitID, dayKey: "2024-02-29", isComplete: true)
    let second = try HabitCheckIn(habitID: habitID, dayKey: "2024-02-29", isComplete: false)
    #expect(first.id == second.id)
    #expect(first.id == "\(habitID.uuidString):2024-02-29")
    for invalid in ["2023-02-29", "2024-02-30", "2024-13-01", "2024-1-01", "0000-01-01", "2024-01-01suffix"] {
      #expect(throws: (any Error).self) { try HabitCheckIn(habitID: habitID, dayKey: invalid, isComplete: true) }
    }
    let tombstone = DeletionRecord(entity: .entry, entityID: habitID.uuidString.lowercased())
    #expect(tombstone.entityID == habitID.uuidString)
    #expect(throws: (any Error).self) {
      try AppSnapshot(deletions: [DeletionRecord(entity: .habit, entityID: "invalid")]).validated()
    }
  }

  @Test func modelsRejectNonfiniteDates() throws {
    let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
    #expect(throws: (any Error).self) { try EnergyEntry(energy: 25, occurredAt: invalid) }
    #expect(throws: (any Error).self) { try HabitDefinition(title: "散步", modifiedAt: invalid) }
    #expect(throws: (any Error).self) {
      try AppSnapshot(deletions: [DeletionRecord(entity: .entry, entityID: UUID().uuidString, deletedAt: invalid)]).validated()
    }
  }
}

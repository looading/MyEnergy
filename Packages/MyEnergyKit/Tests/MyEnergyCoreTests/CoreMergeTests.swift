import Foundation
import Testing
@testable import MyEnergyCore

@Suite("Three way snapshot convergence")
struct CoreMergeTests {
  @Test func independentEditsAndAddsSurviveWithoutTimestampWinners() throws {
    let old = Date(timeIntervalSince1970: 1_000)
    let entry = try EnergyEntry(energy: 40, occurredAt: old)
    let habit = try HabitDefinition(title: "散步", createdAt: old)
    let base = AppSnapshot(entries: [entry], habits: [habit])
    var local = base
    local.entries[0].energy = 70
    local.entries[0].modifiedAt = old.addingTimeInterval(-100)
    var remote = base
    remote.habits[0].title = "读书"
    let added = try EnergyEntry(energy: 90, occurredAt: old)
    remote.entries.append(added)
    let result = SnapshotMerger.merge(base: base, local: local, remote: remote)
    #expect(result.conflicts.isEmpty)
    #expect(result.snapshot.entries.first(where: { $0.id == entry.id })?.energy == 70)
    #expect(result.snapshot.entries.contains(added))
    #expect(result.snapshot.habits.first?.title == "读书")
    #expect(result.snapshot.entries.map(\.id.uuidString) == result.snapshot.entries.map(\.id.uuidString).sorted())
  }

  @Test func resolutionOnlySelectsConflictingEntity() throws {
    let entry = try EnergyEntry(energy: 50)
    let unrelated = try HabitDefinition(title: "拉伸")
    let base = AppSnapshot(entries: [entry], habits: [unrelated])
    var local = base
    local.entries[0].energy = 20
    local.entries[0].modifiedAt = Date(timeIntervalSince1970: 9_999)
    local.habits[0].title = "慢跑"
    var remote = base
    remote.entries[0].energy = 80
    remote.entries[0].modifiedAt = Date(timeIntervalSince1970: 1)
    let remoteAddition = try EnergyEntry(energy: 75)
    remote.entries.append(remoteAddition)
    let result = SnapshotMerger.merge(base: base, local: local, remote: remote)
    #expect(result.conflicts.count == 1)
    #expect(result.conflicts.first?.entity == .entry)
    #expect(result.snapshot.entries.first(where: { $0.id == entry.id })?.energy == 20)
    let resolved = SnapshotMerger.resolve(base: base, local: local, remote: remote, favoring: .remote)
    #expect(resolved.entries.first(where: { $0.id == entry.id })?.energy == 80)
    #expect(resolved.habits.first?.title == "慢跑")
    #expect(resolved.entries.contains(remoteAddition))
  }

  @Test func identicalConcurrentChangesAreNotConflicts() throws {
    let entry = try EnergyEntry(energy: 50)
    let base = AppSnapshot(entries: [entry])
    var changed = base
    changed.entries[0].energy = 62
    let result = SnapshotMerger.merge(base: base, local: changed, remote: changed)
    #expect(result.conflicts.isEmpty)
    #expect(result.snapshot.entries == changed.entries)
  }

  @Test func tombstonesBeatEditsAndCannotBeLostOrResurrected() throws {
    let entry = try EnergyEntry(energy: 30)
    let base = AppSnapshot(entries: [entry])
    let deletion = DeletionRecord(entity: .entry, entityID: entry.id.uuidString.lowercased(), deletedAt: Date(timeIntervalSince1970: 100))
    let local = AppSnapshot(deletions: [deletion])
    var remote = base
    remote.entries[0].energy = 99
    let result = SnapshotMerger.merge(base: base, local: local, remote: remote)
    #expect(result.snapshot.entries.isEmpty)
    #expect(result.conflicts.isEmpty)
    #expect(result.snapshot.deletions == [deletion])
    let resurrectAttempt = SnapshotMerger.resolve(base: result.snapshot, local: remote, remote: AppSnapshot(), favoring: .local)
    #expect(resurrectAttempt.entries.isEmpty)
    #expect(resurrectAttempt.deletions == [deletion])
  }

  @Test func habitDeletionClearsCheckInsAndSuppressesIrrelevantConflicts() throws {
    let habit = try HabitDefinition(title: "喝水")
    let checkIn = try HabitCheckIn(habitID: habit.id, dayKey: "2026-11-18", isComplete: true)
    let base = AppSnapshot(habits: [habit], checkIns: [checkIn])
    let deletedAt = Date(timeIntervalSince1970: 200)
    let local = AppSnapshot(deletions: [DeletionRecord(entity: .habit, entityID: habit.id.uuidString, deletedAt: deletedAt)])
    var remote = base
    remote.habits[0].title = "补水"
    remote.checkIns[0].isComplete = false
    let result = SnapshotMerger.merge(base: base, local: local, remote: remote)
    #expect(result.snapshot.habits.isEmpty)
    #expect(result.snapshot.checkIns.isEmpty)
    #expect(result.conflicts.isEmpty)
    let resolved = SnapshotMerger.resolve(base: base, local: local, remote: remote, favoring: .remote)
    #expect(resolved.habits.isEmpty)
    #expect(resolved.checkIns.isEmpty)
  }

  @Test func checkInTombstoneAndImplicitDeletionAreHandledByIdentity() throws {
    let habit = try HabitDefinition(title: "午休")
    let first = try HabitCheckIn(habitID: habit.id, dayKey: "2026-11-17", isComplete: true)
    let second = try HabitCheckIn(habitID: habit.id, dayKey: "2026-11-18", isComplete: true)
    let base = AppSnapshot(habits: [habit], checkIns: [first])
    let local = AppSnapshot(habits: [habit], deletions: [DeletionRecord(entity: .checkIn, entityID: first.id.lowercased())])
    let remote = AppSnapshot(habits: [habit], checkIns: [first, second])
    let result = SnapshotMerger.merge(base: base, local: local, remote: remote)
    #expect(result.snapshot.checkIns == [second])
    let implicit = SnapshotMerger.merge(base: base, local: AppSnapshot(), remote: base)
    #expect(implicit.snapshot.habits.isEmpty)
    #expect(implicit.snapshot.checkIns.isEmpty)
  }
}

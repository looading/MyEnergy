import Foundation
import Testing
@testable import MyEnergyCore

@Suite("Explicitly shared health summaries")
struct CoreSharedHealthTests {
  private let date = Date(timeIntervalSince1970: 1_795_000_000)

  private func summary(id: UUID = UUID(), restingHeartRate: Double? = 60, sleepHours: Double? = 8) throws -> SharedHealthSummary {
    try SharedHealthSummary(id: id, sourceIdentifier: "device-one", sourceDescription: "我的 iPhone",
                            recovery: RecoverySummary(status: .insufficientHistory, latestMS: 45, sampledAt: date, historyDays: 2),
                            restingHeartRate: restingHeartRate, sleepHours: sleepHours, updatedAt: date)
  }

  @Test func snapshotsStartWithoutSharedHealthAndDecodeOlderSchemaOne() throws {
    #expect(AppSnapshot().sharedHealthSummaries.isEmpty)
    let oldJSON = Data(#"{"schemaVersion":1,"entries":[],"habits":[],"checkIns":[],"deletions":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(AppSnapshot.self, from: oldJSON)
    #expect(decoded.sharedHealthSummaries.isEmpty)
    let shared = try summary()
    let snapshot = AppSnapshot(sharedHealthSummaries: [shared])
    #expect(try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
  }

  @Test func summariesValidatePhysiologicalBoundariesAndSourceLengths() throws {
    #expect(try summary(restingHeartRate: 1, sleepHours: 0).sleepHours == 0)
    #expect(try summary(restingHeartRate: nil, sleepHours: 24).sleepHours == 24)
    for invalid in [0, -1, Double.infinity, Double.nan] {
      #expect(throws: (any Error).self) { try summary(restingHeartRate: invalid) }
    }
    for invalid in [-0.01, 24.01, Double.infinity, Double.nan] {
      #expect(throws: (any Error).self) { try summary(sleepHours: invalid) }
    }
    #expect(throws: (any Error).self) {
      try SharedHealthSummary(sourceIdentifier: String(repeating: "x", count: 129), sourceDescription: "iPhone",
                              recovery: RecoverySummary(status: .unavailable))
    }
    #expect(throws: (any Error).self) {
      try SharedHealthSummary(sourceIdentifier: "device", sourceDescription: String(repeating: "x", count: 201),
                              recovery: RecoverySummary(status: .unavailable))
    }
    #expect(throws: (any Error).self) {
      try SharedHealthSummary(sourceIdentifier: "device", sourceDescription: "iPhone",
                              recovery: RecoverySummary(status: .unavailable), updatedAt: Date(timeIntervalSinceReferenceDate: .nan))
    }
  }

  @Test func malformedRecoveryAndDecodedSummariesCannotBypassValidation() throws {
    let invalidRecovery = [
      RecoverySummary(status: .ready, latestMS: .infinity, baselineMS: 50, sampledAt: date, historyDays: 7),
      RecoverySummary(status: .ready, latestMS: 50, baselineMS: 0, sampledAt: date, historyDays: 7),
      RecoverySummary(status: .ready, latestMS: 50, baselineMS: 40, changePercent: .nan, sampledAt: date, historyDays: 7),
      RecoverySummary(status: .insufficientHistory, latestMS: 50, sampledAt: date, historyDays: -1),
      RecoverySummary(status: .ready, latestMS: 50, baselineMS: 40, sampledAt: date, historyDays: 6)
    ]
    for recovery in invalidRecovery {
      #expect(throws: (any Error).self) {
        try SharedHealthSummary(sourceIdentifier: "device", sourceDescription: "iPhone", recovery: recovery)
      }
    }
    let valid = try summary()
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
    json["sleepHours"] = 25
    let invalidBytes = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(SharedHealthSummary.self, from: invalidBytes) }
    #expect(throws: (any Error).self) { try AppSnapshot(sharedHealthSummaries: [valid, valid]).validated() }
    var invalidMutation = valid
    invalidMutation.restingHeartRate = -10
    #expect(throws: (any Error).self) { try AppSnapshot(sharedHealthSummaries: [invalidMutation]).validated() }
  }

  @Test func healthSummaryMergePreservesUnrelatedEditsAndResolvesTrueConflicts() throws {
    let shared = try summary()
    let base = AppSnapshot(sharedHealthSummaries: [shared])
    var local = base
    local.sharedHealthSummaries[0].sleepHours = 7
    let entry = try EnergyEntry(energy: 70)
    local.entries.append(entry)
    var remote = base
    remote.sharedHealthSummaries[0].sleepHours = 9
    let remoteAddition = try summary()
    remote.sharedHealthSummaries.append(remoteAddition)
    let result = SnapshotMerger.merge(base: base, local: local, remote: remote)
    #expect(result.conflicts.count == 1)
    #expect(result.conflicts.first?.entity == .healthSummary)
    #expect(result.snapshot.sharedHealthSummaries.first(where: { $0.id == shared.id })?.sleepHours == 7)
    let resolved = SnapshotMerger.resolve(base: base, local: local, remote: remote, favoring: .remote)
    #expect(resolved.sharedHealthSummaries.first(where: { $0.id == shared.id })?.sleepHours == 9)
    #expect(resolved.sharedHealthSummaries.contains(remoteAddition))
    #expect(resolved.entries == [entry])
    #expect(resolved.sharedHealthSummaries.map(\.id.uuidString) == resolved.sharedHealthSummaries.map(\.id.uuidString).sorted())
  }

  @Test func healthTombstonesPreventOfflineResurrection() throws {
    let shared = try summary()
    let base = AppSnapshot(sharedHealthSummaries: [shared])
    let deletion = DeletionRecord(entity: .healthSummary, entityID: shared.id.uuidString.lowercased(), deletedAt: date)
    #expect(deletion.entityID == shared.id.uuidString)
    let local = AppSnapshot(deletions: [deletion])
    var remote = base
    remote.sharedHealthSummaries[0].sleepHours = 6
    let merged = SnapshotMerger.merge(base: base, local: local, remote: remote)
    #expect(merged.conflicts.isEmpty)
    #expect(merged.snapshot.sharedHealthSummaries.isEmpty)
    #expect(merged.snapshot.deletions == [deletion])
    let retry = SnapshotMerger.resolve(base: merged.snapshot, local: remote, remote: AppSnapshot(), favoring: .local)
    #expect(retry.sharedHealthSummaries.isEmpty)
    #expect(retry.deletions == [deletion])
  }
}

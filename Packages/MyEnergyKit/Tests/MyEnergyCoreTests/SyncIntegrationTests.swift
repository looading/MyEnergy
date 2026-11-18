import Foundation
import MyEnergyCore
import MyEnergyPlatform
import Testing

@Suite("Two encrypted clients", .serialized)
struct SyncIntegrationTests {
  private func fixture() async throws -> (AccountClient, AccountSession, Data, URL, SyncService, SyncService) {
    let address = try #require(ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"])
    let url = try #require(URL(string: address))
    let client = try AccountClient(baseURL: url)
    let session = try await client.signInDevelopment(accountName: "t-" + UUID().uuidString)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let key = VaultCrypto.generateKey()
    return (client, session, key, root,
      try SyncService(baseURL: url, session: session, key: key, baselineURL: root.appendingPathComponent("a.json")),
      try SyncService(baseURL: url, session: session, key: key, baselineURL: root.appendingPathComponent("b.json")))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"] != nil))
  func sequentialEditsConflictResolutionAndOfflineDeleteConverge() async throws {
    let (client, session, _, directory, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = AppSnapshot(entries: [try EnergyEntry(energy: 40)])
    let sent = try await a.synchronize(local: original)
    try await a.acknowledgeApplied(sent)
    let received = try await b.synchronize(local: AppSnapshot())
    try await b.acknowledgeApplied(received)
    #expect(received.snapshot == original)
    var b50 = received.snapshot
    b50.entries[0].energy = 50
    let updated = try await b.synchronize(local: b50)
    try await b.acknowledgeApplied(updated)
    let pulled = try await a.synchronize(local: original)
    #expect(pulled.completed)
    #expect(pulled.snapshot.entries.first?.energy == 50)
    try await a.acknowledgeApplied(pulled)
    var a60 = pulled.snapshot; a60.entries[0].energy = 60
    var b70 = updated.snapshot; b70.entries[0].energy = 70
    let first = try await a.synchronize(local: a60)
    try await a.acknowledgeApplied(first)
    let conflict = try await b.synchronize(local: b70)
    #expect(conflict.conflicts.count == 1)
    let selected = try await b.synchronize(local: b70, resolving: .local)
    try await b.acknowledgeApplied(selected)
    #expect(selected.snapshot.entries.first?.energy == 70)
    let second = try await a.synchronize(local: first.snapshot)
    try await a.acknowledgeApplied(second)
    let entry = try #require(second.snapshot.entries.first)
    let deleted = AppSnapshot(deletions: [DeletionRecord(entity: .entry, entityID: entry.id.uuidString)])
    let removed = try await a.synchronize(local: deleted)
    try await a.acknowledgeApplied(removed)
    b70.entries[0].energy = 80
    let afterOffline = try await b.synchronize(local: b70)
    #expect(afterOffline.snapshot.entries.isEmpty)
    #expect(!afterOffline.snapshot.deletions.isEmpty)
    try await client.deleteAccount(session: session)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"] != nil))
  func baselineAdvancesOnlyAfterCallerDurablyApplies() async throws {
    let (client, session, _, directory, a, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let local = AppSnapshot(entries: [try EnergyEntry(energy: 25)])
    let result = try await a.synchronize(local: local)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.json").path))
    try await a.acknowledgeApplied(result)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("a.json").path))
    try await client.deleteAccount(session: session)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["MYENERGY_TEST_SYNC_URL"] != nil))
  func consentedSummaryCrossesEncryptedVaultAndRevocationWinsOfflineCopy() async throws {
    let (client, session, _, directory, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let date = Date()
    let recovery = RecoverySummary(status: .insufficientHistory, latestMS: 42, baselineMS: nil,
      changePercent: nil, sampledAt: date, historyDays: 0)
    let summary = try SharedHealthSummary(sourceIdentifier: "fixture-device", sourceDescription: "Test fixture, not a health measurement",
      recovery: recovery, restingHeartRate: 62, sleepHours: 7.5, updatedAt: date)
    let shared = AppSnapshot(sharedHealthSummaries: [summary])
    let uploaded = try await a.synchronize(local: shared)
    try await a.acknowledgeApplied(uploaded)
    let downloaded = try await b.synchronize(local: AppSnapshot())
    try await b.acknowledgeApplied(downloaded)
    #expect(downloaded.snapshot.sharedHealthSummaries == [summary])
    let removal = AppSnapshot(deletions: [DeletionRecord(entity: .healthSummary, entityID: summary.id.uuidString)])
    let revoked = try await a.synchronize(local: removal)
    try await a.acknowledgeApplied(revoked)
    let afterOffline = try await b.synchronize(local: downloaded.snapshot)
    #expect(afterOffline.snapshot.sharedHealthSummaries.isEmpty)
    #expect(afterOffline.snapshot.deletions.contains { $0.entity == .healthSummary })
    try await client.deleteAccount(session: session)
  }
}

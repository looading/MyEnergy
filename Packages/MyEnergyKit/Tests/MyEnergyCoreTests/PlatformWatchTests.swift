import Foundation
import MyEnergyCore
import XCTest
@testable import MyEnergyPlatform

final class PlatformWatchTests: XCTestCase {
  func testWatchRetryPreservesEventIdentityAndNamespace() throws {
    let base = AppSnapshot(entries: [try EnergyEntry(energy: 40)])
    let event = WatchWireMessage(kind: .snapshot, namespace: "account-A:generation-1",
      snapshot: AppSnapshot(), baseSnapshot: base)
    let first = try WatchWireMessage.decode(event.encoded())
    let retry = try WatchWireMessage.decode(first.encoded())
    XCTAssertEqual(first.eventID, retry.eventID)
    XCTAssertEqual(retry.namespace, "account-A:generation-1")
    XCTAssertEqual(retry.baseSnapshot, base)
    XCTAssertEqual(retry, event)
  }

  func testWatchRejectsFutureProtocolAndOversizedMalformedPayloads() throws {
    let event = WatchWireMessage(kind: .snapshot, namespace: "local-paired", snapshot: AppSnapshot())
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: event.encoded()) as? [String: Any])
    object["version"] = 9
    XCTAssertThrowsError(try WatchWireMessage.decode(JSONSerialization.data(withJSONObject: object)))
    XCTAssertThrowsError(try WatchWireMessage.decode(Data(repeating: 0, count: WatchWireMessage.maxBytes + 1)))
    XCTAssertThrowsError(try WatchWireMessage.decode(Data("{}".utf8)))
  }

  func testWatchRejectsMissingSnapshotAndAckContainingSnapshot() {
    XCTAssertThrowsError(try WatchWireMessage(kind: .snapshot, namespace: "local-paired").encoded())
    XCTAssertThrowsError(try WatchWireMessage(kind: .acknowledgement, namespace: "local-paired",
      snapshot: AppSnapshot()).encoded())
    XCTAssertThrowsError(try WatchWireMessage(kind: .snapshot, namespace: "contains whitespace",
      snapshot: AppSnapshot()).encoded())
    XCTAssertThrowsError(try WatchWireMessage(kind: .acknowledgement, namespace: "local-paired",
      baseSnapshot: AppSnapshot()).encoded())
  }

  func testWireRejectsMissingOrInvalidCausalBaseAndOldProtocol() throws {
    let event = WatchWireMessage(kind: .snapshot, namespace: "local-paired", snapshot: AppSnapshot())
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: event.encoded()) as? [String: Any])
    object.removeValue(forKey: "baseSnapshot")
    XCTAssertThrowsError(try WatchWireMessage.decode(JSONSerialization.data(withJSONObject: object)))
    object["version"] = 1
    XCTAssertThrowsError(try WatchWireMessage.decode(JSONSerialization.data(withJSONObject: object)))
    XCTAssertThrowsError(try WatchWireMessage(kind: .snapshot, namespace: "local-paired",
      snapshot: AppSnapshot(), baseSnapshot: AppSnapshot(schemaVersion: 999)).encoded())
  }

  func testWatchRejectsValidSnapshotThatExceedsConservativeTransportLimit() throws {
    let entries = try (0..<128).map { _ in
      try EnergyEntry(energy: 50, note: String(repeating: "x", count: 500))
    }
    let event = WatchWireMessage(kind: .snapshot, namespace: "local-paired", snapshot: AppSnapshot(entries: entries))
    XCTAssertGreaterThan(try JSONEncoder().encode(event).count, 60 * 1_024)
    XCTAssertThrowsError(try event.encoded())
  }

  func testTransportLimitIncludesBothCausalBaseAndSnapshot() throws {
    let entries = try (0..<64).map { _ in
      try EnergyEntry(energy: 50, note: String(repeating: "x", count: 500))
    }
    let snapshot = AppSnapshot(entries: entries)
    XCTAssertLessThan(try JSONEncoder().encode(snapshot).count, 60 * 1_024)
    let event = WatchWireMessage(kind: .snapshot, namespace: "local-paired", snapshot: snapshot, baseSnapshot: snapshot)
    XCTAssertGreaterThan(try JSONEncoder().encode(event).count, 60 * 1_024)
    XCTAssertThrowsError(try event.encoded())
  }

  func testConsecutiveOfflineEditsChainToPendingPredecessorWithoutFalseConflict() throws {
    let entry = try EnergyEntry(energy: 40)
    let shared = AppSnapshot(entries: [entry])
    var edit50 = entry
    edit50.energy = 50
    let snapshot50 = AppSnapshot(entries: [edit50])
    var edit60 = entry
    edit60.energy = 60
    let snapshot60 = AppSnapshot(entries: [edit60])
    var queue = WatchNamespaceState()
    try queue.enqueueSnapshot(snapshot50, base: shared, namespace: "account-A")
    let originalFirst = try XCTUnwrap(queue.outbox.first)
    try queue.enqueueSnapshot(snapshot60, base: shared, namespace: "account-A")
    XCTAssertEqual(queue.outbox.first, originalFirst)
    XCTAssertEqual(queue.outbox.last?.baseSnapshot, snapshot50)
    XCTAssertEqual(queue.outbox.first?.baseSnapshot, shared)
    var peer = shared
    for event in queue.outbox {
      let message = try WatchWireMessage.decode(event.encoded())
      let result = SnapshotMerger.merge(base: try XCTUnwrap(message.baseSnapshot),
        local: peer, remote: try XCTUnwrap(message.snapshot))
      XCTAssertTrue(result.conflicts.isEmpty)
      peer = result.snapshot
    }
    XCTAssertEqual(peer.entries.first?.energy, 60)
  }

  @MainActor
  func testAcknowledgementCallbackFailureRetainsDurableEventUntilRetrySucceeds() async throws {
    enum Busy: Error { case retry }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = folder.appendingPathComponent("outbox.json")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let base = AppSnapshot(entries: [try EnergyEntry(energy: 40)])
    var changedEntry = try XCTUnwrap(base.entries.first)
    changedEntry.energy = 50
    let changed = AppSnapshot(entries: [changedEntry])
    let event = WatchWireMessage(kind: .snapshot, namespace: "account-A", snapshot: changed, baseSnapshot: base)
    var seed = WatchPersistentState()
    seed.activeNamespace = "account-A"
    seed.spaces["account-A"] = WatchNamespaceState(outbox: [event])
    try JSONEncoder().encode(seed).write(to: file)
    let bridge = WatchBridge(outboxURL: file)
    try bridge.setNamespace("account-A")
    let ack = try WatchWireMessage(kind: .acknowledgement, eventID: event.eventID, namespace: "account-A").encoded()
    bridge.onAcknowledged = { snapshot, causalBase in
      XCTAssertEqual(snapshot, changed)
      XCTAssertEqual(causalBase, base)
      let disk = try JSONDecoder().decode(WatchPersistentState.self, from: Data(contentsOf: file))
      XCTAssertEqual(disk.spaces["account-A"]?.outbox.first?.eventID, event.eventID)
      throw Busy.retry
    }
    do {
      try await bridge.processIncoming(ack)
      XCTFail("a failed baseline save must preserve the event")
    } catch Busy.retry {}
    XCTAssertEqual(bridge.pendingCount, 1)
    let restored = WatchBridge(outboxURL: file)
    try restored.setNamespace("account-A")
    XCTAssertEqual(restored.pendingCount, 1)
    var successfulCallbacks = 0
    restored.onAcknowledged = { snapshot, causalBase in
      XCTAssertEqual(snapshot, changed)
      XCTAssertEqual(causalBase, base)
      successfulCallbacks += 1
    }
    try await restored.processIncoming(ack)
    try await restored.processIncoming(ack)
    XCTAssertEqual(successfulCallbacks, 1)
    XCTAssertEqual(restored.pendingCount, 0)
    let disk = try JSONDecoder().decode(WatchPersistentState.self, from: Data(contentsOf: file))
    XCTAssertEqual(disk.spaces["account-A"]?.outbox.count, 0)
  }

  @MainActor
  func testReceivedCausalBaseAvoidsConflictAfterOriginatedRecordIsEditedByPeer() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = folder.appendingPathComponent("transport.json")
    defer { try? FileManager.default.removeItem(at: folder) }
    let entry = try EnergyEntry(energy: 40)
    let base = AppSnapshot(entries: [entry])
    var edited = entry
    edited.energy = 50
    let remote = AppSnapshot(entries: [edited])
    let bridge = WatchBridge(outboxURL: file)
    var merged: AppSnapshot?
    bridge.onReceive = { _ in XCTFail("the causal receiver should take precedence over the legacy callback") }
    bridge.onReceiveWithBase = { snapshot, causalBase in
      let result = SnapshotMerger.merge(base: causalBase, local: base, remote: snapshot)
      XCTAssertTrue(result.conflicts.isEmpty)
      merged = result.snapshot
    }
    let event = WatchWireMessage(kind: .snapshot, namespace: "local-paired", snapshot: remote, baseSnapshot: base)
    try await bridge.processIncoming(event.encoded())
    XCTAssertEqual(merged?.entries.first?.energy, 50)
  }

  @MainActor
  func testNamespaceDrainSerializesSuspendedCallbackAndCommitsOnlyLatestRequest() async throws {
    let drain = WatchNamespaceDrain()
    let started = AsyncStream<Void>.makeStream()
    var releaseFirst: CheckedContinuation<Void, Never>?
    var changed: [String] = []
    var committed: [String] = []
    drain.enqueue("account-A")
    let worker = Task { @MainActor in
      try await drain.drain(change: { namespace in
        changed.append(namespace)
        if namespace == "account-A" {
          await withCheckedContinuation { continuation in
            releaseFirst = continuation
            started.continuation.yield()
          }
        }
      }, commit: { committed.append($0) })
    }
    for await _ in started.stream { break }
    drain.enqueue("account-B")
    // 重入 drain 不应并行调用模型，后续的 C 取代尚未开始处理的 B。
    try await drain.drain(change: { _ in XCTFail("namespace callbacks must be serialized") }, commit: { _ in })
    drain.enqueue("account-C")
    releaseFirst?.resume()
    try await worker.value
    XCTAssertEqual(changed, ["account-A", "account-C"])
    XCTAssertEqual(committed, ["account-C"])
    XCTAssertFalse(drain.hasPending)
  }

  @MainActor
  func testNamespaceDrainRetainsLatestTargetAfterTemporaryBusyFailure() async throws {
    enum Busy: Error { case retry }
    let drain = WatchNamespaceDrain()
    var committed: [String] = []
    drain.enqueue("account-B")
    do {
      try await drain.drain(change: { _ in throw Busy.retry }, commit: { committed.append($0) })
      XCTFail("temporary busy failure should reach retry owner")
    } catch Busy.retry {}
    XCTAssertTrue(drain.hasPending)
    XCTAssertTrue(committed.isEmpty)
    try await drain.drain(change: { _ in }, commit: { committed.append($0) })
    XCTAssertEqual(committed, ["account-B"])
    XCTAssertFalse(drain.hasPending)
  }

  func testPersistentQueueRejectsCrossAccountReassignmentAndDuplicateIDs() throws {
    let event = WatchWireMessage(kind: .snapshot, namespace: "account-A", snapshot: AppSnapshot())
    var state = WatchPersistentState()
    state.spaces["account-B"] = WatchNamespaceState(outbox: [event])
    XCTAssertThrowsError(try state.validated())
    state.spaces = ["account-A": WatchNamespaceState(outbox: [event, event])]
    XCTAssertThrowsError(try state.validated())
  }

  @MainActor
  func testNamespaceSwitchPersistsIsolationAcrossRestart() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = folder.appendingPathComponent("outbox.json")
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = WatchBridge(outboxURL: file)
    try first.setNamespace("account-A:generation-1")
    try first.setNamespace("account-B:generation-1")
    let restored = WatchBridge(outboxURL: file)
    // setNamespace loads persisted transport state even on macOS, without starting WCSession.
    try restored.setNamespace("account-B:generation-1")
    XCTAssertEqual(restored.activeNamespace, "account-B:generation-1")
    let state = try JSONDecoder().decode(WatchPersistentState.self, from: Data(contentsOf: file))
    XCTAssertNotNil(state.spaces["account-A:generation-1"])
    XCTAssertNotNil(state.spaces["account-B:generation-1"])
  }

  @MainActor
  func testSwitchQuarantinesPendingSnapshotAndRestoresSameEventID() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = folder.appendingPathComponent("outbox.json")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let event = WatchWireMessage(kind: .snapshot, namespace: "account-A:1", snapshot: AppSnapshot())
    var seed = WatchPersistentState()
    seed.activeNamespace = "account-A:1"
    seed.spaces["account-A:1"] = WatchNamespaceState(outbox: [event])
    try JSONEncoder().encode(seed).write(to: file)
    let first = WatchBridge(outboxURL: file)
    try first.setNamespace("account-B:1")
    XCTAssertEqual(first.pendingCount, 0)
    let restored = WatchBridge(outboxURL: file)
    try restored.setNamespace("account-A:1")
    XCTAssertEqual(restored.pendingCount, 1)
    let disk = try JSONDecoder().decode(WatchPersistentState.self, from: Data(contentsOf: file))
    XCTAssertEqual(disk.spaces["account-A:1"]?.outbox.first?.eventID, event.eventID)
    try restored.discardData(in: "account-A:1")
    XCTAssertEqual(restored.pendingCount, 0)
  }

  @MainActor
  func testCorruptQueueIsPreservedInsteadOfDiscarded() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = folder.appendingPathComponent("outbox.json")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let original = Data("corrupt queue bytes".utf8)
    try original.write(to: file)
    let bridge = WatchBridge(outboxURL: file)
    XCTAssertThrowsError(try bridge.setNamespace("account-A"))
    XCTAssertEqual(try Data(contentsOf: file), original)
  }
}

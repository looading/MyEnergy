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
    let event = WatchWireMessage(kind: .snapshot, namespace: "local-paired", snapshot: AppSnapshot())
    var replied = false
    do {
      try await bridge.processIncoming(event.encoded(), inlineAcknowledgement: { _ in replied = true })
      XCTFail("a corrupt transport cannot confirm receipt")
    } catch WatchBridgeError.corruptState {}
    XCTAssertFalse(replied)
    XCTAssertEqual(try Data(contentsOf: file), original)
  }

  @MainActor
  func testInlineAcknowledgementFollowsAppAndTransportPersistenceAndDuplicateOnlyReplies() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("transport.json")
    let appFile = folder.appendingPathComponent("records.json")
    let appStore = SnapshotFileStore(url: appFile)
    let snapshot = AppSnapshot(entries: [try EnergyEntry(energy: 55, note: "Explicit transport fixture")])
    let event = WatchWireMessage(kind: .snapshot, namespace: "local-paired", snapshot: snapshot)
    let bridge = WatchBridge(outboxURL: file)
    var appReceives = 0
    var replies: [WatchWireMessage] = []
    bridge.onReceiveWithBase = { incoming, _ in
      appReceives += 1
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
      try await appStore.save(incoming)
    }
    try await bridge.processIncoming(event.encoded(), inlineAcknowledgement: { data in
      XCTAssertEqual(appReceives, 1)
      XCTAssertEqual(try JSONDecoder().decode(AppSnapshot.self, from: Data(contentsOf: appFile)), snapshot)
      let durable = try JSONDecoder().decode(WatchPersistentState.self, from: Data(contentsOf: file))
      XCTAssertTrue(durable.spaces[event.namespace]?.receivedIDs.contains(event.eventID) == true)
      replies.append(try WatchWireMessage.decode(data))
    })
    let restarted = WatchBridge(outboxURL: file)
    restarted.onReceive = { _ in XCTFail("a durable duplicate must not reapply the app snapshot") }
    try await restarted.processIncoming(event.encoded(), inlineAcknowledgement: { data in
      replies.append(try WatchWireMessage.decode(data))
    })
    XCTAssertEqual(appReceives, 1)
    XCTAssertEqual(replies.count, 2)
    for reply in replies {
      XCTAssertEqual(reply.version, 2)
      XCTAssertEqual(reply.kind, .acknowledgement)
      XCTAssertEqual(reply.eventID, event.eventID)
      XCTAssertEqual(reply.namespace, event.namespace)
      XCTAssertNil(reply.snapshot)
      XCTAssertNil(reply.baseSnapshot)
    }
  }

  @MainActor
  func testInlineReplyFailurePreservesReceivedIdentityForRetryWithoutReapplying() async throws {
    enum ReplyFailure: Error { case disconnected }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("transport.json")
    let bridge = WatchBridge(outboxURL: file)
    let event = WatchWireMessage(kind: .snapshot, namespace: "local-paired", snapshot: AppSnapshot())
    var appReceives = 0
    bridge.onReceive = { _ in appReceives += 1 }
    do {
      try await bridge.processIncoming(event.encoded(), inlineAcknowledgement: { _ in throw ReplyFailure.disconnected })
      XCTFail("the failed direct reply must reach the retry owner")
    } catch ReplyFailure.disconnected {}
    let saved = try JSONDecoder().decode(WatchPersistentState.self, from: Data(contentsOf: file))
    XCTAssertTrue(saved.spaces[event.namespace]?.receivedIDs.contains(event.eventID) == true)
    let restarted = WatchBridge(outboxURL: file)
    restarted.onReceive = { _ in XCTFail("lost reply must not repeat a durable app operation") }
    var repliedEvent: UUID?
    try await restarted.processIncoming(event.encoded(), inlineAcknowledgement: { data in
      repliedEvent = try WatchWireMessage.decode(data).eventID
    })
    XCTAssertEqual(appReceives, 1)
    XCTAssertEqual(repliedEvent, event.eventID)
  }

  @MainActor
  func testRejectedAndNamespaceChangedSnapshotsCannotProduceInlineAcknowledgement() async throws {
    enum AppFailure: Error { case busy }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("transport.json")
    let bridge = WatchBridge(outboxURL: file)
    try bridge.setNamespace("account-A")
    let event = WatchWireMessage(kind: .snapshot, namespace: "account-A", snapshot: AppSnapshot())
    var replies = 0
    bridge.onReceive = { _ in throw AppFailure.busy }
    do {
      try await bridge.processIncoming(event.encoded(), inlineAcknowledgement: { _ in replies += 1 })
      XCTFail("a rejected app write must not be acknowledged")
    } catch AppFailure.busy {}
    let afterFailure = try JSONDecoder().decode(WatchPersistentState.self, from: Data(contentsOf: file))
    XCTAssertFalse(afterFailure.spaces["account-A"]?.receivedIDs.contains(event.eventID) == true)
    bridge.onReceive = { _ in try bridge.setNamespace("account-B") }
    do {
      try await bridge.processIncoming(event.encoded(), inlineAcknowledgement: { _ in replies += 1 })
      XCTFail("a changed namespace must not confirm another account's snapshot")
    } catch WatchBridgeError.namespaceMismatch {}
    let afterSwitch = try JSONDecoder().decode(WatchPersistentState.self, from: Data(contentsOf: file))
    XCTAssertEqual(afterSwitch.activeNamespace, "account-B")
    XCTAssertFalse(afterSwitch.spaces["account-A"]?.receivedIDs.contains(event.eventID) == true)
    XCTAssertEqual(replies, 0)
  }

  @MainActor
  func testFailedTransportPersistenceDoesNotReplyAfterSuccessfulAppCallback() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let transportFolder = folder.appendingPathComponent("transport")
    let bridge = WatchBridge(outboxURL: transportFolder.appendingPathComponent("state.json"))
    let event = WatchWireMessage(kind: .snapshot, namespace: "account-A", snapshot: AppSnapshot())
    try bridge.setNamespace("account-A")
    var appAccepted = false
    var replied = false
    bridge.onReceive = { _ in
      appAccepted = true
      try FileManager.default.removeItem(at: transportFolder)
      try Data("deliberately blocks the transport directory".utf8).write(to: transportFolder)
    }
    do {
      try await bridge.processIncoming(event.encoded(), inlineAcknowledgement: { _ in replied = true })
      XCTFail("an unpersisted received ID must not be acknowledged")
    } catch {}
    XCTAssertTrue(appAccepted)
    XCTAssertFalse(replied)
  }

  @MainActor
  func testReplyAcknowledgementKeepsFIFOIdentitiesAndRejectsUnrelatedReplies() async throws {
    enum SendFailure: Error { case timeout }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("transport.json")
    var queue = WatchNamespaceState()
    try queue.enqueueSnapshot(AppSnapshot(), base: AppSnapshot(), namespace: "account-A")
    try queue.enqueueSnapshot(AppSnapshot(entries: [try EnergyEntry(energy: 60)]), base: AppSnapshot(), namespace: "account-A")
    let first = try XCTUnwrap(queue.outbox.first)
    let second = try XCTUnwrap(queue.outbox.last)
    var seed = WatchPersistentState()
    seed.activeNamespace = "account-A"
    seed.spaces["account-A"] = queue
    try JSONEncoder().encode(seed).write(to: file)
    let bridge = WatchBridge(outboxURL: file)
    try bridge.setNamespace("account-A")
    var confirmed: [AppSnapshot] = []
    var reportedFailures = 0
    bridge.onAcknowledged = { snapshot, _ in confirmed.append(snapshot) }
    bridge.onError = { _ in reportedFailures += 1 }
    let firstACK = WatchWireMessage(kind: .acknowledgement, eventID: first.eventID, namespace: first.namespace)
    let secondACK = WatchWireMessage(kind: .acknowledgement, eventID: second.eventID, namespace: second.namespace)
    do {
      try await bridge.processReply(secondACK.encoded(), for: first)
      XCTFail("a reply for another event cannot advance this request")
    } catch WatchBridgeError.invalidMessage {}
    do {
      try await bridge.processReply(first.encoded(), for: first)
      XCTFail("a snapshot is not a product acknowledgement")
    } catch WatchBridgeError.invalidMessage {}
    XCTAssertEqual(bridge.pendingCount, 2)
    bridge.reportSendError(SendFailure.timeout, for: first)
    XCTAssertEqual(reportedFailures, 1)
    try await bridge.processReply(firstACK.encoded(), for: first)
    try await bridge.processReply(firstACK.encoded(), for: first)
    XCTAssertEqual(bridge.pendingCount, 1)
    bridge.reportSendError(SendFailure.timeout, for: first)
    bridge.reportBackgroundTransferError(SendFailure.timeout, messageData: try first.encoded())
    XCTAssertEqual(reportedFailures, 1, "a late timeout must not overwrite a saved acknowledgement")
    let midway = try JSONDecoder().decode(WatchPersistentState.self, from: Data(contentsOf: file))
    XCTAssertEqual(midway.spaces["account-A"]?.outbox.first?.eventID, second.eventID)
    XCTAssertEqual(confirmed, [try XCTUnwrap(first.snapshot)])
    try bridge.setNamespace("account-B")
    bridge.reportSendError(SendFailure.timeout, for: second)
    bridge.reportBackgroundTransferError(SendFailure.timeout, messageData: try second.encoded())
    XCTAssertEqual(reportedFailures, 1, "a callback from an inactive namespace must not change current status")
    try bridge.setNamespace("account-A")
    bridge.reportSendError(SendFailure.timeout, for: second)
    XCTAssertEqual(reportedFailures, 2)
    try await bridge.processReply(secondACK.encoded(), for: second)
    XCTAssertEqual(bridge.pendingCount, 0)
    XCTAssertEqual(confirmed, [try XCTUnwrap(first.snapshot), try XCTUnwrap(second.snapshot)])
    var acknowledgementOfAcknowledgement = false
    try await bridge.processIncoming(secondACK.encoded(), inlineAcknowledgement: { _ in acknowledgementOfAcknowledgement = true })
    XCTAssertFalse(acknowledgementOfAcknowledgement)
  }

  @MainActor
  func testBackgroundAcknowledgementErrorsAreScopedToAnAcceptedActiveEvent() async throws {
    enum Failure: Error { case disconnected }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bridge = WatchBridge(outboxURL: folder.appendingPathComponent("transport.json"))
    try bridge.setNamespace("account-A")
    let event = WatchWireMessage(kind: .snapshot, namespace: "account-A", snapshot: AppSnapshot())
    let ack = WatchWireMessage(kind: .acknowledgement, eventID: event.eventID, namespace: event.namespace)
    var errors = 0
    bridge.onError = { _ in errors += 1 }
    bridge.reportBackgroundTransferError(Failure.disconnected, messageData: nil)
    bridge.reportBackgroundTransferError(Failure.disconnected, messageData: Data("invalid".utf8))
    bridge.reportBackgroundTransferError(Failure.disconnected, messageData: try ack.encoded())
    XCTAssertEqual(errors, 0)
    bridge.onReceive = { _ in }
    try await bridge.processIncoming(event.encoded(), inlineAcknowledgement: { _ in })
    bridge.reportBackgroundTransferError(Failure.disconnected, messageData: try ack.encoded())
    XCTAssertEqual(errors, 1)
    try bridge.setNamespace("account-B")
    bridge.reportBackgroundTransferError(Failure.disconnected, messageData: try ack.encoded())
    XCTAssertEqual(errors, 1, "a prior account's ACK error must not replace the active account's state")
  }
}

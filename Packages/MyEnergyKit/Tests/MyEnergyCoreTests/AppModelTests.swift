import Foundation
import MyEnergyCore
import MyEnergyUI
import Testing

@Suite("Durable UI state", .serialized)
struct AppModelTests {
  private func location() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("records.json")
  }

  @Test @MainActor func demoCannotOverwriteDiskAndRealRecordsSurvive() async throws {
    let url = location()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let model = AppModel(storageURL: url)
    await model.load()
    #expect(await model.saveEntry(energy: 43, mood: .neutral, note: "test", occurredAt: Date()))
    let real = model.snapshot
    model.startDemo()
    #expect(model.isDemo)
    do { try await model.replaceSnapshot(AppSnapshot()); Issue.record("sync replacement must be blocked in demo") } catch {}
    model.exitDemo()
    #expect(model.snapshot == real)
    let reloaded = AppModel(storageURL: url)
    await reloaded.load()
    #expect(reloaded.snapshot == real)
  }

  @Test @MainActor func failedSpaceSwitchAndDeletedEditorNeverReplaceRecords() async throws {
    let url = location()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let model = AppModel(storageURL: url)
    await model.load()
    #expect(await model.saveEntry(energy: 70, mood: .good, note: "", occurredAt: Date()))
    let entry = try #require(model.snapshot.entries.first)
    let bad = url.deletingLastPathComponent().appendingPathComponent("broken.json")
    try Data("broken".utf8).write(to: bad)
    do { try await model.switchStorage(to: bad); Issue.record("corrupt space must fail") } catch {}
    #expect(model.storageURL == url)
    #expect(model.snapshot.entries == [entry])
    #expect(await model.deleteEntry(entry))
    #expect(!(await model.saveEntry(id: entry.id, energy: 99, mood: nil, note: "", occurredAt: entry.occurredAt)))
    #expect(model.snapshot.entries.isEmpty)
    #expect(model.snapshot.deletions.contains { $0.entityID == entry.id.uuidString })
  }

  @Test @MainActor func clearRetainsTombstonesAndReopeningKeepsDeletion() async throws {
    let url = location()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let model = AppModel(storageURL: url)
    await model.load()
    #expect(await model.saveHabit(title: "休息一下", symbol: "leaf"))
    let habit = try #require(model.activeHabits.first)
    #expect(await model.toggleHabit(habit))
    #expect(await model.clearAllData())
    #expect(model.snapshot.habits.isEmpty)
    #expect(model.snapshot.checkIns.isEmpty)
    #expect(!model.snapshot.deletions.isEmpty)
    let next = AppModel(storageURL: url)
    await next.load()
    #expect(next.snapshot == model.snapshot)
  }
}

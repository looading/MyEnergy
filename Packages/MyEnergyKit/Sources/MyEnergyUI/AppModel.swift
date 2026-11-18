import Foundation
import SwiftUI
import MyEnergyCore
import MyEnergyPlatform

@MainActor
protocol AppHealthClient: AnyObject {
    var isAvailable: Bool { get }
    func requestReadAccess() async throws
    func fetchReport(now: Date) async throws -> HealthReport
}

extension HealthDataClient: AppHealthClient {}

/// 界面只在磁盘保存成功后切换到新状态，失败时保留表单输入。
@MainActor
public final class AppModel: ObservableObject {
    @Published public var snapshot: AppSnapshot = .init()
    @Published public var errorMessage: String?
    @Published public private(set) var isLoaded = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var hasLoadFailure = false
    @Published public private(set) var isDemo = false
    @Published public private(set) var healthReport: HealthReport?
    @Published public private(set) var healthError: String?
    @Published public private(set) var healthConnected = false
    @Published public private(set) var isRefreshingHealth = false
    @Published public private(set) var healthSharingEnabled = false
    @Published public private(set) var lastSavedAt: Date?

    private var store: SnapshotFileStore
    @Published public private(set) var storageURL: URL
    private let healthClient: any AppHealthClient
    private let healthSourceIdentifier: String
    private var healthSharingGenerationID: UUID?
    private var realSnapshot: AppSnapshot?
    private var healthGeneration = 0

    public convenience init(storageURL: URL? = nil) {
        self.init(storageURL: storageURL, healthClient: HealthDataClient(), preferences: .standard)
    }

    init(storageURL: URL? = nil, healthClient: any AppHealthClient, preferences: UserDefaults) {
        let url = storageURL ?? Self.defaultStorageURL
        self.storageURL = url
        store = SnapshotFileStore(url: url)
        self.healthClient = healthClient
        let key = "MyEnergy.healthSummarySourceIdentifier"
        if let saved = preferences.string(forKey: key), UUID(uuidString: saved) != nil {
            healthSourceIdentifier = saved
        } else {
            let generated = UUID().uuidString
            preferences.set(generated, forKey: key)
            healthSourceIdentifier = generated
        }
    }

    public static var defaultStorageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MyEnergy", isDirectory: true).appendingPathComponent("records.json")
    }

    public var healthIsAvailable: Bool { healthClient.isAvailable }
    public var hasHealthSharingAccountContext: Bool {
        !isDemo && storageURL.standardizedFileURL != Self.defaultStorageURL.standardizedFileURL
    }
    public var healthReportHasData: Bool { healthReport.map(Self.hasData) ?? false }
    public var ownSharedHealthSummaryCount: Int {
        visibleSharedHealthSummaries.filter { $0.sourceIdentifier == healthSourceIdentifier }.count
    }
    public var latestSharedHealthSummary: SharedHealthSummary? {
        let otherDevices = visibleSharedHealthSummaries.filter { $0.sourceIdentifier != healthSourceIdentifier }
        return (otherDevices.isEmpty ? visibleSharedHealthSummaries : otherDevices).max { $0.updatedAt < $1.updatedAt }
    }
    public func isOwnSharedHealthSummary(_ summary: SharedHealthSummary) -> Bool {
        summary.sourceIdentifier == healthSourceIdentifier
    }
    public var canEdit: Bool { isLoaded && !hasLoadFailure && !isSaving }
    public var activeHabits: [HabitDefinition] { snapshot.habits.filter { !$0.isArchived }.sorted { $0.createdAt < $1.createdAt } }
    public var todayKey: String { DateRules.dayKey(for: Date()) }
    public var todayEntries: [EnergyEntry] { entries(for: todayKey) }
    public var latestEntry: EnergyEntry? { snapshot.entries.max { $0.occurredAt < $1.occurredAt } }
    public var visibleSleepRecords: [SleepRecord] {
        let removed = Set(snapshot.deletions.filter { $0.entity == .sleep }.map(\.entityID))
        return snapshot.sleepRecords.filter { !removed.contains($0.id.uuidString) }.sorted { $0.wakeTime > $1.wakeTime }
    }
    public var latestSleepObservation: SleepObservation? { sleepObservations(days: 30).last }
    public func sleepObservations(days: Int, now: Date = Date()) -> [SleepObservation] {
        SleepObservationBuilder.build(manual: visibleSleepRecords,
            health: isDemo ? [] : (healthReport?.sleepHistory ?? []),
            shared: isDemo ? [] : visibleSharedHealthSummaries, days: days, now: now)
    }
    public var localStatus: String {
        if isDemo { return "示例空间 · 仅在内存" }
        if hasLoadFailure { return "读取失败 · 原文件已保留" }
        if isSaving { return "正在保存到本机…" }
        return isLoaded ? "本机记录" : "正在读取…"
    }

    public func entries(for dayKey: String) -> [EnergyEntry] {
        snapshot.entries.filter {
            DateRules.dayKey(for: $0.occurredAt, timeZone: TimeZone(identifier: $0.timeZoneIdentifier) ?? .current) == dayKey
        }.sorted { $0.occurredAt > $1.occurredAt }
    }

    public func isComplete(_ habit: HabitDefinition, dayKey: String? = nil) -> Bool {
        snapshot.checkIns.first { $0.habitID == habit.id && $0.dayKey == (dayKey ?? todayKey) }?.isComplete ?? false
    }

    public func load() async {
        guard !isLoaded, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            snapshot = try await store.load()
            isLoaded = true
            hasLoadFailure = false
            errorMessage = nil
        } catch {
            hasLoadFailure = true
            errorMessage = "暂时无法读取本机记录。原文件已保留，请重试。\n\(error.localizedDescription)"
        }
    }

    public func persist() async {
        _ = await apply(snapshot)
    }

    /// 账号切换先读取目标空间，读取失败时完整保留当前空间。
    public func switchStorage(to url: URL) async throws {
        guard !isDemo, !isSaving else { throw AppModelStorageError.busyOrDemo }
        isSaving = true
        defer { isSaving = false }
        let nextStore = SnapshotFileStore(url: url)
        let nextSnapshot = try await nextStore.load()
        if storageURL.standardizedFileURL != url.standardizedFileURL {
            disconnectHealth()
        }
        store = nextStore
        storageURL = url
        snapshot = nextSnapshot
        isLoaded = true
        hasLoadFailure = false
        errorMessage = nil
        lastSavedAt = nil
    }

    /// 同步接收方仅在此方法成功返回后发送已持久化确认。
    public func replaceSnapshot(_ value: AppSnapshot) async throws {
        guard canEdit, !isDemo else { throw AppModelStorageError.busyOrDemo }
        isSaving = true
        defer { isSaving = false }
        let validated = try value.validated()
        try await store.save(validated)
        snapshot = validated
        lastSavedAt = Date()
        errorMessage = nil
    }

    @discardableResult
    public func saveEntry(id: UUID? = nil, energy: Int, mood: Mood?, note: String, occurredAt: Date) async -> Bool {
        do {
            let existing = id.flatMap { value in snapshot.entries.first { $0.id == value } }
            guard id == nil || existing != nil else {
                errorMessage = "这条记录已不存在，可能已在另一台设备删除。你的输入仍在当前页面。"
                return false
            }
            let entry = try EnergyEntry(id: id ?? UUID(), energy: energy, mood: mood, note: note,
                occurredAt: occurredAt, modifiedAt: Date(), timeZoneIdentifier: existing?.timeZoneIdentifier ?? TimeZone.current.identifier)
            var candidate = snapshot
            candidate.entries.removeAll { $0.id == entry.id }
            candidate.entries.append(entry)
            return await apply(candidate)
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    public func deleteEntry(_ entry: EnergyEntry) async -> Bool {
        var candidate = snapshot
        candidate.entries.removeAll { $0.id == entry.id }
        addDeletion(.init(entity: .entry, entityID: entry.id.uuidString), to: &candidate)
        return await apply(candidate)
    }

    @discardableResult
    public func saveSleep(id: UUID? = nil, bedtime: Date, wakeTime: Date, note: String = "") async -> Bool {
        if let id, !visibleSleepRecords.contains(where: { $0.id == id }) {
            errorMessage = "这条睡眠记录已被删除，请关闭旧编辑页后重新补记。"
            return false
        }
        guard wakeTime <= Date() else {
            errorMessage = "观测记录的结束时间不能在未来。"
            return false
        }
        do {
            let existing = id.flatMap { value in visibleSleepRecords.first { $0.id == value } }
            let record = try SleepRecord(id: id ?? UUID(), bedtime: bedtime, wakeTime: wakeTime,
                timeZoneIdentifier: existing?.timeZoneIdentifier ?? TimeZone.current.identifier,
                note: note, modifiedAt: Date())
            var candidate = snapshot
            candidate.sleepRecords.removeAll { $0.id == record.id }
            candidate.sleepRecords.append(record)
            return await apply(candidate)
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    public func deleteSleep(_ record: SleepRecord) async -> Bool {
        guard visibleSleepRecords.contains(where: { $0.id == record.id }) else { return false }
        var candidate = snapshot
        candidate.sleepRecords.removeAll { $0.id == record.id }
        addDeletion(.init(entity: .sleep, entityID: record.id.uuidString), to: &candidate)
        return await apply(candidate)
    }

    @discardableResult
    public func saveHabit(id: UUID? = nil, title: String, symbol: String) async -> Bool {
        do {
            let existing = id.flatMap { value in snapshot.habits.first { $0.id == value } }
            guard id == nil || existing != nil else {
                errorMessage = "这个习惯已不存在。你的输入仍在当前页面。"
                return false
            }
            let habit = try HabitDefinition(id: id ?? UUID(), title: title, symbol: symbol,
                isArchived: existing?.isArchived ?? false, createdAt: existing?.createdAt ?? Date(), modifiedAt: Date())
            var candidate = snapshot
            candidate.habits.removeAll { $0.id == habit.id }
            candidate.habits.append(habit)
            return await apply(candidate)
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    public func setHabitArchived(_ habit: HabitDefinition, archived: Bool) async -> Bool {
        var candidate = snapshot
        guard let index = candidate.habits.firstIndex(where: { $0.id == habit.id }) else { return false }
        candidate.habits[index].isArchived = archived
        candidate.habits[index].modifiedAt = Date()
        return await apply(candidate)
    }

    @discardableResult
    public func toggleHabit(_ habit: HabitDefinition, dayKey: String? = nil) async -> Bool {
        do {
            let fixedDay = dayKey ?? todayKey
            let checkIn = try HabitCheckIn(habitID: habit.id, dayKey: fixedDay,
                isComplete: !isComplete(habit, dayKey: fixedDay))
            var candidate = snapshot
            candidate.checkIns.removeAll { $0.id == checkIn.id }
            candidate.checkIns.append(checkIn)
            return await apply(candidate)
        } catch { errorMessage = error.localizedDescription; return false }
    }

    /// 清除可见内容时保留删除标记，供离线设备恢复连接后传播删除。
    @discardableResult
    public func clearAllData() async -> Bool {
        var candidate = snapshot
        for entry in candidate.entries { addDeletion(.init(entity: .entry, entityID: entry.id.uuidString), to: &candidate) }
        for habit in candidate.habits { addDeletion(.init(entity: .habit, entityID: habit.id.uuidString), to: &candidate) }
        for checkIn in candidate.checkIns { addDeletion(.init(entity: .checkIn, entityID: checkIn.id), to: &candidate) }
        for summary in candidate.sharedHealthSummaries { addDeletion(.init(entity: .healthSummary, entityID: summary.id.uuidString), to: &candidate) }
        for sleep in candidate.sleepRecords { addDeletion(.init(entity: .sleep, entityID: sleep.id.uuidString), to: &candidate) }
        candidate.entries = []
        candidate.habits = []
        candidate.checkIns = []
        candidate.sharedHealthSummaries = []
        candidate.sleepRecords = []
        healthGeneration += 1
        let saved = await apply(candidate)
        if saved { healthSharingEnabled = false; healthSharingGenerationID = nil }
        return saved
    }

    public func startDemo() {
        guard canEdit, !isDemo else { return }
        realSnapshot = snapshot
        isDemo = true
        snapshot = DemoRecords.make()
        errorMessage = nil
        disconnectHealth()
    }

    public func exitDemo() {
        guard isDemo else { return }
        snapshot = realSnapshot ?? .init()
        realSnapshot = nil
        isDemo = false
        errorMessage = nil
    }

    public func connectHealth() async {
        guard !isDemo, !isRefreshingHealth else { return }
        guard healthIsAvailable else {
            healthError = "这台设备不支持读取 Apple 健康。主观记录和习惯可以照常使用。"
            return
        }
        let generation = healthGeneration
        isRefreshingHealth = true
        defer { isRefreshingHealth = false }
        do {
            try await healthClient.requestReadAccess()
            guard !isDemo, generation == healthGeneration else { return }
            healthConnected = true
            let report = try await healthClient.fetchReport(now: Date())
            guard !isDemo, healthConnected, generation == healthGeneration else { return }
            healthReport = report
            healthError = nil
            if healthSharingEnabled { _ = await shareLatestHealthReport() }
        } catch {
            guard generation == healthGeneration else { return }
            healthError = error.localizedDescription
        }
    }

    public func refreshHealth() async {
        guard healthConnected, !isDemo, !isRefreshingHealth else { return }
        let generation = healthGeneration
        isRefreshingHealth = true
        defer { isRefreshingHealth = false }
        do {
            let report = try await healthClient.fetchReport(now: Date())
            guard generation == healthGeneration, healthConnected, !isDemo else { return }
            healthReport = report
            healthError = nil
            if healthSharingEnabled { _ = await shareLatestHealthReport() }
        } catch {
            guard generation == healthGeneration else { return }
            healthError = "暂时无法读取身体数据，请稍后重试。\n\(error.localizedDescription)"
        }
    }

    public func disconnectHealth() {
        healthGeneration += 1
        healthConnected = false
        healthReport = nil
        healthError = nil
        healthSharingEnabled = false
        healthSharingGenerationID = nil
    }

    /// 仅用户明确开启后，把当前摘要加入当前账号的加密记录空间。
    @discardableResult
    public func setHealthSharing(_ enabled: Bool) async -> Bool {
        if !enabled {
            // 即使磁盘暂时写入失败，也立即停止后续新增分享；删除仍需重试保存。
            healthSharingEnabled = false
            healthSharingGenerationID = nil
        }
        guard canEdit, !isDemo else {
            healthError = "请先退出示例，并等待本机记录读取或保存完成。"
            return false
        }
        if enabled {
            guard hasHealthSharingAccountContext, healthIsAvailable, let report = healthReport, Self.hasData(report) else {
                healthError = "请先进入账号空间，并在支持的设备上主动读取可用健康数据，再选择共享摘要。"
                return false
            }
            if healthSharingEnabled { return await shareLatestHealthReport() }
            let generationID = UUID()
            let healthRequestGeneration = healthGeneration
            do {
                let summary = try makeSharedSummary(report, id: generationID)
                var candidate = snapshot
                removeOwnSharedSummaries(from: &candidate)
                candidate.sharedHealthSummaries.append(summary)
                guard await apply(candidate) else { healthError = errorMessage; return false }
                guard healthRequestGeneration == healthGeneration, healthConnected else {
                    _ = await setHealthSharing(false)
                    return false
                }
                healthSharingGenerationID = generationID
                healthSharingEnabled = true
                healthError = nil
                return true
            } catch { healthError = error.localizedDescription; return false }
        }
        var candidate = snapshot
        removeOwnSharedSummaries(from: &candidate)
        guard await apply(candidate) else { healthError = errorMessage; return false }
        healthSharingEnabled = false
        healthSharingGenerationID = nil
        healthError = nil
        return true
    }

    @discardableResult
    public func shareLatestHealthReport() async -> Bool {
        guard healthSharingEnabled, hasHealthSharingAccountContext, healthIsAvailable,
              let id = healthSharingGenerationID, let report = healthReport, Self.hasData(report) else { return false }
        // 删除传播到本机后停止该代分享，不用同一 ID 重新创建已被删除的摘要。
        guard !snapshot.deletions.contains(where: { $0.entity == .healthSummary && $0.entityID == id.uuidString }) else {
            healthSharingEnabled = false
            healthSharingGenerationID = nil
            healthError = "此设备的共享摘要已被删除；如需继续，请重新明确开启共享。"
            return false
        }
        do {
            let summary = try makeSharedSummary(report, id: id)
            var candidate = snapshot
            candidate.sharedHealthSummaries.removeAll { $0.id == id }
            candidate.sharedHealthSummaries.append(summary)
            let saved = await apply(candidate)
            if !saved { healthError = errorMessage }
            return saved
        } catch { healthError = error.localizedDescription; return false }
    }

    private var visibleSharedHealthSummaries: [SharedHealthSummary] {
        let removed = Set(snapshot.deletions.filter { $0.entity == .healthSummary }.map(\.entityID))
        return snapshot.sharedHealthSummaries.filter { !removed.contains($0.id.uuidString) }
    }

    private static func hasData(_ report: HealthReport) -> Bool {
        report.recovery.latestMS != nil || report.restingHeartRate != nil || report.sleepHours != nil || !report.sleepHistory.isEmpty
    }

    private func makeSharedSummary(_ report: HealthReport, id: UUID) throws -> SharedHealthSummary {
        let latestSleep = SleepNight.latestPrimary(in: report.sleepHistory)
        return try SharedHealthSummary(id: id, sourceIdentifier: healthSourceIdentifier,
            sourceDescription: report.sourceDescription, recovery: report.recovery,
            restingHeartRate: report.restingHeartRate, sleepHours: latestSleep?.durationHours ?? report.sleepHours,
            updatedAt: report.updatedAt, sleepNight: latestSleep)
    }

    private func removeOwnSharedSummaries(from candidate: inout AppSnapshot) {
        for summary in candidate.sharedHealthSummaries where summary.sourceIdentifier == healthSourceIdentifier {
            addDeletion(.init(entity: .healthSummary, entityID: summary.id.uuidString), to: &candidate)
        }
        candidate.sharedHealthSummaries.removeAll { $0.sourceIdentifier == healthSourceIdentifier }
    }

    private func apply(_ candidate: AppSnapshot) async -> Bool {
        guard canEdit else {
            errorMessage = hasLoadFailure ? "请先重试读取记录，避免覆盖原文件。" : "正在处理上一项操作，请稍后重试。"
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let validated = try candidate.validated()
            if !isDemo { try await store.save(validated) }
            snapshot = validated
            if !isDemo { lastSavedAt = Date() }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "未能保存，请重试。你的输入仍在当前页面。\n\(error.localizedDescription)"
            return false
        }
    }

    private func addDeletion(_ deletion: DeletionRecord, to value: inout AppSnapshot) {
        value.deletions.removeAll { $0.id == deletion.id }
        value.deletions.append(deletion)
    }
}

private enum AppModelStorageError: LocalizedError {
    case busyOrDemo
    var errorDescription: String? { "当前无法切换或写入数据空间。请退出示例并等待本机记录读取或保存完成。" }
}

private enum DemoRecords {
    static func make(now: Date = Date()) -> AppSnapshot {
        let calendar = Calendar.current
        let energies = [64, 58, 72, 61, 79, 68, 74, 55, 67, 81, 70, 76, 63, 72]
        var entries: [EnergyEntry] = []
        for offset in 0..<14 where offset != 4 && offset != 9 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now),
                  let date = calendar.date(bySettingHour: offset == 0 ? 9 : 18, minute: 20, second: 0, of: day),
                  let entry = try? EnergyEntry(energy: energies[offset], mood: offset % 3 == 0 ? .neutral : .good,
                    note: offset == 0 ? "午后想留一点时间，出去走走。" : "示例记录", occurredAt: min(date, now)) else { continue }
            entries.append(entry)
        }
        let habits = [("起身走一走", "figure.walk"), ("喝一杯水", "drop"), ("留一点空闲", "leaf")]
            .compactMap { try? HabitDefinition(title: $0.0, symbol: $0.1) }
        let checkIns = habits.prefix(1).compactMap { try? HabitCheckIn(habitID: $0.id, dayKey: DateRules.dayKey(for: now), isComplete: true) }
        let sleepHours = [7.4, 6.8, 8.1, 7.2, 7.7, 6.5, 8.0, 7.5, 7.1, 8.2, 6.9, 7.8, 7.3, 7.6]
        let sleep = (0..<14).compactMap { offset -> SleepRecord? in
            guard offset != 4 && offset != 9,
                  let day = calendar.date(byAdding: .day, value: -offset, to: now),
                  let end = calendar.date(bySettingHour: 7, minute: 10, second: 0, of: day), end <= now else { return nil }
            return try? SleepRecord(bedtime: end.addingTimeInterval(-sleepHours[offset] * 3_600), wakeTime: end,
                timeZoneIdentifier: TimeZone.current.identifier, note: "示例睡眠时段，不是真实健康测量。", modifiedAt: end)
        }
        return AppSnapshot(entries: entries, habits: habits, checkIns: checkIns, sleepRecords: sleep)
    }
}

import Foundation
import MyEnergyCore

public struct SleepObservation: Identifiable, Equatable, Sendable {
    public let dayKey: String
    public let bedtime: Date
    public let wakeTime: Date
    public let durationHours: Double
    public let sourceTitle: String
    public let isEstimated: Bool
    public let timeZoneIdentifier: String
    public var id: String { dayKey }
}

/// 每天保留一份主要观测，来源优先级明确，不将重叠的手工和自动数据相加。
enum SleepObservationBuilder {
    static func build(manual: [SleepRecord], health: [SleepNight], shared: [SharedHealthSummary],
                      days: Int, now: Date, timeZone: TimeZone = .current) -> [SleepObservation] {
        guard days > 0, now.timeIntervalSince1970.isFinite else { return [] }
        let keys = Set(DateRules.recentDays(count: min(days, 30), endingAt: now, timeZone: timeZone)
            .map { DateRules.dayKey(for: $0, timeZone: timeZone) })
        var selected: [String: (priority: Int, observation: SleepObservation)] = [:]
        func include(bedtime: Date, wakeTime: Date, hours: Double, zoneID: String, source: String,
                     estimated: Bool, priority: Int) {
            guard wakeTime <= now, wakeTime > bedtime, hours.isFinite, hours > 0,
                  TimeZone(identifier: zoneID) != nil else { return }
            // 日期范围与分组共用查看设备的时区，避免其他时区的已结束记录落到“明天”而消失。
            let day = DateRules.dayKey(for: wakeTime, timeZone: timeZone)
            guard keys.contains(day) else { return }
            let observation = SleepObservation(dayKey: day, bedtime: bedtime, wakeTime: wakeTime,
                durationHours: hours, sourceTitle: source, isEstimated: estimated, timeZoneIdentifier: zoneID)
            if let current = selected[day] {
                if priority > current.priority { return }
                if priority == current.priority {
                    if hours < current.observation.durationHours { return }
                    if hours == current.observation.durationHours && wakeTime < current.observation.wakeTime { return }
                    if hours == current.observation.durationHours && wakeTime == current.observation.wakeTime {
                        if source > current.observation.sourceTitle { return }
                        if source == current.observation.sourceTitle && bedtime >= current.observation.bedtime { return }
                    }
                }
            }
            selected[day] = (priority, observation)
        }
        for night in health {
            include(bedtime: night.bedtime, wakeTime: night.wakeTime, hours: night.durationHours,
                zoneID: night.timeZoneIdentifier, source: "Apple 健康 · \(night.sourceDescription)", estimated: false, priority: 0)
        }
        for summary in shared {
            guard let night = summary.sleepNight else { continue }
            include(bedtime: night.bedtime, wakeTime: night.wakeTime, hours: night.durationHours,
                zoneID: night.timeZoneIdentifier, source: "已授权设备摘要 · \(summary.sourceDescription)", estimated: false, priority: 1)
        }
        for record in manual {
            include(bedtime: record.bedtime, wakeTime: record.wakeTime, hours: record.durationHours,
                zoneID: record.timeZoneIdentifier, source: "手动补记 · 自述时段估算", estimated: true, priority: 2)
        }
        return selected.keys.sorted().compactMap { selected[$0]?.observation }
    }
}

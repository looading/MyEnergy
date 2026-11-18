import Foundation
import MyEnergyCore

struct HealthSleepInterval: Equatable, Sendable {
  let start: Date
  let end: Date
  let isAsleep: Bool
}

enum HealthSleepAnalyzer {
  /// 先合并实际睡眠的重叠区间，再将间隔不超过三小时的区间归为一个展示片段。
  /// 分组间隔不计入实际睡眠；未结束、未来或超过 24 小时的无效观测不会显示。
  static func nights(intervals: [HealthSleepInterval], now: Date, timeZone: TimeZone = .current) -> [SleepNight] {
    guard now.timeIntervalSinceReferenceDate.isFinite else { return [] }
    let completed = intervals.compactMap { sample -> DateInterval? in
      guard sample.isAsleep, sample.start.timeIntervalSinceReferenceDate.isFinite,
            sample.end.timeIntervalSinceReferenceDate.isFinite, sample.end <= now,
            sample.start < sample.end, sample.end.timeIntervalSince(sample.start) <= 24 * 3_600 else { return nil }
      return DateInterval(start: sample.start, end: sample.end)
    }.sorted { lhs, rhs in
      lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
    }
    guard let first = completed.first else { return [] }
    var union: [DateInterval] = []
    var current = first
    for range in completed.dropFirst() {
      if range.start <= current.end {
        current = DateInterval(start: current.start, end: max(current.end, range.end))
      } else {
        union.append(current)
        current = range
      }
    }
    union.append(current)

    var nights: [SleepNight] = []
    var bedtime = union[0].start
    var wakeTime = union[0].end
    var asleepSeconds = union[0].duration
    func appendNight() {
      // 过长的完整片段整体忽略，不裁剪成看似有效的观测。
      if let night = try? SleepNight(bedtime: bedtime, wakeTime: wakeTime,
                                    asleepSeconds: min(asleepSeconds, wakeTime.timeIntervalSince(bedtime)),
                                    timeZoneIdentifier: timeZone.identifier, sourceDescription: "Apple 健康") {
        nights.append(night)
      }
    }
    for range in union.dropFirst() {
      if range.start.timeIntervalSince(wakeTime) <= 3 * 3_600 {
        wakeTime = range.end
        asleepSeconds += range.duration
      } else {
        appendNight()
        bedtime = range.start
        wakeTime = range.end
        asleepSeconds = range.duration
      }
    }
    appendNight()
    return nights
  }

  /// 对实际睡眠区间求并集，避免多个设备、来源或睡眠阶段重复计时。
  static func asleepSeconds(intervals: [HealthSleepInterval], within window: DateInterval) -> Double {
    guard window.start.timeIntervalSince1970.isFinite, window.end.timeIntervalSince1970.isFinite,
      window.end > window.start else { return 0 }
    let ranges = intervals.compactMap { sample -> DateInterval? in
      guard sample.isAsleep, sample.start.timeIntervalSince1970.isFinite,
        sample.end.timeIntervalSince1970.isFinite, sample.end > sample.start else { return nil }
      let start = max(sample.start, window.start)
      let end = min(sample.end, window.end)
      return end > start ? DateInterval(start: start, end: end) : nil
    }.sorted { $0.start < $1.start }
    guard let first = ranges.first else { return 0 }
    var current = first
    var total: Double = 0
    for range in ranges.dropFirst() {
      if range.start <= current.end {
        current = DateInterval(start: current.start, end: max(current.end, range.end))
      } else {
        total += current.duration
        current = range
      }
    }
    return total + current.duration
  }

  /// 以本地中午划分夜间窗口，只采纳已经结束且最近 36 小时内的睡眠样本。
  /// 该摘要不推断用户是否已起床，也不将 inBed、awake 当作睡眠。
  static func latestNightHours(
    intervals: [HealthSleepInterval], now: Date, timeZone: TimeZone = .current
  ) -> Double? {
    guard now.timeIntervalSince1970.isFinite else { return nil }
    let completed = intervals.filter {
      $0.isAsleep && $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite
        && $0.start < $0.end && $0.end <= now && now.timeIntervalSince($0.end) <= 36 * 3_600
    }
    guard let latest = completed.max(by: { $0.end < $1.end }) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: latest.end),
      let start = latest.end <= noon ? calendar.date(byAdding: .day, value: -1, to: noon) : noon,
      let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
    let seconds = asleepSeconds(intervals: completed, within: DateInterval(start: start, end: min(end, now)))
    return seconds > 0 ? seconds / 3_600 : nil
  }
}

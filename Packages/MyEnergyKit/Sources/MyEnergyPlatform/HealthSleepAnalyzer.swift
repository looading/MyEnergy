import Foundation

struct HealthSleepInterval: Equatable, Sendable {
  let start: Date
  let end: Date
  let isAsleep: Bool
}

enum HealthSleepAnalyzer {
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

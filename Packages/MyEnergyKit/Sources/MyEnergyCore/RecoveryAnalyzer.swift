import Foundation

public struct HRVSample: Codable, Equatable, Sendable {
  public let valueMS: Double
  public let date: Date

  public init(valueMS: Double, date: Date) {
    self.valueMS = valueMS
    self.date = date
  }
}

public enum RecoveryStatus: String, Codable, Sendable {
  case unavailable, insufficientHistory, stale, ready
}

public struct RecoverySummary: Codable, Equatable, Sendable {
  public let status: RecoveryStatus
  public let latestMS: Double?
  public let baselineMS: Double?
  public let changePercent: Double?
  public let sampledAt: Date?
  public let historyDays: Int

  public init(status: RecoveryStatus, latestMS: Double? = nil, baselineMS: Double? = nil,
              changePercent: Double? = nil, sampledAt: Date? = nil, historyDays: Int = 0) {
    self.status = status
    self.latestMS = latestMS
    self.baselineMS = baselineMS
    self.changePercent = changePercent
    self.sampledAt = sampledAt
    self.historyDays = historyDays
  }
}

/// 只计算与本人历史的数值对照，不从 HRV 推断情绪或给出临床分类。
public enum RecoveryAnalyzer {
  public static func analyze(samples: [HRVSample], now: Date = Date()) -> RecoverySummary {
    guard now.timeIntervalSinceReferenceDate.isFinite else { return RecoverySummary(status: .unavailable) }
    let valid = samples.filter {
      $0.valueMS.isFinite && $0.valueMS > 0 && $0.date.timeIntervalSinceReferenceDate.isFinite && $0.date <= now
    }
    // 时间相同的样本按数值排序，保证相同输入集合的最新样本选择稳定。
    guard let latest = valid.max(by: { $0.date == $1.date ? $0.valueMS < $1.valueMS : $0.date < $1.date }),
          let utc = TimeZone(secondsFromGMT: 0) else { return RecoverySummary(status: .unavailable) }
    let day: TimeInterval = 86_400
    let lowerBound = now.addingTimeInterval(-30 * day)
    let recentBoundary = now.addingTimeInterval(-day)
    let historical = valid.filter { $0.date >= lowerBound && $0.date < recentBoundary }
    let grouped = Dictionary(grouping: historical) { DateRules.dayKey(for: $0.date, timeZone: utc) }
    let dailyMedians = grouped.values.compactMap { median($0.map(\.valueMS)) }
    let baseline = dailyMedians.count >= 7 ? median(dailyMedians) : nil
    var change: Double?
    if let baseline {
      let percent = ((latest.valueMS - baseline) / baseline) * 100
      change = percent.isFinite ? percent : nil
    }
    let status: RecoveryStatus
    if now.timeIntervalSince(latest.date) > day { status = .stale }
    else if baseline == nil { status = .insufficientHistory }
    else { status = .ready }
    return RecoverySummary(status: status, latestMS: latest.valueMS, baselineMS: baseline, changePercent: change,
                           sampledAt: latest.date, historyDays: dailyMedians.count)
  }

  private static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      let lower = sorted[middle - 1]
      return lower + (sorted[middle] - lower) / 2
    }
    return sorted[middle]
  }
}

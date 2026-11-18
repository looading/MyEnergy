import Foundation

public enum DateRules {
  public static func dayKey(for date: Date, timeZone: TimeZone = .current) -> String {
    guard date.timeIntervalSinceReferenceDate.isFinite else { return "" }
    let calendar = gregorian(timeZone: timeZone)
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
    return String(format: "%04d-%02d-%02d", locale: Locale(identifier: "en_US_POSIX"), year, month, day)
  }

  /// 按本地日历从早到晚返回日期；夏令时切换不假设每天固定 24 小时。
  public static func recentDays(count: Int, endingAt: Date = Date(), timeZone: TimeZone = .current) -> [Date] {
    guard count > 0, endingAt.timeIntervalSinceReferenceDate.isFinite else { return [] }
    let calendar = gregorian(timeZone: timeZone)
    let last = calendar.startOfDay(for: endingAt)
    return (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: last) }
  }

  static func gregorian(timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = timeZone
    return calendar
  }

  static func isValidDayKey(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false }
    for (index, byte) in bytes.enumerated() where index != 4 && index != 7 {
      guard (48...57).contains(byte) else { return false }
    }
    guard let year = Int(value.prefix(4)), let month = Int(value.dropFirst(5).prefix(2)), let day = Int(value.suffix(2)),
          (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
          let utc = TimeZone(secondsFromGMT: 0) else { return false }
    let calendar = gregorian(timeZone: utc)
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 12
    guard let date = calendar.date(from: components) else { return false }
    let actual = calendar.dateComponents([.year, .month, .day], from: date)
    return actual.year == year && actual.month == month && actual.day == day
  }
}

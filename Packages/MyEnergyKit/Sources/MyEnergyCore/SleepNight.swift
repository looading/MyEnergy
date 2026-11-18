import Foundation

/// 已结束的睡眠观测片段；边界内的清醒间隔不计入实际睡眠秒数。
public struct SleepNight: Identifiable, Codable, Equatable, Sendable {
  public var id: String {
    let start = String(bedtime.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    let end = String(wakeTime.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    return "\(start):\(end):\(timeZoneIdentifier)"
  }
  public let bedtime: Date
  public let wakeTime: Date
  public let asleepSeconds: Double
  public let timeZoneIdentifier: String
  public let sourceDescription: String

  public init(bedtime: Date, wakeTime: Date, asleepSeconds: Double,
              timeZoneIdentifier: String = TimeZone.current.identifier,
              sourceDescription: String) throws {
    self.bedtime = bedtime
    self.wakeTime = wakeTime
    self.asleepSeconds = asleepSeconds
    self.timeZoneIdentifier = timeZoneIdentifier
    self.sourceDescription = sourceDescription
    try checkValidity()
  }

  public var durationHours: Double { asleepSeconds / 3_600 }

  /// 按观测结束日期归属，跨午夜和夏令时均使用记录的时区。
  public var dayKey: String {
    guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return "" }
    return DateRules.dayKey(for: wakeTime, timeZone: timeZone)
  }

  /// 取最近有观测日期的最长片段；同日午睡不会覆盖更长的主要睡眠。
  public static func latestPrimary(in nights: [SleepNight]) -> SleepNight? {
    nights.max { lhs, rhs in
      if lhs.dayKey != rhs.dayKey { return lhs.dayKey < rhs.dayKey }
      if lhs.asleepSeconds != rhs.asleepSeconds { return lhs.asleepSeconds < rhs.asleepSeconds }
      if lhs.wakeTime != rhs.wakeTime { return lhs.wakeTime < rhs.wakeTime }
      if lhs.id != rhs.id { return lhs.id < rhs.id }
      return lhs.sourceDescription < rhs.sourceDescription
    }
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(bedtime: values.decode(Date.self, forKey: .bedtime),
                    wakeTime: values.decode(Date.self, forKey: .wakeTime),
                    asleepSeconds: values.decode(Double.self, forKey: .asleepSeconds),
                    timeZoneIdentifier: values.decode(String.self, forKey: .timeZoneIdentifier),
                    sourceDescription: values.decode(String.self, forKey: .sourceDescription))
    } catch { throw ModelValidation.decodingError(error, decoder: decoder) }
  }

  func checkValidity() throws {
    try Self.validateInterval(bedtime: bedtime, wakeTime: wakeTime, timeZoneIdentifier: timeZoneIdentifier)
    guard asleepSeconds.isFinite, asleepSeconds > 0, asleepSeconds <= wakeTime.timeIntervalSince(bedtime) else {
      throw SnapshotValidationError.invalidValue("实际睡眠时长必须为有效正数，且不能超过观测时段。")
    }
  }

  static func validateInterval(bedtime: Date, wakeTime: Date, timeZoneIdentifier: String) throws {
    try ModelValidation.date(bedtime)
    try ModelValidation.date(wakeTime)
    let duration = wakeTime.timeIntervalSince(bedtime)
    guard duration > 0, duration <= 24 * 3_600 else {
      throw SnapshotValidationError.invalidValue("睡眠结束时间必须晚于开始，且单条时段不能超过 24 小时。")
    }
    guard TimeZone(identifier: timeZoneIdentifier) != nil else {
      throw SnapshotValidationError.invalidValue("睡眠记录包含无效时区。")
    }
  }

  private enum CodingKeys: String, CodingKey { case bedtime, wakeTime, asleepSeconds, timeZoneIdentifier, sourceDescription }
}

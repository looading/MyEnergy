import Foundation

/// 用户自行补记的睡眠时段；时长是自述估算，不代表传感器测量。
public struct SleepRecord: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var bedtime: Date
  public var wakeTime: Date
  public var timeZoneIdentifier: String
  public var note: String
  public var modifiedAt: Date

  public init(id: UUID = UUID(), bedtime: Date, wakeTime: Date,
              timeZoneIdentifier: String = TimeZone.current.identifier,
              note: String = "", modifiedAt: Date = Date()) throws {
    self.id = id
    self.bedtime = bedtime
    self.wakeTime = wakeTime
    self.timeZoneIdentifier = timeZoneIdentifier
    self.note = note
    self.modifiedAt = modifiedAt
    try checkValidity()
  }

  public var durationHours: Double { wakeTime.timeIntervalSince(bedtime) / 3_600 }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(id: values.decode(UUID.self, forKey: .id),
                    bedtime: values.decode(Date.self, forKey: .bedtime),
                    wakeTime: values.decode(Date.self, forKey: .wakeTime),
                    timeZoneIdentifier: values.decode(String.self, forKey: .timeZoneIdentifier),
                    note: values.decode(String.self, forKey: .note),
                    modifiedAt: values.decode(Date.self, forKey: .modifiedAt))
    } catch { throw ModelValidation.decodingError(error, decoder: decoder) }
  }

  func checkValidity() throws {
    try SleepNight.validateInterval(bedtime: bedtime, wakeTime: wakeTime, timeZoneIdentifier: timeZoneIdentifier)
    try ModelValidation.date(modifiedAt)
    guard note.count <= 500 else { throw SnapshotValidationError.invalidValue("备注最多 500 个字符。") }
  }

  private enum CodingKeys: String, CodingKey { case id, bedtime, wakeTime, timeZoneIdentifier, note, modifiedAt }
}

import Foundation

/// 用户主动分享的当前健康摘要；不包含 HealthKit 原始样本或测量历史。
public struct SharedHealthSummary: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var sourceIdentifier: String
  public var sourceDescription: String
  public var recovery: RecoverySummary
  public var restingHeartRate: Double?
  public var sleepHours: Double?
  public var updatedAt: Date

  public init(id: UUID = UUID(), sourceIdentifier: String, sourceDescription: String, recovery: RecoverySummary,
              restingHeartRate: Double? = nil, sleepHours: Double? = nil, updatedAt: Date = Date()) throws {
    self.id = id
    self.sourceIdentifier = sourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    self.sourceDescription = sourceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    self.recovery = recovery
    self.restingHeartRate = restingHeartRate
    self.sleepHours = sleepHours
    self.updatedAt = updatedAt
    try checkValidity()
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(id: values.decode(UUID.self, forKey: .id),
                    sourceIdentifier: values.decode(String.self, forKey: .sourceIdentifier),
                    sourceDescription: values.decode(String.self, forKey: .sourceDescription),
                    recovery: values.decode(RecoverySummary.self, forKey: .recovery),
                    restingHeartRate: values.decodeIfPresent(Double.self, forKey: .restingHeartRate),
                    sleepHours: values.decodeIfPresent(Double.self, forKey: .sleepHours),
                    updatedAt: values.decode(Date.self, forKey: .updatedAt))
    } catch { throw ModelValidation.decodingError(error, decoder: decoder) }
  }

  func checkValidity() throws {
    guard (1...128).contains(sourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).count) else {
      throw SnapshotValidationError.invalidValue("健康摘要的设备标识应为 1～128 个字符。")
    }
    guard (1...200).contains(sourceDescription.trimmingCharacters(in: .whitespacesAndNewlines).count) else {
      throw SnapshotValidationError.invalidValue("健康摘要的来源说明应为 1～200 个字符。")
    }
    if let restingHeartRate {
      guard restingHeartRate.isFinite && restingHeartRate > 0 else {
        throw SnapshotValidationError.invalidValue("静息心率必须为有效正数。")
      }
    }
    if let sleepHours {
      guard sleepHours.isFinite && (0...24).contains(sleepHours) else {
        throw SnapshotValidationError.invalidValue("睡眠时长应在 0～24 小时之间。")
      }
    }
    try ModelValidation.date(updatedAt)
    try recovery.checkValidity()
  }

  func validated() throws -> SharedHealthSummary {
    try SharedHealthSummary(id: id, sourceIdentifier: sourceIdentifier, sourceDescription: sourceDescription,
                            recovery: recovery, restingHeartRate: restingHeartRate, sleepHours: sleepHours, updatedAt: updatedAt)
  }

  private enum CodingKeys: String, CodingKey {
    case id, sourceIdentifier, sourceDescription, recovery, restingHeartRate, sleepHours, updatedAt
  }
}

extension RecoverySummary {
  func checkValidity() throws {
    guard (0...30).contains(historyDays) else {
      throw SnapshotValidationError.invalidValue("恢复参考的历史有效日数应在 0～30 之间。")
    }
    for measurement in [latestMS, baselineMS].compactMap({ $0 }) {
      guard measurement.isFinite && measurement > 0 else {
        throw SnapshotValidationError.invalidValue("恢复参考中的 HRV 必须为有效正数。")
      }
    }
    if let changePercent {
      guard changePercent.isFinite && changePercent >= -100 && latestMS != nil && baselineMS != nil else {
        throw SnapshotValidationError.invalidValue("恢复参考的变化比例无效。")
      }
    }
    if let sampledAt { try ModelValidation.date(sampledAt) }
    switch status {
    case .unavailable:
      guard latestMS == nil && baselineMS == nil && changePercent == nil && sampledAt == nil && historyDays == 0 else {
        throw SnapshotValidationError.invalidValue("不可用的恢复参考不能包含测量值。")
      }
    case .insufficientHistory:
      guard latestMS != nil && sampledAt != nil && historyDays < 7 && baselineMS == nil && changePercent == nil else {
        throw SnapshotValidationError.invalidValue("恢复参考的历史不足状态与数据不一致。")
      }
    case .ready:
      guard latestMS != nil && sampledAt != nil && baselineMS != nil && historyDays >= 7 else {
        throw SnapshotValidationError.invalidValue("恢复参考缺少有效的测量或历史基线。")
      }
    case .stale:
      guard latestMS != nil && sampledAt != nil,
            (historyDays >= 7 ? baselineMS != nil : baselineMS == nil) else {
        throw SnapshotValidationError.invalidValue("恢复参考的过期状态与数据不一致。")
      }
    }
  }
}

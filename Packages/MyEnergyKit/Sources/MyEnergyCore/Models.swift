import Foundation

public enum SnapshotValidationError: Error, Codable, Equatable, Sendable, LocalizedError {
  case invalidValue(String)
  case duplicateID(String)
  case unsupportedSchema(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidValue(let message): message
    case .duplicateID(let identifier): "数据包含重复标识：\(identifier)"
    case .unsupportedSchema(let version): "暂不支持数据版本 \(version)，原文件已保留。"
    }
  }
}

public enum Mood: String, CaseIterable, Codable, Sendable {
  case veryLow, low, neutral, good, veryGood

  public var title: String {
    switch self {
    case .veryLow: "很低落"
    case .low: "有些低落"
    case .neutral: "平静"
    case .good: "愉快"
    case .veryGood: "很愉快"
    }
  }

  public var symbol: String {
    switch self {
    case .veryLow: "cloud.rain"
    case .low: "cloud"
    case .neutral: "cloud.sun"
    case .good: "sun.max"
    case .veryGood: "sparkles"
    }
  }
}

public struct EnergyEntry: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var energy: Int
  public var mood: Mood?
  public var note: String
  public var occurredAt: Date
  public var modifiedAt: Date
  public var timeZoneIdentifier: String

  public init(id: UUID = UUID(), energy: Int, mood: Mood? = nil, note: String = "", occurredAt: Date = Date(),
              modifiedAt: Date? = nil, timeZoneIdentifier: String = TimeZone.current.identifier) throws {
    self.id = id
    self.energy = energy
    self.mood = mood
    self.note = note
    self.occurredAt = occurredAt
    self.modifiedAt = modifiedAt ?? occurredAt
    self.timeZoneIdentifier = timeZoneIdentifier
    try checkValidity()
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(id: values.decode(UUID.self, forKey: .id), energy: values.decode(Int.self, forKey: .energy),
                    mood: values.decodeIfPresent(Mood.self, forKey: .mood), note: values.decode(String.self, forKey: .note),
                    occurredAt: values.decode(Date.self, forKey: .occurredAt),
                    modifiedAt: values.decode(Date.self, forKey: .modifiedAt),
                    timeZoneIdentifier: values.decode(String.self, forKey: .timeZoneIdentifier))
    } catch { throw ModelValidation.decodingError(error, decoder: decoder) }
  }

  func checkValidity() throws {
    guard (0...100).contains(energy) else { throw SnapshotValidationError.invalidValue("精力应在 0～100 之间。") }
    guard note.count <= 500 else { throw SnapshotValidationError.invalidValue("备注最多 500 个字符。") }
    try ModelValidation.date(occurredAt)
    try ModelValidation.date(modifiedAt)
    guard TimeZone(identifier: timeZoneIdentifier) != nil else {
      throw SnapshotValidationError.invalidValue("记录包含无效时区。")
    }
  }

  private enum CodingKeys: String, CodingKey { case id, energy, mood, note, occurredAt, modifiedAt, timeZoneIdentifier }
}

public struct HabitDefinition: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var symbol: String
  public var isArchived: Bool
  public var createdAt: Date
  public var modifiedAt: Date

  public init(id: UUID = UUID(), title: String, symbol: String = "leaf", isArchived: Bool = false,
              createdAt: Date = Date(), modifiedAt: Date? = nil) throws {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...40).contains(trimmed.count) else {
      throw SnapshotValidationError.invalidValue("习惯名称应为 1～40 个字符。")
    }
    try ModelValidation.date(createdAt)
    try ModelValidation.date(modifiedAt ?? createdAt)
    self.id = id
    self.title = trimmed
    self.symbol = symbol
    self.isArchived = isArchived
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt ?? createdAt
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(id: values.decode(UUID.self, forKey: .id), title: values.decode(String.self, forKey: .title),
                    symbol: values.decode(String.self, forKey: .symbol), isArchived: values.decode(Bool.self, forKey: .isArchived),
                    createdAt: values.decode(Date.self, forKey: .createdAt), modifiedAt: values.decode(Date.self, forKey: .modifiedAt))
    } catch { throw ModelValidation.decodingError(error, decoder: decoder) }
  }

  func validated() throws -> HabitDefinition {
    try HabitDefinition(id: id, title: title, symbol: symbol, isArchived: isArchived, createdAt: createdAt, modifiedAt: modifiedAt)
  }

  private enum CodingKeys: String, CodingKey { case id, title, symbol, isArchived, createdAt, modifiedAt }
}

public struct HabitCheckIn: Identifiable, Codable, Equatable, Sendable {
  public var id: String { "\(habitID.uuidString):\(dayKey)" }
  public let habitID: UUID
  public let dayKey: String
  public var isComplete: Bool
  public var modifiedAt: Date

  public init(habitID: UUID, dayKey: String, isComplete: Bool, modifiedAt: Date = Date()) throws {
    guard DateRules.isValidDayKey(dayKey) else { throw SnapshotValidationError.invalidValue("打卡日期格式或日期无效。") }
    try ModelValidation.date(modifiedAt)
    self.habitID = habitID
    self.dayKey = dayKey
    self.isComplete = isComplete
    self.modifiedAt = modifiedAt
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(habitID: values.decode(UUID.self, forKey: .habitID), dayKey: values.decode(String.self, forKey: .dayKey),
                    isComplete: values.decode(Bool.self, forKey: .isComplete), modifiedAt: values.decode(Date.self, forKey: .modifiedAt))
    } catch { throw ModelValidation.decodingError(error, decoder: decoder) }
  }

  func checkValidity() throws {
    guard DateRules.isValidDayKey(dayKey) else { throw SnapshotValidationError.invalidValue("打卡日期格式或日期无效。") }
    try ModelValidation.date(modifiedAt)
  }

  private enum CodingKeys: String, CodingKey { case habitID, dayKey, isComplete, modifiedAt }
}

public enum EntityKind: String, Codable, Sendable { case entry, habit, checkIn, healthSummary }

public struct DeletionRecord: Identifiable, Codable, Equatable, Sendable {
  public var id: String { "\(entity.rawValue):\(entityID)" }
  public let entity: EntityKind
  public let entityID: String
  public let deletedAt: Date

  public init(entity: EntityKind, entityID: String, deletedAt: Date = Date()) {
    self.entity = entity
    self.entityID = ModelValidation.canonicalID(entityID, entity: entity) ?? entityID
    self.deletedAt = deletedAt
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(entity: try values.decode(EntityKind.self, forKey: .entity),
              entityID: try values.decode(String.self, forKey: .entityID), deletedAt: try values.decode(Date.self, forKey: .deletedAt))
    do { try checkValidity() } catch { throw ModelValidation.decodingError(error, decoder: decoder) }
  }

  func checkValidity() throws {
    guard ModelValidation.canonicalID(entityID, entity: entity) != nil else {
      throw SnapshotValidationError.invalidValue("删除标记包含无效标识。")
    }
    try ModelValidation.date(deletedAt)
  }

  private enum CodingKeys: String, CodingKey { case entity, entityID, deletedAt }
}

public struct AppSnapshot: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var entries: [EnergyEntry]
  public var habits: [HabitDefinition]
  public var checkIns: [HabitCheckIn]
  public var deletions: [DeletionRecord]
  public var sharedHealthSummaries: [SharedHealthSummary]

  public init(schemaVersion: Int = 1, entries: [EnergyEntry] = [], habits: [HabitDefinition] = [],
              checkIns: [HabitCheckIn] = [], deletions: [DeletionRecord] = [], sharedHealthSummaries: [SharedHealthSummary] = []) {
    self.schemaVersion = schemaVersion
    self.entries = entries
    self.habits = habits
    self.checkIns = checkIns
    self.deletions = deletions
    self.sharedHealthSummaries = sharedHealthSummaries
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let version = try values.decode(Int.self, forKey: .schemaVersion)
    guard version == 1 else {
      throw ModelValidation.decodingError(SnapshotValidationError.unsupportedSchema(version), decoder: decoder)
    }
    self.init(schemaVersion: version, entries: try values.decode([EnergyEntry].self, forKey: .entries),
              habits: try values.decode([HabitDefinition].self, forKey: .habits),
              checkIns: try values.decode([HabitCheckIn].self, forKey: .checkIns),
              deletions: try values.decode([DeletionRecord].self, forKey: .deletions),
              sharedHealthSummaries: try values.decodeIfPresent([SharedHealthSummary].self, forKey: .sharedHealthSummaries) ?? [])
    do { self = try validated() } catch { throw ModelValidation.decodingError(error, decoder: decoder) }
  }

  public func validated() throws -> AppSnapshot {
    guard schemaVersion == 1 else { throw SnapshotValidationError.unsupportedSchema(schemaVersion) }
    for entry in entries { try entry.checkValidity() }
    let checkedHabits = try habits.map { try $0.validated() }
    let checkedHealthSummaries = try sharedHealthSummaries.map { try $0.validated() }
    for checkIn in checkIns { try checkIn.checkValidity() }
    for deletion in deletions { try deletion.checkValidity() }
    try ModelValidation.unique(entries.map { $0.id.uuidString })
    try ModelValidation.unique(checkedHabits.map { $0.id.uuidString })
    try ModelValidation.unique(checkIns.map(\.id))
    try ModelValidation.unique(deletions.map(\.id))
    try ModelValidation.unique(checkedHealthSummaries.map { $0.id.uuidString })
    return AppSnapshot(schemaVersion: schemaVersion, entries: entries, habits: checkedHabits, checkIns: checkIns,
                       deletions: deletions, sharedHealthSummaries: checkedHealthSummaries)
  }

  private enum CodingKeys: String, CodingKey { case schemaVersion, entries, habits, checkIns, deletions, sharedHealthSummaries }
}

enum ModelValidation {
  static func date(_ value: Date) throws {
    guard value.timeIntervalSinceReferenceDate.isFinite else { throw SnapshotValidationError.invalidValue("日期无效。") }
  }

  static func unique(_ identifiers: [String]) throws {
    var seen = Set<String>()
    for identifier in identifiers where !seen.insert(identifier).inserted {
      throw SnapshotValidationError.duplicateID(identifier)
    }
  }

  static func canonicalID(_ value: String, entity: EntityKind) -> String? {
    switch entity {
    case .entry, .habit, .healthSummary: return UUID(uuidString: value)?.uuidString
    case .checkIn:
      let parts = value.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 2, let habitID = UUID(uuidString: String(parts[0])), DateRules.isValidDayKey(String(parts[1])) else { return nil }
      return "\(habitID.uuidString):\(parts[1])"
    }
  }

  static func decodingError(_ error: any Error, decoder: any Decoder) -> DecodingError {
    .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.localizedDescription, underlyingError: error))
  }
}

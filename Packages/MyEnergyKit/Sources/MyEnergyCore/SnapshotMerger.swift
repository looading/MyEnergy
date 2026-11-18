import Foundation

public enum ConflictSide: Codable, Equatable, Sendable { case local, remote }

public struct MergeConflict: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let entity: EntityKind
  public let entityID: String

  public init(entity: EntityKind, entityID: String) {
    self.entity = entity
    self.entityID = entityID
    self.id = "\(entity.rawValue):\(entityID)"
  }
}

public struct SnapshotMergeResult: Codable, Equatable, Sendable {
  public let snapshot: AppSnapshot
  public let conflicts: [MergeConflict]

  public init(snapshot: AppSnapshot, conflicts: [MergeConflict]) {
    self.snapshot = snapshot
    self.conflicts = conflicts
  }
}

/// 用共同基线识别两端变更，不用设备时钟为冲突内容决定胜负。
public enum SnapshotMerger {
  public static func merge(base: AppSnapshot, local: AppSnapshot, remote: AppSnapshot) -> SnapshotMergeResult {
    merging(base: base, local: local, remote: remote, favoring: .local)
  }

  /// 仅改变冲突实体的取舍，仍保留所有不冲突的新增、修改和删除。
  public static func resolve(base: AppSnapshot, local: AppSnapshot, remote: AppSnapshot, favoring: ConflictSide) -> AppSnapshot {
    merging(base: base, local: local, remote: remote, favoring: favoring).snapshot
  }

  private static func merging(base: AppSnapshot, local: AppSnapshot, remote: AppSnapshot,
                              favoring: ConflictSide) -> SnapshotMergeResult {
    let deletions = mergedDeletions(base.deletions + local.deletions + remote.deletions)
    let deletedEntries = Set(deletions.filter { $0.entity == .entry }.map(\.entityID))
    let deletedHabits = Set(deletions.filter { $0.entity == .habit }.map(\.entityID))
    let deletedCheckIns = Set(deletions.filter { $0.entity == .checkIn }.map(\.entityID))
    let deletedHealthSummaries = Set(deletions.filter { $0.entity == .healthSummary }.map(\.entityID))
    let entries = mergeEntities(base: base.entries, local: local.entries, remote: remote.entries, kind: .entry,
                               identifier: { $0.id.uuidString }, deleted: deletedEntries, favoring: favoring)
    let habits = mergeEntities(base: base.habits, local: local.habits, remote: remote.habits, kind: .habit,
                              identifier: { $0.id.uuidString }, deleted: deletedHabits, favoring: favoring)
    let knownHabitIDs = Set((base.habits + local.habits + remote.habits).map { $0.id.uuidString })
    let survivingHabitIDs = Set(habits.values.map { $0.id.uuidString })
    let removedHabitIDs = knownHabitIDs.subtracting(survivingHabitIDs).union(deletedHabits)
    let allCheckIns = base.checkIns + local.checkIns + remote.checkIns
    let clearedCheckIns = Set(allCheckIns.filter { removedHabitIDs.contains($0.habitID.uuidString) }.map(\.id))
    let checkIns = mergeEntities(base: base.checkIns, local: local.checkIns, remote: remote.checkIns, kind: .checkIn,
                                identifier: { $0.id }, deleted: deletedCheckIns.union(clearedCheckIns), favoring: favoring)
    let healthSummaries = mergeEntities(base: base.sharedHealthSummaries, local: local.sharedHealthSummaries,
                                       remote: remote.sharedHealthSummaries, kind: .healthSummary,
                                       identifier: { $0.id.uuidString }, deleted: deletedHealthSummaries, favoring: favoring)
    // 未支持的版本继续携带到输出，后续校验会拒绝，避免静默降级后覆盖文件。
    let schemaVersion = [local.schemaVersion, remote.schemaVersion, base.schemaVersion].first(where: { $0 != 1 }) ?? 1
    let snapshot = AppSnapshot(schemaVersion: schemaVersion, entries: entries.values, habits: habits.values,
                               checkIns: checkIns.values, deletions: deletions, sharedHealthSummaries: healthSummaries.values)
    let conflicts = (entries.conflicts + habits.conflicts + checkIns.conflicts + healthSummaries.conflicts).sorted { $0.id < $1.id }
    return SnapshotMergeResult(snapshot: snapshot, conflicts: conflicts)
  }

  private static func mergeEntities<Value: Equatable>(base: [Value], local: [Value], remote: [Value], kind: EntityKind,
                                                       identifier: (Value) -> String, deleted: Set<String>,
                                                       favoring: ConflictSide) -> (values: [Value], conflicts: [MergeConflict]) {
    func indexed(_ items: [Value]) -> [String: Value] {
      var result: [String: Value] = [:]
      for item in items { result[identifier(item)] = item }
      return result
    }
    let baseValues = indexed(base)
    let localValues = indexed(local)
    let remoteValues = indexed(remote)
    let identifiers = Set(baseValues.keys).union(localValues.keys).union(remoteValues.keys).subtracting(deleted).sorted()
    var values: [Value] = []
    var conflicts: [MergeConflict] = []
    for id in identifiers {
      let baseline = baseValues[id]
      let localValue = localValues[id]
      let remoteValue = remoteValues[id]
      let chosen: Value?
      if localValue == remoteValue { chosen = localValue }
      else if localValue == baseline { chosen = remoteValue }
      else if remoteValue == baseline { chosen = localValue }
      else {
        conflicts.append(MergeConflict(entity: kind, entityID: id))
        chosen = favoring == .local ? localValue : remoteValue
      }
      if let chosen { values.append(chosen) }
    }
    return (values, conflicts)
  }

  private static func mergedDeletions(_ records: [DeletionRecord]) -> [DeletionRecord] {
    var indexed: [String: DeletionRecord] = [:]
    for record in records {
      // 同一删除事件的日期只作元数据；保留最早标记使集合合并满足交换律。
      if let existing = indexed[record.id], existing.deletedAt <= record.deletedAt { continue }
      indexed[record.id] = record
    }
    return indexed.values.sorted { $0.id < $1.id }
  }
}

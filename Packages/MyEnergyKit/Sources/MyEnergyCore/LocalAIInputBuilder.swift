import Foundation

/// 将当天记录整理为有界事实，不把用户自由文本或健康历史交给模型。
public enum DailyReflectionInputBuilder {
  public static func build(snapshot source: AppSnapshot, day: Date = Date(), timeZone: TimeZone = .current) throws -> DailyReflectionInput {
    guard day.timeIntervalSinceReferenceDate.isFinite else { throw LocalAIError.invalidInput("复盘日期无效。") }
    let snapshot: AppSnapshot
    do { snapshot = try source.validated() }
    catch { throw LocalAIError.invalidInput("本机记录未通过验证。") }
    let dayKey = DateRules.dayKey(for: day, timeZone: timeZone)
    guard DateRules.isValidDayKey(dayKey) else { throw LocalAIError.invalidInput("复盘日期超出范围。") }
    let removedEntries = deletedIDs(.entry, in: snapshot)
    let removedHabits = deletedIDs(.habit, in: snapshot)
    let removedCheckIns = deletedIDs(.checkIn, in: snapshot)
    let removedSleep = deletedIDs(.sleep, in: snapshot)

    let allEntries = snapshot.entries.filter {
      !removedEntries.contains($0.id.uuidString) && $0.occurredAt <= day
        && DateRules.dayKey(for: $0.occurredAt, timeZone: timeZone) == dayKey
    }.sorted {
      if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
      return $0.id.uuidString < $1.id.uuidString
    }
    // 汇总统计覆盖全天，明细只保留最近三条，减少小模型的重复引用与上下文负担。
    let entries = Array(allEntries.suffix(3))
    let habits = snapshot.habits.filter {
      !$0.isArchived && !removedHabits.contains($0.id.uuidString) && $0.createdAt <= day
    }.sorted { $0.id.uuidString < $1.id.uuidString }
    let checkIns = snapshot.checkIns.filter {
      $0.dayKey == dayKey && !removedCheckIns.contains($0.id)
    }
    let completed = Set(checkIns.filter(\.isComplete).map(\.habitID))
    let sleeps = snapshot.sleepRecords.filter {
      !removedSleep.contains($0.id.uuidString) && $0.wakeTime <= day
        && DateRules.dayKey(for: $0.wakeTime, timeZone: timeZone) == dayKey
    }.sorted {
      if $0.durationHours != $1.durationHours { return $0.durationHours > $1.durationHours }
      if $0.wakeTime != $1.wakeTime { return $0.wakeTime > $1.wakeTime }
      return $0.id.uuidString < $1.id.uuidString
    }

    var facts: [DailyReflectionFact] = []
    var missingData: [String] = []
    if !allEntries.isEmpty {
      let average = Double(allEntries.reduce(0) { $0 + $1.energy }) / Double(allEntries.count)
      let value = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), average)
      let minimum = allEntries.map(\.energy).min() ?? 0
      let maximum = allEntries.map(\.energy).max() ?? 0
      facts.append(.init(id: "energy_summary",
        statement: "当天全部 \(allEntries.count) 条主观精力自评：均值 \(value)/100，范围 \(minimum)～\(maximum)。"))
    }
    for (index, entry) in entries.enumerated() {
      let mood = entry.mood.map { $0.title } ?? "未填写"
      facts.append(.init(id: "energy_\(index + 1)",
        statement: "\(clock(entry.occurredAt, timeZone: timeZone)) 精力自评 \(entry.energy)/100；心情：\(mood)。"))
    }
    if entries.isEmpty { missingData.append("当天尚无主观精力记录，不能推断精力或心情。") }
    else if !entries.contains(where: { $0.mood != nil }) { missingData.append("所选主观记录均未填写心情，心情未知。") }
    if allEntries.count > entries.count { missingData.append("精力统计覆盖当天全部记录，仅展示最近 3 条明细。") }

    if habits.isEmpty { missingData.append("当前没有活跃习惯，无法比较习惯完成情况。") }
    else {
      let completedCount = habits.filter { completed.contains($0.id) }.count
      facts.append(.init(id: "habit_summary", statement: "当前全部 \(habits.count) 个活跃习惯中，当天标记完成 \(completedCount) 个；未打卡不证明没有行动。"))
    }

    if let primary = sleeps.first {
      let duration = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), primary.durationHours)
      facts.append(.init(id: "sleep_1", statement: "当天结束的手动睡眠共 \(sleeps.count) 段；最长约 \(duration) 小时，只是自述时段估算。"))
    } else { missingData.append("当天尚无已结束的手动睡眠记录，睡眠时长未知。") }
    missingData.append("本次未使用备注、习惯原名、共享健康摘要或原始健康样本；仅凭当天记录不能判断长期趋势或因果。")

    return try DailyReflectionInput(dayKey: dayKey, timeZoneIdentifier: timeZone.identifier,
      facts: facts.sorted { $0.id < $1.id }, missingData: missingData,
      entryCount: entries.count, habitCount: habits.count, manualSleepCount: sleeps.count).validated()
  }

  private static func deletedIDs(_ kind: EntityKind, in snapshot: AppSnapshot) -> Set<String> {
    Set(snapshot.deletions.filter { $0.entity == kind }.map(\.entityID))
  }

  private static func clock(_ date: Date, timeZone: TimeZone) -> String {
    let parts = DateRules.gregorian(timeZone: timeZone).dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", locale: Locale(identifier: "en_US_POSIX"), parts.hour ?? 0, parts.minute ?? 0)
  }
}

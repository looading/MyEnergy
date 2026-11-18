import Foundation
import MyEnergyCore

#if canImport(HealthKit) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
@preconcurrency import HealthKit
#endif

public struct HealthReport: Sendable {
  public var recovery: RecoverySummary
  public var restingHeartRate: Double?
  public var sleepHours: Double?
  public var updatedAt: Date
  public var sourceDescription: String
  public var sleepHistory: [SleepNight]

  public init(
    recovery: RecoverySummary, restingHeartRate: Double? = nil, sleepHours: Double? = nil,
    updatedAt: Date = Date(), sourceDescription: String, sleepHistory: [SleepNight] = []
  ) {
    self.recovery = recovery
    self.restingHeartRate = restingHeartRate
    self.sleepHours = sleepHours
    self.updatedAt = updatedAt
    self.sourceDescription = sourceDescription
    self.sleepHistory = sleepHistory
  }
}

public enum HealthDataError: Error, LocalizedError, Sendable {
  case unavailable
  case authorizationRequestFailed
  case invalidDate

  public var errorDescription: String? {
    switch self {
    case .unavailable: "当前设备不支持读取 Apple Health。"
    case .authorizationRequestFailed: "健康权限请求未完成，请稍后重试。"
    case .invalidDate: "健康查询时间无效。"
    }
  }
}

/// 只读健康适配器；授权请求成功只表示系统完成请求，不能据此判断用户授予了读取权限。
@MainActor
public final class HealthDataClient {
  #if canImport(HealthKit) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
  private let store = HKHealthStore()
  #endif

  public init() {}

  public var isAvailable: Bool {
    #if canImport(HealthKit) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    HKHealthStore.isHealthDataAvailable()
    #else
    false
    #endif
  }

  public func requestReadAccess() async throws {
    guard isAvailable else { throw HealthDataError.unavailable }
    #if canImport(HealthKit) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    let readTypes: Set<HKObjectType> = [
      HKQuantityType(.heartRateVariabilitySDNN), HKQuantityType(.restingHeartRate),
      HKCategoryType(.sleepAnalysis)
    ]
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      store.requestAuthorization(toShare: [], read: readTypes) { completed, error in
        if let error { continuation.resume(throwing: error) }
        else if completed { continuation.resume() }
        else { continuation.resume(throwing: HealthDataError.authorizationRequestFailed) }
      }
    }
    #endif
  }

  /// 不自动弹出授权，也不把空结果解释为“用户拒绝”。摘要仅在本机返回。
  public func fetchReport(now: Date = Date()) async throws -> HealthReport {
    guard now.timeIntervalSince1970.isFinite else { throw HealthDataError.invalidDate }
    guard isAvailable else {
      return HealthReport(
        recovery: RecoveryAnalyzer.analyze(samples: [], now: now), updatedAt: now,
        sourceDescription: "本机无法读取 Apple Health；健康摘要尚未连接。"
      )
    }
    #if canImport(HealthKit) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
    let start = now.addingTimeInterval(-30 * 86_400)
    let hrv = try await quantityReadings(type: HKQuantityType(.heartRateVariabilitySDNN),
      unit: .secondUnit(with: .milli), start: start, end: now)
    let heartRate = try await quantityReadings(type: HKQuantityType(.restingHeartRate),
      unit: .count().unitDivided(by: .minute()), start: start, end: now)
    let sleep = try await sleepReadings(start: start, end: now)
    let resting = heartRate.filter {
      $0.value.isFinite && $0.value > 0 && $0.date <= now && now.timeIntervalSince($0.date) <= 86_400
    }.max(by: { $0.date < $1.date })?.value
    let samples = hrv.map { HRVSample(valueMS: $0.value, date: $0.date) }
    let recovery = RecoveryAnalyzer.analyze(samples: samples, now: now)
    let sleepHistory = HealthSleepAnalyzer.nights(intervals: sleep, now: now)
    let hours = SleepNight.latestPrimary(in: sleepHistory)?.durationHours
    let hasData = !samples.isEmpty || resting != nil || hours != nil
    return HealthReport(
      recovery: recovery, restingHeartRate: resting, sleepHours: hours, updatedAt: now,
      sourceDescription: hasData
        ? "Apple Health · HRV SDNN、静息心率与睡眠；仅作个人历史参考。"
        : "Apple Health 暂无可读取样本；可能尚未记录或未开放读取权限。",
      sleepHistory: sleepHistory
    )
    #else
    return HealthReport(
      recovery: RecoveryAnalyzer.analyze(samples: [], now: now), updatedAt: now,
      sourceDescription: "本机无法读取 Apple Health。"
    )
    #endif
  }

  #if canImport(HealthKit) && (os(iOS) || os(watchOS)) && !targetEnvironment(macCatalyst)
  private struct QuantityReading: Sendable {
    let value: Double
    let date: Date
  }

  private func quantityReadings(type: HKQuantityType, unit: HKUnit, start: Date, end: Date) async throws
    -> [QuantityReading] {
    try await withCheckedThrowingContinuation { continuation in
      let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
      let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
        sortDescriptors: nil) { _, samples, error in
        if let error { continuation.resume(throwing: error); return }
        let values = (samples as? [HKQuantitySample] ?? []).compactMap { sample -> QuantityReading? in
          let value = sample.quantity.doubleValue(for: unit)
          guard value.isFinite, value > 0, sample.endDate <= end,
            sample.endDate.timeIntervalSince1970.isFinite else { return nil }
          return QuantityReading(value: value, date: sample.endDate)
        }
        continuation.resume(returning: values)
      }
      store.execute(query)
    }
  }

  private func sleepReadings(start: Date, end: Date) async throws -> [HealthSleepInterval] {
    try await withCheckedThrowingContinuation { continuation in
      let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictEndDate])
      let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
        limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
        if let error { continuation.resume(throwing: error); return }
        let asleepValues = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let intervals = (samples as? [HKCategorySample] ?? []).map {
          HealthSleepInterval(start: $0.startDate, end: $0.endDate, isAsleep: asleepValues.contains($0.value))
        }
        continuation.resume(returning: intervals)
      }
      store.execute(query)
    }
  }
  #endif
}

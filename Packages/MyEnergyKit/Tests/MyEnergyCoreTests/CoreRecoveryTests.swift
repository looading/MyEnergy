import Foundation
import Testing
@testable import MyEnergyCore

@Suite("Historical HRV comparison")
struct CoreRecoveryTests {
  private let now = Date(timeIntervalSince1970: 1_763_467_200) // fixed UTC noon
  private let day: TimeInterval = 86_400

  @Test func emptyInvalidAndFutureSamplesAreUnavailable() {
    let samples = [
      HRVSample(valueMS: 0, date: now), HRVSample(valueMS: -10, date: now),
      HRVSample(valueMS: .nan, date: now), HRVSample(valueMS: .infinity, date: now),
      HRVSample(valueMS: 50, date: now.addingTimeInterval(1)),
      HRVSample(valueMS: 50, date: Date(timeIntervalSinceReferenceDate: .nan))
    ]
    let summary = RecoveryAnalyzer.analyze(samples: samples, now: now)
    #expect(summary.status == .unavailable)
    #expect(summary.latestMS == nil)
    #expect(summary.baselineMS == nil)
    #expect(summary.changePercent == nil)
    #expect(summary.historyDays == 0)
  }

  @Test func sevenHistoricalDaysAreRequiredRatherThanSevenMeasurements() {
    let manySameDay = (0..<20).map { HRVSample(valueMS: Double(30 + $0), date: now.addingTimeInterval(-2 * day - Double($0))) }
    let summary = RecoveryAnalyzer.analyze(samples: manySameDay + [HRVSample(valueMS: 60, date: now)], now: now)
    #expect(summary.status == .insufficientHistory)
    #expect(summary.historyDays == 1)
    #expect(summary.baselineMS == nil)
    #expect(summary.changePercent == nil)
  }

  @Test func medianOfDailyMediansDoesNotOverweightBusySamplingDays() {
    var samples: [HRVSample] = []
    for offset in 2...8 {
      samples.append(HRVSample(valueMS: Double(offset * 10), date: now.addingTimeInterval(-Double(offset) * day + 3_600)))
    }
    // The first historical day's three values have a median of 20; the outlier does not shift the baseline.
    samples.append(HRVSample(valueMS: 1, date: now.addingTimeInterval(-2 * day + 7_200)))
    samples.append(HRVSample(valueMS: 1_000, date: now.addingTimeInterval(-2 * day + 10_800)))
    samples.append(HRVSample(valueMS: 75, date: now))
    let summary = RecoveryAnalyzer.analyze(samples: Array(samples.reversed()), now: now)
    #expect(summary.status == .ready)
    #expect(summary.historyDays == 7)
    #expect(summary.latestMS == 75)
    #expect(summary.baselineMS == 50)
    #expect(summary.changePercent == 50)
    #expect(summary.sampledAt == now)
  }

  @Test func historyWindowExcludesRecentTwentyFourHoursAndOldSamples() {
    let history = (2...7).map { HRVSample(valueMS: 50, date: now.addingTimeInterval(-Double($0) * day)) }
    let samples = history + [
      HRVSample(valueMS: 999, date: now.addingTimeInterval(-day)),
      HRVSample(valueMS: 999, date: now.addingTimeInterval(-3_600)),
      HRVSample(valueMS: 999, date: now.addingTimeInterval(-30 * day - 1)),
      HRVSample(valueMS: 50, date: now.addingTimeInterval(-30 * day)),
      HRVSample(valueMS: 60, date: now)
    ]
    let summary = RecoveryAnalyzer.analyze(samples: samples, now: now)
    #expect(summary.historyDays == 7)
    #expect(summary.baselineMS == 50)
    #expect(summary.status == .ready)
    #expect(summary.changePercent == 20)
  }

  @Test func latestExactlyTwentyFourHoursOldIsFreshAndOlderIsStale() {
    let atBoundary = RecoveryAnalyzer.analyze(samples: [HRVSample(valueMS: 45, date: now.addingTimeInterval(-day))], now: now)
    #expect(atBoundary.status == .insufficientHistory)
    #expect(atBoundary.historyDays == 0)
    let older = RecoveryAnalyzer.analyze(samples: [HRVSample(valueMS: 45, date: now.addingTimeInterval(-day - 1))], now: now)
    #expect(older.status == .stale)
    #expect(older.latestMS == 45)
    #expect(older.sampledAt == now.addingTimeInterval(-day - 1))
  }
}

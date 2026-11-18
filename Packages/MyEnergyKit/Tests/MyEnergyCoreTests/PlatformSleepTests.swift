import Foundation
import XCTest
import MyEnergyCore
@testable import MyEnergyPlatform

final class PlatformSleepTests: XCTestCase {
  private let utc = TimeZone(secondsFromGMT: 0)!

  private func date(_ value: String) throws -> Date {
    try XCTUnwrap(ISO8601DateFormatter().date(from: value))
  }

  private func asleep(_ start: Date, _ end: Date) -> HealthSleepInterval {
    HealthSleepInterval(start: start, end: end, isAsleep: true)
  }

  func testNightsUnionDuplicateAndOverlappingSourcesAndExcludeAwakeOrInBed() throws {
    let start = try date("2026-11-17T22:00:00Z")
    let end = start.addingTimeInterval(10 * 3_600)
    let intervals = [
      asleep(start, start.addingTimeInterval(3 * 3_600)),
      asleep(start, start.addingTimeInterval(3 * 3_600)),
      asleep(start.addingTimeInterval(2 * 3_600), start.addingTimeInterval(5 * 3_600)),
      HealthSleepInterval(start: start, end: end, isAsleep: false),
      HealthSleepInterval(start: start.addingTimeInterval(5 * 3_600), end: end, isAsleep: false),
      asleep(start.addingTimeInterval(7 * 3_600), start.addingTimeInterval(8 * 3_600))
    ]
    let nights = HealthSleepAnalyzer.nights(intervals: intervals, now: end, timeZone: utc)
    let night = try XCTUnwrap(nights.first)
    XCTAssertEqual(nights.count, 1)
    XCTAssertEqual(night.bedtime, start)
    XCTAssertEqual(night.wakeTime, start.addingTimeInterval(8 * 3_600))
    XCTAssertEqual(night.asleepSeconds, 6 * 3_600)
    XCTAssertEqual(night.dayKey, "2026-11-18")
    XCTAssertEqual(night.sourceDescription, "Apple 健康")
    XCTAssertEqual(HealthSleepAnalyzer.nights(intervals: Array(intervals.reversed()), now: end, timeZone: utc), nights)
  }

  func testThreeHourGapGroupsButLongerGapStartsNewEpisodeAndKeepsChronologicalOrder() throws {
    let start = try date("2026-11-18T00:00:00Z")
    let first = asleep(start, start.addingTimeInterval(3_600))
    let boundary = asleep(start.addingTimeInterval(4 * 3_600), start.addingTimeInterval(5 * 3_600))
    let separate = asleep(start.addingTimeInterval(8 * 3_600 + 1), start.addingTimeInterval(9 * 3_600))
    let nights = HealthSleepAnalyzer.nights(intervals: [separate, boundary, first],
                                            now: start.addingTimeInterval(10 * 3_600), timeZone: utc)
    XCTAssertEqual(nights.count, 2)
    XCTAssertEqual(nights[0].asleepSeconds, 2 * 3_600)
    XCTAssertEqual(nights[0].wakeTime, boundary.end)
    XCTAssertEqual(nights[1].bedtime, separate.start)
  }

  func testInvalidFutureAndUnfinishedIntervalsNeverBecomeNights() throws {
    let now = try date("2026-11-18T10:00:00Z")
    let valid = asleep(now.addingTimeInterval(-2 * 3_600), now.addingTimeInterval(-3_600))
    let invalid: [HealthSleepInterval] = [
      asleep(now.addingTimeInterval(-3_600), now.addingTimeInterval(3_600)),
      asleep(now.addingTimeInterval(3_600), now.addingTimeInterval(7_200)),
      asleep(now, now), asleep(now, now.addingTimeInterval(-1)),
      asleep(Date(timeIntervalSince1970: .nan), now),
      asleep(now.addingTimeInterval(-3_600), Date(timeIntervalSince1970: .infinity)),
      asleep(now.addingTimeInterval(-26 * 3_600), now.addingTimeInterval(-3_600))
    ]
    XCTAssertTrue(HealthSleepAnalyzer.nights(intervals: invalid, now: now, timeZone: utc).isEmpty)
    let nights = HealthSleepAnalyzer.nights(intervals: invalid + [valid], now: now, timeZone: utc)
    XCTAssertEqual(nights.count, 1)
    XCTAssertEqual(nights.first?.durationHours, 1)
    XCTAssertTrue(HealthSleepAnalyzer.nights(intervals: [valid], now: Date(timeIntervalSince1970: .nan), timeZone: utc).isEmpty)
  }

  func testImplausiblyLongGroupedEpisodeIsNotClippedIntoInventedNight() throws {
    let start = try date("2026-11-16T00:00:00Z")
    let intervals = [
      asleep(start, start.addingTimeInterval(12 * 3_600)),
      asleep(start.addingTimeInterval(14 * 3_600), start.addingTimeInterval(26 * 3_600))
    ]
    XCTAssertTrue(HealthSleepAnalyzer.nights(intervals: intervals,
      now: start.addingTimeInterval(30 * 3_600), timeZone: utc).isEmpty)
  }

  func testWakeDateUsesRequestedTimeZoneAndElapsedTimeAcrossBothDSTTransitions() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    for (startText, endText, hours, key) in [
      ("2026-03-08T06:00:00Z", "2026-03-08T12:00:00Z", 6.0, "2026-03-08"),
      ("2026-11-01T04:00:00Z", "2026-11-01T12:00:00Z", 8.0, "2026-11-01")
    ] {
      let start = try date(startText)
      let end = try date(endText)
      let night = try XCTUnwrap(HealthSleepAnalyzer.nights(intervals: [asleep(start, end)],
        now: end, timeZone: zone).first)
      XCTAssertEqual(night.durationHours, hours)
      XCTAssertEqual(night.dayKey, key)
    }
    let start = try date("2026-11-17T16:30:00Z")
    let end = try date("2026-11-18T00:30:00Z")
    let california = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    XCTAssertEqual(HealthSleepAnalyzer.nights(intervals: [asleep(start, end)], now: end, timeZone: utc).first?.dayKey, "2026-11-18")
    XCTAssertEqual(HealthSleepAnalyzer.nights(intervals: [asleep(start, end)], now: end, timeZone: california).first?.dayKey, "2026-11-17")
  }

  func testLatestPrimarySelectsLongestEpisodeOfLatestDateInsteadOfAfternoonNap() throws {
    let start = try date("2026-11-17T23:00:00Z")
    let night = asleep(start, start.addingTimeInterval(8 * 3_600))
    let nap = asleep(start.addingTimeInterval(15 * 3_600), start.addingTimeInterval(16 * 3_600))
    let older = asleep(start.addingTimeInterval(-24 * 3_600), start.addingTimeInterval(-14 * 3_600))
    let nights = HealthSleepAnalyzer.nights(intervals: [nap, older, night],
      now: start.addingTimeInterval(18 * 3_600), timeZone: utc)
    XCTAssertEqual(nights.count, 3)
    let primary = try XCTUnwrap(SleepNight.latestPrimary(in: nights))
    XCTAssertEqual(primary.durationHours, 8)
    XCTAssertEqual(primary.wakeTime, night.end)
    XCTAssertEqual(primary.dayKey, "2026-11-18")
    XCTAssertEqual(SleepNight.latestPrimary(in: Array(nights.reversed())), primary)
    XCTAssertNil(SleepNight.latestPrimary(in: []))
  }

  func testLatestPrimaryDurationTieUsesLaterEndOnSameDate() throws {
    let start = try date("2026-11-18T00:00:00Z")
    let first = try SleepNight(bedtime: start, wakeTime: start.addingTimeInterval(3_600), asleepSeconds: 3_600,
                              timeZoneIdentifier: "GMT", sourceDescription: "Apple 健康")
    let later = try SleepNight(bedtime: start.addingTimeInterval(5 * 3_600), wakeTime: start.addingTimeInterval(6 * 3_600),
                              asleepSeconds: 3_600, timeZoneIdentifier: "GMT", sourceDescription: "Apple 健康")
    XCTAssertEqual(SleepNight.latestPrimary(in: [later, first]), later)
  }

  func testHealthReportKeepsOldInitializerAndDefaultsRawHistoryToEmpty() {
    let report = HealthReport(recovery: RecoverySummary(status: .unavailable), sleepHours: 8, sourceDescription: "旧摘要")
    XCTAssertEqual(report.sleepHours, 8)
    XCTAssertTrue(report.sleepHistory.isEmpty)
  }
}

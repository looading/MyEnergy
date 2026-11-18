import Foundation
import XCTest
@testable import MyEnergyPlatform

final class PlatformHealthTests: XCTestCase {
  private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

  func testSleepUnionsOverlappingSourcesWithoutAddingInBedOrAwake() {
    let window = DateInterval(start: epoch, duration: 10 * 3_600)
    let samples = [
      HealthSleepInterval(start: epoch, end: epoch.addingTimeInterval(8 * 3_600), isAsleep: false),
      HealthSleepInterval(start: epoch.addingTimeInterval(3_600), end: epoch.addingTimeInterval(4 * 3_600), isAsleep: true),
      HealthSleepInterval(start: epoch.addingTimeInterval(2 * 3_600), end: epoch.addingTimeInterval(5 * 3_600), isAsleep: true),
      HealthSleepInterval(start: epoch.addingTimeInterval(5 * 3_600), end: epoch.addingTimeInterval(6 * 3_600), isAsleep: false),
      HealthSleepInterval(start: epoch.addingTimeInterval(6 * 3_600), end: epoch.addingTimeInterval(7 * 3_600), isAsleep: true)
    ]
    XCTAssertEqual(HealthSleepAnalyzer.asleepSeconds(intervals: samples, within: window), 5 * 3_600)
  }

  func testSleepClipsBoundariesAndRejectsInvalidIntervals() {
    let samples = [
      HealthSleepInterval(start: epoch.addingTimeInterval(-3_600), end: epoch.addingTimeInterval(3_600), isAsleep: true),
      HealthSleepInterval(start: epoch.addingTimeInterval(7_200), end: epoch.addingTimeInterval(18_000), isAsleep: true),
      HealthSleepInterval(start: epoch.addingTimeInterval(7_200), end: epoch, isAsleep: true),
      HealthSleepInterval(start: Date(timeIntervalSince1970: .nan), end: epoch, isAsleep: true)
    ]
    XCTAssertEqual(HealthSleepAnalyzer.asleepSeconds(intervals: samples,
      within: DateInterval(start: epoch, duration: 10_800)), 7_200)
  }

  func testLatestSleepDoesNotUseStaleFutureOrInBedSamples() {
    let intervals = [
      HealthSleepInterval(start: epoch.addingTimeInterval(-60 * 3_600), end: epoch.addingTimeInterval(-40 * 3_600), isAsleep: true),
      HealthSleepInterval(start: epoch.addingTimeInterval(-3_600), end: epoch.addingTimeInterval(3_600), isAsleep: true),
      HealthSleepInterval(start: epoch.addingTimeInterval(-3_600), end: epoch, isAsleep: false)
    ]
    XCTAssertNil(HealthSleepAnalyzer.latestNightHours(intervals: intervals, now: epoch,
      timeZone: TimeZone(secondsFromGMT: 0)!))
  }

  func testSleepUsesLocalCalendarAcrossDaylightSavingBoundary() throws {
    let formatter = ISO8601DateFormatter()
    let start = try XCTUnwrap(formatter.date(from: "2026-11-01T04:00:00Z"))
    let end = try XCTUnwrap(formatter.date(from: "2026-11-01T12:00:00Z"))
    let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let hours = HealthSleepAnalyzer.latestNightHours(
      intervals: [HealthSleepInterval(start: start, end: end, isAsleep: true)],
      now: end.addingTimeInterval(3_600), timeZone: zone)
    XCTAssertEqual(try XCTUnwrap(hours), 8, accuracy: 0.0001)
  }

  #if os(macOS)
  @MainActor
  func testMacReturnsUnavailableWithoutRequestingHealthAuthorization() async throws {
    let client = HealthDataClient()
    XCTAssertFalse(client.isAvailable)
    let report = try await client.fetchReport(now: epoch)
    XCTAssertEqual(report.recovery.status, .unavailable)
    XCTAssertNil(report.restingHeartRate)
    XCTAssertNil(report.sleepHours)
    XCTAssertEqual(report.updatedAt, epoch)
  }
  #endif
}

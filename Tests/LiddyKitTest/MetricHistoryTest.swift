import XCTest
@testable import LiddyKit

final class MetricHistoryTest: XCTestCase {
    private func sample(_ index: Int) -> MetricSample {
        MetricSample(
            at: Date(timeIntervalSince1970: TimeInterval(index)),
            leaseCount: index,
            batteryPercent: 50,
            thermalRank: 0,
            isHeld: true)
    }

    /// The ring must drop the oldest, not the newest — a sparkline that stops updating
    /// after 15 minutes would be worse than no sparkline.
    func testOverflowDropsOldestFirst() {
        let history = MetricHistory(capacity: 3)
        for index in 0..<5 { history.append(sample(index)) }
        XCTAssertEqual(history.sample.count, 3)
        XCTAssertEqual(history.sample.map(\.leaseCount), [2, 3, 4])
    }

    func testRecentReturnsTheTail() {
        let history = MetricHistory(capacity: 10)
        for index in 0..<6 { history.append(sample(index)) }
        XCTAssertEqual(history.recent(limit: 2).map(\.leaseCount), [4, 5])
    }

    func testRecentBeyondCountReturnsEverything() {
        let history = MetricHistory(capacity: 10)
        for index in 0..<3 { history.append(sample(index)) }
        XCTAssertEqual(history.recent(limit: 99).count, 3)
    }

    func testCapacityIsNeverZero() {
        let history = MetricHistory(capacity: 0)
        history.append(sample(1))
        XCTAssertEqual(history.sample.count, 1)
    }

    func testClearEmptiesIt() {
        let history = MetricHistory(capacity: 4)
        history.append(sample(1))
        history.clear()
        XCTAssertTrue(history.sample.isEmpty)
    }
}

final class SnapshotDisplayTest: XCTestCase {
    func testTimerFractionIsNilWithoutATimer() {
        let snapshot = RuntimeSnapshot(startedAt: Date(), expiresAt: nil)
        XCTAssertNil(snapshot.timerFraction)
    }

    func testTimerFractionIsHalfwayThrough() {
        let start = Date().addingTimeInterval(-50)
        let end = Date().addingTimeInterval(50)
        let fraction = RuntimeSnapshot(startedAt: start, expiresAt: end).timerFraction
        XCTAssertNotNil(fraction)
        XCTAssertEqual(fraction ?? 0, 0.5, accuracy: 0.02)
    }

    /// A ring drawn past its own end would render as an overfull circle.
    func testTimerFractionClampsAtOne() {
        let snapshot = RuntimeSnapshot(
            startedAt: Date().addingTimeInterval(-100),
            expiresAt: Date().addingTimeInterval(-10))
        XCTAssertEqual(snapshot.timerFraction, 1)
    }

    func testRemainingSecondNeverGoesNegative() {
        let snapshot = RuntimeSnapshot(expiresAt: Date().addingTimeInterval(-60))
        XCTAssertEqual(snapshot.remainingSecond, 0)
    }
}

/// The countdown label. Pure, and previously wrong in two ways at once: the ring
/// carried a variable-length string that made SwiftUI rescale the type mid-countdown
/// (which moved the glyph vertically every few seconds), and the hour format dropped
/// the leading zero — 8h00m rendered as "8h0".
final class RemainingDisplayTest: XCTestCase {
    private func snapshot(remaining: Int) -> RuntimeSnapshot {
        RuntimeSnapshot(
            startedAt: Date().addingTimeInterval(-60),
            expiresAt: Date().addingTimeInterval(TimeInterval(remaining)))
    }

    private func display(_ remaining: Int) -> RuntimeSnapshot.RemainingDisplay? {
        snapshot(remaining: remaining).remainingDisplay
    }

    func testNilWithoutATimer() {
        XCTAssertNil(RuntimeSnapshot(startedAt: Date()).remainingDisplay)
    }

    /// The property the ring depends on: the value never grows past two characters, so
    /// it can never trigger the scaling that caused the drift.
    func testRingValueIsNeverWiderThanTwoDigits() {
        for remaining in stride(from: 0, through: 8 * 3600, by: 37) {
            guard let shown = display(remaining) else { continue }
            XCTAssertLessThanOrEqual(
                shown.value.count, 2,
                "\(remaining)s produced \"\(shown.value)\", which is wide enough to force a rescale")
            XCTAssertEqual(shown.unit.count, 1)
        }
    }

    func testHourCaptionIsZeroPadded() {
        XCTAssertEqual(display(8 * 3600)?.caption, "8h 00m left")
        XCTAssertEqual(display(7 * 3600 + 5 * 60)?.caption, "7h 05m left")
        XCTAssertEqual(display(3600 + 60)?.caption, "1h 01m left")
    }

    func testHourRingDropsToTheHour() {
        XCTAssertEqual(display(7 * 3600 + 59 * 60).map { $0.value + $0.unit }, "7h")
        XCTAssertEqual(display(8 * 3600).map { $0.value + $0.unit }, "8h")
    }

    func testMinuteRing() {
        XCTAssertEqual(display(59 * 60).map { $0.value + $0.unit }, "59m")
        XCTAssertEqual(display(10 * 60).map { $0.value + $0.unit }, "10m")
    }

    /// Ring and caption must not contradict each other. The first cut showed "1m" in
    /// the ring beside "0m left" underneath.
    func testTheLastMinuteAgreesWithItself() {
        let shown = display(45)
        XCTAssertEqual(shown?.value, "1", "still holding, so not zero")
        XCTAssertEqual(shown?.caption, "under a minute left")
    }

    func testExpiryReadsAsReleasing() {
        XCTAssertEqual(display(0)?.caption, "releasing")
    }
}

final class BatteryDisplayTest: XCTestCase {
    func testRemainingIsFormattedAsHourAndMinute() {
        let battery = BatteryReading(percent: 55, isCharging: false, isOnMain: false, minuteRemaining: 185)
        XCTAssertEqual(battery.remainingDisplay, "3:05")
        XCTAssertEqual(battery.sourceDisplay, "3:05 left")
    }

    func testChargingSaysToFull() {
        let battery = BatteryReading(percent: 55, isCharging: true, isOnMain: true, minuteRemaining: 65)
        XCTAssertEqual(battery.sourceDisplay, "1:05 to full")
    }

    /// IOKit reports -1 while it is still estimating; the menu must not print it.
    func testNoEstimateFallsBackToThePowerSource() {
        let battery = BatteryReading(percent: 55, isCharging: false, isOnMain: false, minuteRemaining: nil)
        XCTAssertNil(battery.remainingDisplay)
        XCTAssertEqual(battery.sourceDisplay, "on battery")
    }

    func testDesktopMacReadsAsAcPower() {
        XCTAssertEqual(BatteryReading.unknown.sourceDisplay, "AC power")
    }
}

final class SettingCompatibilityTest: XCTestCase {
    /// The trap this decoder exists to avoid: a config written by an older build is
    /// missing the newest key, and a strict decode would throw — which `Setting.load()`
    /// swallows into `.default`, silently resetting every threshold the user tuned.
    func testConfigWithoutTheNewestKeyKeepsItsOtherValues() throws {
        let legacy = Data("""
        {
          "softBatteryPercent": 35,
          "hardBatteryPercent": 6,
          "thermalCeiling": "serious",
          "idleReleaseSecond": 900,
          "isChargingOnly": true,
          "watchPattern": ["cargo"]
        }
        """.utf8)
        let setting = try JSONDecoder().decode(Setting.self, from: legacy)
        XCTAssertEqual(setting.softBatteryPercent, 35)
        XCTAssertEqual(setting.hardBatteryPercent, 6)
        XCTAssertEqual(setting.thermalCeiling, .serious)
        XCTAssertEqual(setting.idleReleaseSecond, 900)
        XCTAssertTrue(setting.isChargingOnly)
        XCTAssertEqual(setting.watchPattern, ["cargo"])
        XCTAssertTrue(setting.isNetworkProbeOn, "a missing key should take the default, not false")
    }

    func testEmptyObjectDecodesToTheDefault() throws {
        let setting = try JSONDecoder().decode(Setting.self, from: Data("{}".utf8))
        XCTAssertEqual(setting, .default)
    }

    func testRoundTripsThroughItsOwnEncoder() throws {
        var setting = Setting.default
        setting.isNetworkProbeOn = false
        let data = try JSONEncoder().encode(setting)
        XCTAssertEqual(try JSONDecoder().decode(Setting.self, from: data), setting)
    }

    func testPatchLeavesUntouchedFieldsAlone() {
        let patched = SettingPatch(isNetworkProbeOn: false).applied(to: .default)
        XCTAssertFalse(patched.isNetworkProbeOn)
        XCTAssertEqual(patched.softBatteryPercent, Setting.default.softBatteryPercent)
        XCTAssertEqual(patched.watchPattern, Setting.default.watchPattern)
    }
}

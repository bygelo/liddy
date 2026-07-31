import XCTest
@testable import LiddyKit

/// The governor decides whether an overnight run survives, so its rules are tested
/// directly rather than inferred from the app behaving plausibly.
final class SafetyGovernorTest: XCTestCase {
    private let governor = SafetyGovernor(setting: .default)

    private func battery(_ percent: Int?, onMain: Bool = false) -> BatteryReading {
        BatteryReading(percent: percent, isCharging: onMain, isOnMain: onMain)
    }

    func testProceedOnHealthyBatteryAndTemperature() {
        let verdict = governor.evaluate(
            battery: battery(80),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: true
        )
        XCTAssertEqual(verdict, .proceed)
    }

    func testSoftFloorReleasesBeforeHardFloorForcesSleep() {
        let soft = governor.evaluate(
            battery: battery(18),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: true
        )
        XCTAssertEqual(soft, .release(.batteryFloor))

        let hard = governor.evaluate(
            battery: battery(3),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: true
        )
        XCTAssertEqual(hard, .forceSleep(.batteryFloor))
    }

    /// A battery floor must never fire while the Mac is plugged in — that would end
    /// runs on a machine that is charging past the threshold.
    func testBatteryFloorIsIgnoredOnMainPower() {
        let verdict = governor.evaluate(
            battery: battery(3, onMain: true),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: true
        )
        XCTAssertEqual(verdict, .proceed)
    }

    /// Critical heat with the lid shut has no airflow, so releasing our own assertion
    /// is not enough — something else holding one would keep the machine cooking.
    func testCriticalHeatForcesSleepOnlyWithLidClosed() {
        XCTAssertEqual(
            governor.evaluate(battery: battery(90), thermal: ThermalReading(level: .critical), isClamshellActive: true),
            .forceSleep(.thermalCritical)
        )
        XCTAssertEqual(
            governor.evaluate(battery: battery(90), thermal: ThermalReading(level: .critical), isClamshellActive: false),
            .release(.thermalCritical)
        )
    }

    func testSeriousHeatWarnsWithoutStopping() {
        let verdict = governor.evaluate(
            battery: battery(90),
            thermal: ThermalReading(level: .serious),
            isClamshellActive: true
        )
        XCTAssertFalse(verdict.isStop)
        if case .warn = verdict {} else { XCTFail("expected a warning, got \(verdict)") }
    }

    /// A desktop with no battery reports nil, which must never read as 0%.
    func testMissingBatteryNeverTripsAFloor() {
        let verdict = governor.evaluate(
            battery: battery(nil, onMain: true),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: true
        )
        XCTAssertEqual(verdict, .proceed)
    }

    func testChargingOnlyReleasesOnBattery() {
        var setting = Setting.default
        setting.isChargingOnly = true
        let verdict = SafetyGovernor(setting: setting).evaluate(
            battery: battery(90),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: false
        )
        XCTAssertEqual(verdict, .release(.userStopped))
    }

    /// A hand-edited config must not be able to disable a floor by inverting it.
    func testSettingNormalizationKeepsSoftFloorAboveHardFloor() {
        let broken = Setting(
            softBatteryPercent: 2,
            hardBatteryPercent: 99,
            thermalCeiling: .critical,
            idleReleaseSecond: 1,
            isChargingOnly: false,
            watchPattern: []
        ).normalized()

        XCTAssertTrue(Setting.hardBatteryRange.contains(broken.hardBatteryPercent))
        XCTAssertTrue(Setting.softBatteryRange.contains(broken.softBatteryPercent))
        XCTAssertGreaterThan(broken.softBatteryPercent, broken.hardBatteryPercent)
        XCTAssertGreaterThanOrEqual(broken.idleReleaseSecond, 30)
    }
}

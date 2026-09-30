import XCTest
@testable import LiddyKit

final class AppInstallTest: XCTestCase {
    func testApplicationsPathIsOk() {
        let check = AppInstall.healthCheck(bundlePath: "/Applications/Liddy.app")
        XCTAssertEqual(check.id, "liddy.install")
        XCTAssertEqual(check.state, .ok)
        XCTAssertEqual(check.detail, AppInstall.applicationsPath)
    }

    func testNestedPathInsideTheBundleStillCounts() {
        XCTAssertTrue(AppInstall.isInApplications("/Applications/Liddy.app/Contents/MacOS/Liddy"))
        XCTAssertEqual(
            AppInstall.healthCheck(bundlePath: "/Applications/Liddy.app/Contents/MacOS").state,
            .ok)
    }

    /// A copy in `dist/` works until you log out. That is the whole bug.
    func testDistBuildIsDegraded() {
        let check = AppInstall.healthCheck(
            bundlePath: "/Users/me/liddy/dist/Liddy.app")
        XCTAssertEqual(check.state, .degraded)
        XCTAssertTrue(check.detail.contains("/Applications"))
    }

    func testSwiftPmBuildIsOffNotBroken() {
        let check = AppInstall.healthCheck(
            bundlePath: "/Users/me/liddy/.build/release/LiddyApp")
        XCTAssertEqual(check.state, .off)
        XCTAssertEqual(check.detail, "dev build")
    }

    func testUnbundledExecutableIsADevBuild() {
        XCTAssertTrue(AppInstall.isDevBuild("/usr/local/bin/liddy"))
        XCTAssertFalse(AppInstall.isDevBuild("/Applications/Liddy.app"))
        XCTAssertFalse(AppInstall.isDevBuild("/tmp/Liddy.app"))
    }

    func testInstallCheckShowsUpInLiddyCheck() {
        let check = HealthProbe.liddyCheck(
            context: HealthContext(isSocketBound: true),
            pmsetText: "",
            bundlePath: "/tmp/Liddy.app")
        XCTAssertEqual(check.first { $0.id == "liddy.install" }?.state, .degraded)
    }
}

final class MenuBarIconTest: XCTestCase {
    func testIdleUsesBoltSlash() {
        let icon = MenuBarIcon(RuntimeSnapshot())
        XCTAssertEqual(icon.symbolName, "bolt.slash")
        XCTAssertTrue(icon.label.hasPrefix("Liddy: idle"))
    }

    func testHoldUsesBolt() {
        let icon = MenuBarIcon(RuntimeSnapshot(isAwakeHeld: true))
        XCTAssertEqual(icon.symbolName, "bolt.fill")
    }

    func testClamshellOutranksAPlainHold() {
        let icon = MenuBarIcon(RuntimeSnapshot(isAwakeHeld: true, isClamshellActive: true))
        XCTAssertEqual(icon.symbolName, "laptopcomputer.slash")
    }

    /// A failing check takes the glyph. Whether the Mac is awake is visible
    /// everywhere; that the helper died is visible nowhere else.
    func testDownHealthTakesTheGlyph() {
        let report = HealthReport(check: [
            HealthCheck(id: "x", group: .liddy, label: "x", state: .down, detail: ""),
        ])
        let icon = MenuBarIcon(RuntimeSnapshot(isAwakeHeld: true, health: report))
        XCTAssertEqual(icon.symbolName, "exclamationmark.triangle.fill")
    }

    func testBatteryPercentIsTheTitle() {
        let icon = MenuBarIcon(RuntimeSnapshot(
            battery: BatteryReading(percent: 67, isCharging: false, isOnMain: false)))
        XCTAssertEqual(icon.batteryTitle, "67%")
        XCTAssertTrue(icon.label.contains("67"))
    }

    func testDesktopWithNoBatteryHasNoTitle() {
        let icon = MenuBarIcon(RuntimeSnapshot(battery: .unknown))
        XCTAssertNil(icon.batteryTitle)
        XCTAssertEqual(icon.label, "Liddy: idle")
    }

    func testPercentChangeIsADifferentIcon() {
        let a = MenuBarIcon(RuntimeSnapshot(
            battery: BatteryReading(percent: 50, isCharging: false, isOnMain: false)))
        let b = MenuBarIcon(RuntimeSnapshot(
            battery: BatteryReading(percent: 49, isCharging: false, isOnMain: false)))
        XCTAssertNotEqual(a, b)
    }
}

import XCTest
@testable import LiddyKit

/// Keyed claims exist so a per-turn hook can fire hundreds of times in a session
/// without leaking a lease per turn.
final class KeyedClaimTest: XCTestCase {
    func testSameKeyRenewsInsteadOfStacking() {
        let registry = LeaseRegistry()
        let first = registry.claim(label: "Claude Code", ttlSecond: 60, key: "session-a")
        let second = registry.claim(label: "Claude Code", ttlSecond: 60, key: "session-a")

        XCTAssertEqual(first.token, second.token)
        XCTAssertEqual(registry.active.count, 1, "a repeated claim must not stack a second lease")
    }

    func testDifferentKeyIsADifferentLease() {
        let registry = LeaseRegistry()
        registry.claim(label: "Claude Code", ttlSecond: 60, key: "session-a")
        registry.claim(label: "Claude Code", ttlSecond: 60, key: "session-b")
        XCTAssertEqual(registry.active.count, 2)
    }

    func testReleaseByKey() {
        let registry = LeaseRegistry()
        registry.claim(label: "Claude Code", ttlSecond: 60, key: "session-a")
        XCTAssertTrue(registry.release(key: "session-a"))
        XCTAssertTrue(registry.isEmpty)
        XCTAssertFalse(registry.release(key: "session-a"), "releasing twice must report false")
    }

    /// The backstop: if a session dies mid-turn and no release ever arrives, the
    /// lease must lapse on its own rather than hold the Mac all night.
    func testKeyedClaimStillExpires() {
        let registry = LeaseRegistry()
        registry.claim(label: "Claude Code", ttlSecond: 1, key: "session-a")
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertTrue(registry.isEmpty)
    }

    func testUnkeyedClaimStaysUnique() {
        let registry = LeaseRegistry()
        registry.claim(label: "build", ttlSecond: 60)
        registry.claim(label: "build", ttlSecond: 60)
        XCTAssertEqual(registry.active.count, 2, "unkeyed claims are independent by design")
    }
}

final class SettingPatchTest: XCTestCase {
    /// `liddy set --soft-battery 25` must not quietly reset everything else.
    func testPatchLeavesUnsetFieldAlone() {
        var base = Setting.default
        base.isChargingOnly = true
        base.idleReleaseSecond = 900

        let patched = SettingPatch(softBatteryPercent: 25).applied(to: base)

        XCTAssertEqual(patched.softBatteryPercent, 25)
        XCTAssertEqual(patched.idleReleaseSecond, 900)
        XCTAssertTrue(patched.isChargingOnly)
        XCTAssertEqual(patched.watchPattern, base.watchPattern)
    }

    /// A patch goes through the same clamping as a loaded config — the CLI must not
    /// be a way around a floor.
    func testPatchIsNormalized() {
        let patched = SettingPatch(softBatteryPercent: 1, hardBatteryPercent: 99)
            .applied(to: .default)
        XCTAssertTrue(Setting.hardBatteryRange.contains(patched.hardBatteryPercent))
        XCTAssertGreaterThan(patched.softBatteryPercent, patched.hardBatteryPercent)
    }

    func testEmptyPatchIsDetected() {
        XCTAssertTrue(SettingPatch().isEmpty)
        XCTAssertFalse(SettingPatch(isChargingOnly: false).isEmpty)
    }
}

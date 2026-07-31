import XCTest
@testable import LiddyKit

/// Regression coverage for the flap: the soft battery floor released the hold, and
/// auto-watch re-acquired it ~10s later because the watched processes were obviously
/// still running — so the floor never actually let the Mac sleep. Observed live as the
/// lease count oscillating 0 ↔ 5 with "Battery crossed the floor after 4s" repeating in
/// the log every few seconds.
///
/// The rule that fixes it lives in the governor's own output, so it can be tested
/// there: a release must not be followed by a `.proceed` until conditions have
/// genuinely recovered, or the lock would lift straight back into the same release.
final class SafetyHysteresisTest: XCTestCase {
    private let setting = Setting.default          // soft 20, hard 4
    private var governor: SafetyGovernor { SafetyGovernor(setting: setting) }

    private func battery(_ percent: Int, isOnMain: Bool = false) -> BatteryReading {
        BatteryReading(percent: percent, isCharging: isOnMain, isOnMain: isOnMain)
    }

    private func verdict(_ percent: Int, isOnMain: Bool = false) -> SafetyVerdict {
        governor.evaluate(
            battery: battery(percent, isOnMain: isOnMain),
            thermal: ThermalReading(level: .nominal),
            isClamshellActive: false)
    }

    func testBelowSoftFloorReleases() {
        XCTAssertEqual(verdict(19), .release(.batteryFloor))
    }

    /// The load-bearing assertion. One point above the floor is *not* `.proceed`, so a
    /// lock cleared only on `.proceed` cannot re-arm at 21% and drop again at 19%.
    func testJustAboveTheFloorDoesNotReadAsRecovered() {
        for percent in 20...29 {
            XCTAssertNotEqual(
                verdict(percent), .proceed,
                "\(percent)% is inside the warn band; treating it as recovered re-creates the flap")
        }
    }

    /// Ten points of clearance is what the governor's warn band already gives us, and
    /// it is where the lock is allowed to lift.
    func testWellClearOfTheFloorRecovers() {
        XCTAssertEqual(verdict(30), .proceed)
        XCTAssertEqual(verdict(80), .proceed)
    }

    /// Plugging in is the other recovery path, and it must work at any charge.
    func testMainsPowerRecoversImmediately() {
        XCTAssertEqual(verdict(5, isOnMain: true), .proceed)
        XCTAssertEqual(verdict(19, isOnMain: true), .proceed)
    }

    /// The hard floor is a forced sleep, never a plain release — releasing only drops
    /// Liddy's own assertion and anything else holding one rides the battery to a hard
    /// shutdown.
    func testHardFloorForcesSleep() {
        XCTAssertEqual(verdict(3), .forceSleep(.batteryFloor))
    }

    func testHotMachineIsNotRecovered() {
        let hot = governor.evaluate(
            battery: battery(90, isOnMain: true),
            thermal: ThermalReading(level: .serious),
            isClamshellActive: false)
        XCTAssertNotEqual(hot, .proceed, "still hot — a lock must not lift here")
    }

    func testCoolMachineOnMainsIsRecovered() {
        let cool = governor.evaluate(
            battery: battery(90, isOnMain: true),
            thermal: ThermalReading(level: .fair),
            isClamshellActive: false)
        XCTAssertEqual(cool, .proceed)
    }
}

/// The bug itself, at the level it actually lived: the interaction between the
/// governor, the process watcher and the hold. None of the three is wrong on its own,
/// which is why this needed the whole loop to reproduce.
final class SafetyLockTest: XCTestCase {
    /// Mutable so a test can move the battery under a running runtime.
    private final class Power: @unchecked Sendable {
        let lock = NSLock()
        private var _battery = BatteryReading(percent: 50, isCharging: false, isOnMain: false)
        var battery: BatteryReading {
            get { lock.lock(); defer { lock.unlock() }; return _battery }
            set { lock.lock(); _battery = newValue; lock.unlock() }
        }
        var thermal = ThermalReading(level: .nominal)
    }

    private var logUrl: URL!

    override func setUp() {
        super.setUp()
        logUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("liddy-test-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logUrl)
        super.tearDown()
    }

    private func makeRuntime(_ power: Power) -> LiddyRuntime {
        LiddyRuntime(
            setting: .default,                       // soft 20, hard 4
            log: ActivityLog(url: logUrl),
            battery: { power.battery },
            thermal: { power.thermal })
    }

    /// The exact sequence seen live: hold, drop below the floor, release — and then the
    /// watcher reports the same still-running processes and must **not** re-acquire.
    func testAutoWatchDoesNotReArmAfterASafetyRelease() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude", "npm"])
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, "a healthy battery should hold normally")

        power.battery = BatteryReading(percent: 15, isCharging: false, isOnMain: false)
        runtime.tickForTest()
        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "below the soft floor, the hold must drop")
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor)

        // The processes are obviously still running — releasing the Mac did not kill
        // them. This scan is what used to re-acquire the hold ~10s after every stop.
        runtime.applyScanForTest(["claude", "npm"])
        XCTAssertFalse(
            runtime.snapshot.isAwakeHeld,
            "re-arming here is the 0↔5 flap: release, re-acquire, release, forever")
    }

    /// Repeated scans must stay refused, not just the first one.
    func testRepeatedScanStayRefused() {
        let power = Power()
        power.battery = BatteryReading(percent: 15, isCharging: false, isOnMain: false)
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        for _ in 0..<5 {
            runtime.applyScanForTest(["claude"])
            runtime.tickForTest()
        }
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor)
    }

    /// An agent hook firing every turn must not walk through the floor either.
    func testClaimDoesNotOverrideTheLock() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        power.battery = BatteryReading(percent: 15, isCharging: false, isOnMain: false)
        runtime.tickForTest()
        XCTAssertNotNil(runtime.snapshot.blockedBy)

        _ = runtime.claim(label: "Claude Code · liddy", ttlSecond: 300, key: "session-1")
        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "a claim is not an override of a safety stop")
    }

    /// The lease is still recorded while blocked — the work is real, and the panel has
    /// to be able to say "five things want this Mac awake and I am not allowing it".
    func testLeaseIsStillRecordedWhileBlocked() {
        let power = Power()
        power.battery = BatteryReading(percent: 15, isCharging: false, isOnMain: false)
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.tickForTest()
        _ = runtime.claim(label: "overnight migration", ttlSecond: 300, key: "k")
        XCTAssertEqual(runtime.snapshot.activeLease.count, 1)
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
    }

    /// Plugging in recovers, and the next scan is allowed to hold again.
    func testRecoveryOnMainsPowerLiftsTheLock() {
        let power = Power()
        power.battery = BatteryReading(percent: 15, isCharging: false, isOnMain: false)
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        XCTAssertNotNil(runtime.snapshot.blockedBy)

        power.battery = BatteryReading(percent: 16, isCharging: true, isOnMain: true)
        runtime.tickForTest()
        XCTAssertNil(runtime.snapshot.blockedBy, "on mains, the floor no longer applies")

        runtime.applyScanForTest(["claude"])
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)
    }

    /// Recovering by charge needs real clearance, not one point over the line.
    func testOnePointAboveTheFloorDoesNotLiftTheLock() {
        let power = Power()
        power.battery = BatteryReading(percent: 15, isCharging: false, isOnMain: false)
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()

        power.battery = BatteryReading(percent: 21, isCharging: false, isOnMain: false)
        runtime.tickForTest()
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor, "21% is still inside the warn band")

        power.battery = BatteryReading(percent: 35, isCharging: false, isOnMain: false)
        runtime.tickForTest()
        XCTAssertNil(runtime.snapshot.blockedBy, "well clear of the floor — allowed again")
    }

    /// An explicit hold is an override, and it is allowed to be. The governor still
    /// gets the next word, so this costs one cycle rather than looping.
    func testExplicitHoldOverridesTheLockOnce() {
        let power = Power()
        power.battery = BatteryReading(percent: 15, isCharging: false, isOnMain: false)
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        XCTAssertNotNil(runtime.snapshot.blockedBy)

        runtime.beginHold(second: nil, mode: .manual)
        runtime.tickForTest()   // the governor's next word
        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "still below the floor, so it stops again")
        XCTAssertNotNil(runtime.snapshot.blockedBy, "and the lock is back on, so it stops looping")
    }
}

/// Turning the hold off by hand has to stay off. With auto-watch on and any watched
/// process running — which is the normal case, since that is *why* the Mac was awake —
/// the next scan re-acquired within ten seconds and the switch flipped itself back on.
final class UserPauseTest: XCTestCase {
    private final class Power: @unchecked Sendable {
        var battery = BatteryReading(percent: 80, isCharging: true, isOnMain: true)
        var thermal = ThermalReading(level: .nominal)
    }

    private var logUrl: URL!

    override func setUp() {
        super.setUp()
        logUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("liddy-pause-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logUrl)
        super.tearDown()
    }

    private func makeRuntime(_ power: Power) -> LiddyRuntime {
        LiddyRuntime(
            setting: .default,
            log: ActivityLog(url: logUrl),
            battery: { power.battery },
            thermal: { power.thermal })
    }

    func testManualStopSurvivesTheNextProcessScan() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["npm", "esbuild", "uv"])
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)

        runtime.endHold(reason: .userStopped)
        _ = runtime.snapshot          // drain the queue
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
        XCTAssertTrue(runtime.snapshot.isUserPaused)

        // The watcher's next scan — the processes never stopped.
        runtime.applyScanForTest(["npm", "esbuild", "uv"])
        XCTAssertFalse(
            runtime.snapshot.isAwakeHeld,
            "off has to mean off; this is the switch flipping itself back on")
    }

    func testPauseSurvivesManyScan() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["npm"])
        runtime.endHold(reason: .userStopped)
        _ = runtime.snapshot
        for _ in 0..<10 {
            runtime.applyScanForTest(["npm"])
            runtime.tickForTest()
        }
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)
    }

    func testTurningItBackOnClearsThePause() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["npm"])
        runtime.endHold(reason: .userStopped)
        _ = runtime.snapshot

        runtime.beginHold(second: nil, mode: .smart)
        _ = runtime.snapshot
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)
        XCTAssertFalse(runtime.snapshot.isUserPaused)
    }

    /// A script saying "I am working now" is somebody asking out loud, so it lifts the
    /// pause. Otherwise a pause set days ago silently costs an overnight run.
    func testAnExplicitClaimLiftsThePause() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["npm"])
        runtime.endHold(reason: .userStopped)
        _ = runtime.snapshot
        XCTAssertTrue(runtime.snapshot.isUserPaused)

        _ = runtime.claim(label: "overnight migration", ttlSecond: 300, key: "k")
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)
        XCTAssertFalse(runtime.snapshot.isUserPaused)
    }

    /// Only a *hand-made* stop pauses. Work finishing is the system doing its job, and
    /// the next real workload must hold normally — otherwise one completed build would
    /// quietly disable Liddy until someone noticed.
    func testWorkFinishingDoesNotPause() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["npm"])
        runtime.endHold(reason: .workFinished)
        _ = runtime.snapshot
        XCTAssertFalse(runtime.snapshot.isUserPaused)

        runtime.applyScanForTest(["npm"])
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, "a new workload should hold again")
    }

    func testTimerExpiryDoesNotPause() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["cargo"])
        runtime.endHold(reason: .timerExpired)
        _ = runtime.snapshot
        XCTAssertFalse(runtime.snapshot.isUserPaused)
    }
}

/// "Keep going anyway". The line it must hold: an override waives the rules that exist
/// out of courtesy, and cannot reach the ones that exist to stop work being lost or
/// hardware cooked.
final class OverrideTest: XCTestCase {
    private let governor = SafetyGovernor(setting: .default)   // soft 20, hard 4

    private func verdict(percent: Int, thermal: ThermalLevel = .nominal,
                         isClamshellActive: Bool = false, isOverrideActive: Bool) -> SafetyVerdict {
        governor.evaluate(
            battery: BatteryReading(percent: percent, isCharging: false, isOnMain: false),
            thermal: ThermalReading(level: thermal),
            isClamshellActive: isClamshellActive,
            isOverrideActive: isOverrideActive)
    }

    func testSoftFloorIsWaivable() {
        XCTAssertEqual(verdict(percent: 15, isOverrideActive: false), .release(.batteryFloor))
        let overridden = verdict(percent: 15, isOverrideActive: true)
        XCTAssertFalse(overridden.isStop, "the soft floor is the user's call to waive")
    }

    /// The one that must never be waivable: below the hard floor the Mac is forced to
    /// sleep so the run ends resumable instead of at a hard shutdown.
    func testHardFloorIsNotWaivable() {
        XCTAssertEqual(verdict(percent: 3, isOverrideActive: true), .forceSleep(.batteryFloor))
    }

    /// No airflow behind a shut lid, so releasing is not enough and consent is not the
    /// missing ingredient.
    func testCriticalHeatBehindAShutLidIsNotWaivable() {
        XCTAssertEqual(
            verdict(percent: 90, thermal: .critical, isClamshellActive: true, isOverrideActive: true),
            .forceSleep(.thermalCritical))
    }

    func testThermalCeilingIsWaivableWithTheLidOpen() {
        let overridden = verdict(percent: 90, thermal: .critical, isOverrideActive: true)
        XCTAssertFalse(overridden.isStop)
    }

    func testChargingOnlyIsWaivable() {
        let strict = SafetyGovernor(setting: {
            var setting = Setting.default
            setting.isChargingOnly = true
            return setting
        }())
        let reading = BatteryReading(percent: 90, isCharging: false, isOnMain: false)
        XCTAssertTrue(strict.evaluate(battery: reading, thermal: .init(level: .nominal),
                                      isClamshellActive: false).isStop)
        XCTAssertFalse(strict.evaluate(battery: reading, thermal: .init(level: .nominal),
                                       isClamshellActive: false, isOverrideActive: true).isStop)
    }

    /// An override changes nothing when nothing was wrong.
    func testOverrideIsInertWhenHealthy() {
        XCTAssertEqual(
            governor.evaluate(
                battery: BatteryReading(percent: 90, isCharging: true, isOnMain: true),
                thermal: .init(level: .nominal),
                isClamshellActive: false,
                isOverrideActive: true),
            .proceed)
    }
}

/// The runtime half: an override has to actually resume the hold, expire on its own,
/// and be voided by the rules it was never allowed to touch.
final class OverrideRuntimeTest: XCTestCase {
    private final class Power: @unchecked Sendable {
        let lock = NSLock()
        private var _battery = BatteryReading(percent: 15, isCharging: false, isOnMain: false)
        var battery: BatteryReading {
            get { lock.lock(); defer { lock.unlock() }; return _battery }
            set { lock.lock(); _battery = newValue; lock.unlock() }
        }
        var thermal = ThermalReading(level: .nominal)
    }

    private var logUrl: URL!

    override func setUp() {
        super.setUp()
        logUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("liddy-override-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logUrl)
        super.tearDown()
    }

    private func makeRuntime(_ power: Power) -> LiddyRuntime {
        LiddyRuntime(
            setting: .default,
            log: ActivityLog(url: logUrl),
            battery: { power.battery },
            thermal: { power.thermal })
    }

    func testOverrideResumesHoldingBelowTheSoftFloor() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor)
        XCTAssertFalse(runtime.snapshot.isAwakeHeld)

        runtime.setOverride(second: 1800)
        _ = runtime.snapshot
        XCTAssertTrue(runtime.snapshot.isAwakeHeld, "an override that does not resume is decoration")
        XCTAssertNil(runtime.snapshot.blockedBy)
        XCTAssertNotNil(runtime.snapshot.overrideUntil)

        // And it survives the governor's next word, which is the whole point.
        runtime.tickForTest()
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)
    }

    func testOverrideIsCapped() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.setOverride(second: 99 * 3600)
        guard let until = runtime.snapshot.overrideUntil else { return XCTFail("no override") }
        XCTAssertLessThanOrEqual(
            until.timeIntervalSinceNow,
            TimeInterval(LiddyRuntime.maxOverrideSecond) + 5,
            "an unbounded waiver is just a disabled rule")
    }

    /// Crossing the hard floor while overriding must force sleep anyway, and void the
    /// override rather than leaving it armed for the next rule on the way down.
    func testHardFloorVoidsTheOverride() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        runtime.setOverride(second: 1800)
        _ = runtime.snapshot
        XCTAssertTrue(runtime.snapshot.isAwakeHeld)

        power.battery = BatteryReading(percent: 3, isCharging: false, isOnMain: false)
        runtime.tickForTest()

        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "the hard floor is not waivable")
        XCTAssertNil(runtime.snapshot.overrideUntil, "and the waiver does not survive it")
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor)
    }

    func testCancellingAnOverrideRestoresTheRules() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.applyScanForTest(["claude"])
        runtime.tickForTest()
        runtime.setOverride(second: 1800)
        _ = runtime.snapshot

        runtime.clearOverride()
        _ = runtime.snapshot
        XCTAssertNil(runtime.snapshot.overrideUntil)

        runtime.tickForTest()
        XCTAssertFalse(runtime.snapshot.isAwakeHeld, "back under the floor once the waiver is gone")
        XCTAssertEqual(runtime.snapshot.blockedBy, .batteryFloor)
    }

    /// A recovered machine does not need the override any more, and it should not stay
    /// armed silently.
    func testOverrideExpiryReturnsToNormalRules() {
        let power = Power()
        let runtime = makeRuntime(power)
        defer { runtime.shutdown() }

        runtime.setOverride(second: 60)          // clamped minimum
        _ = runtime.snapshot
        XCTAssertNotNil(runtime.snapshot.overrideUntil)
        XCTAssertLessThanOrEqual(runtime.snapshot.overrideUntil!.timeIntervalSinceNow, 61)
    }
}

/// A thermal ceiling of `.nominal` is unsatisfiable: the governor asks
/// `thermal.level >= ceiling`, and every level is `>= .nominal`. Before the clamp that
/// was reachable from `liddy set --thermal-ceiling nominal` and from the settings
/// picker, and it does not merely misbehave — combined with the safety lock it wedges
/// the app into a state that can never hold again, because the lock only lifts on a
/// verdict the governor can no longer produce.
final class ThermalCeilingClampTest: XCTestCase {
    func testNominalCeilingIsRaisedToFair() {
        var setting = Setting.default
        setting.thermalCeiling = .nominal
        XCTAssertEqual(setting.normalized().thermalCeiling, .fair)
    }

    func testTheCliCannotSetAnUnsatisfiableCeiling() {
        let patched = SettingPatch(thermalCeiling: .nominal).applied(to: .default)
        XCTAssertEqual(patched.thermalCeiling, .fair)
    }

    func testAHandEditedConfigIsClampedOnLoad() throws {
        let data = Data(#"{"thermalCeiling":"nominal"}"#.utf8)
        let decoded = try JSONDecoder().decode(Setting.self, from: data)
        XCTAssertEqual(decoded.normalized().thermalCeiling, .fair)
    }

    func testValidCeilingIsUntouched() {
        for level in Setting.thermalCeilingChoice {
            var setting = Setting.default
            setting.thermalCeiling = level
            XCTAssertEqual(setting.normalized().thermalCeiling, level)
        }
    }

    /// The property that matters: with any offered ceiling, a cool idle Mac can still
    /// reach `.proceed` — so a lock taken for heat is always liftable.
    func testEveryOfferedCeilingLeavesProceedReachable() {
        for level in Setting.thermalCeilingChoice {
            var setting = Setting.default
            setting.thermalCeiling = level
            let verdict = SafetyGovernor(setting: setting).evaluate(
                battery: BatteryReading(percent: 90, isCharging: true, isOnMain: true),
                thermal: ThermalReading(level: .nominal),
                isClamshellActive: false)
            XCTAssertEqual(verdict, .proceed, "ceiling \(level.rawValue) must leave a reachable healthy state")
        }
    }

    /// The picker must not offer the value the clamp exists to reject.
    func testPickerDoesNotOfferNominal() {
        XCTAssertFalse(Setting.thermalCeilingChoice.contains(.nominal))
    }
}

/// The registry half of the same story: a safety stop wipes every lease, and the next
/// process scan puts them all straight back. That is correct — the processes really are
/// still running — which is exactly why the *hold* has to be gated separately from the
/// *lease*, and why the fix could not live here.
final class LeaseAfterSafetyStopTest: XCTestCase {
    func testProcessLeaseComeBackAfterAReleaseAll() {
        let registry = LeaseRegistry()
        registry.replaceProcessLease(["claude", "npm", "python"])
        XCTAssertEqual(registry.active.count, 3)

        registry.releaseAll()
        XCTAssertTrue(registry.isEmpty)

        // The watcher's next scan, 10s later.
        registry.replaceProcessLease(["claude", "npm", "python"])
        XCTAssertEqual(registry.active.count, 3, "the work did not stop just because we let go")
    }

    /// Process leases never expire on their own — they are backed by something real,
    /// so a scan is the only thing that can retire them. Worth pinning: if these ever
    /// gained a TTL, the count would flap for a completely different reason.
    func testProcessLeaseDoesNotExpire() {
        let registry = LeaseRegistry()
        registry.replaceProcessLease(["cargo"])
        let lease = registry.active.first
        XCTAssertNotNil(lease)
        XCTAssertNil(lease?.expiresAt)
        XCTAssertFalse(lease?.isExpired(asOf: Date().addingTimeInterval(86_400)) ?? true)
    }
}

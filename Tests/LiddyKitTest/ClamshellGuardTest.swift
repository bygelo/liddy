import XCTest
@testable import LiddyKit

/// The deadman switch is the single most safety-critical thing in this product — it
/// is what stops a Mac being left unable to sleep in a bag — and until this file it
/// had no test at all, because `ClamshellGuard` lived inside the helper executable.
///
/// The scripted sequences below are connect / request / disconnect / heartbeat-gap
/// against a fake `pmset`; the scorer is the asserted `disablesleep` state per step.
final class ClamshellGuardTest: XCTestCase {

    // MARK: - Fakes

    final class FakePmset: PmsetRunning {
        var invocation: [[String]] = []
        var isFailing = false

        func run(_ argument: [String]) -> Bool {
            invocation.append(argument)
            return !isFailing
        }

        /// The state the real `pmset -a disablesleep` would be in after the script.
        var isDisableSleepOn: Bool {
            invocation.last { $0.contains("disablesleep") }?.last == "1"
        }
    }

    final class MemoryStore: ClamshellStateStoring {
        var state: ClamshellState?
        func load() -> ClamshellState? { state }
        func save(_ state: ClamshellState?) { self.state = state }
    }

    /// Fires the deadman on demand instead of 15 seconds later. Deliberately
    /// lock-free: the scheduled work re-enters `cancel()` through the guard.
    final class ManualScheduler: DelayScheduling {
        private(set) var pending: (() -> Void)?
        private(set) var scheduleCount = 0
        private(set) var cancelCount = 0

        func schedule(afterSecond: Int, _ work: @escaping () -> Void) {
            scheduleCount += 1
            pending = work
        }

        func cancel() {
            cancelCount += 1
            pending = nil
        }

        /// Run the armed timer, as the real queue would when no heartbeat arrived.
        func fire() {
            let work = pending
            pending = nil
            work?()
        }
    }

    private func makeGuard(
        pmset: FakePmset = FakePmset(),
        store: MemoryStore = MemoryStore(),
        scheduler: ManualScheduler = ManualScheduler()
    ) -> ClamshellGuard {
        ClamshellGuard(pmset: pmset, store: store, scheduler: scheduler, deadmanSecond: 15)
    }

    private let app = ConnectionId(raw: 1)
    private let doctor = ConnectionId(raw: 2)

    // MARK: - The toggle

    func testSetOnRunsPmsetAndPersistsState() {
        let pmset = FakePmset()
        let store = MemoryStore()
        let sut = makeGuard(pmset: pmset, store: store)

        XCTAssertTrue(sut.set(true, owner: app))

        XCTAssertEqual(pmset.invocation, [["-a", "disablesleep", "1"]])
        XCTAssertTrue(sut.isOn)
        XCTAssertEqual(store.state?.isClamshellOn, true)
    }

    func testSetOffClearsStateAndDisarmsDeadman() {
        let pmset = FakePmset()
        let store = MemoryStore()
        let scheduler = ManualScheduler()
        let sut = makeGuard(pmset: pmset, store: store, scheduler: scheduler)

        sut.set(true, owner: app)
        sut.set(false)

        XCTAssertFalse(sut.isOn)
        XCTAssertFalse(pmset.isDisableSleepOn)
        XCTAssertNil(store.state)
        XCTAssertNil(scheduler.pending)
        XCTAssertNil(sut.lastHeartbeatAt)
    }

    func testPmsetFailureLeavesTheGuardUnchanged() {
        let pmset = FakePmset()
        pmset.isFailing = true
        let store = MemoryStore()
        let sut = makeGuard(pmset: pmset, store: store)

        XCTAssertFalse(sut.set(true, owner: app))
        XCTAssertFalse(sut.isOn)
        XCTAssertNil(store.state, "nothing was toggled, so there is no leftover to reconcile")
    }

    // MARK: - Connection ownership (the `liddy doctor` regression)

    func testForeignConnectionClosingDoesNotRevert() {
        let pmset = FakePmset()
        let sut = makeGuard(pmset: pmset)

        sut.set(true, owner: app)
        // `liddy doctor` opens a second connection, reads status, and lets it close.
        sut.connectionLost(doctor)

        XCTAssertTrue(sut.isOn, "diagnosing closed-lid mode must not end closed-lid mode")
        XCTAssertTrue(pmset.isDisableSleepOn)
    }

    func testOwningConnectionClosingRevertsImmediately() {
        let pmset = FakePmset()
        let sut = makeGuard(pmset: pmset)

        sut.set(true, owner: app)
        sut.connectionLost(app)

        XCTAssertFalse(sut.isOn)
        XCTAssertFalse(pmset.isDisableSleepOn)
    }

    func testHeartbeatMovesOwnershipToTheLiveConnection() {
        let pmset = FakePmset()
        let sut = makeGuard(pmset: pmset)
        let reconnected = ConnectionId(raw: 3)

        sut.set(true, owner: app)
        // The app crashed and came back on a new connection before the deadman fired.
        sut.heartbeat(from: reconnected)

        sut.connectionLost(app)
        XCTAssertTrue(sut.isOn, "the dead connection is no longer the owner")

        sut.connectionLost(reconnected)
        XCTAssertFalse(sut.isOn)
    }

    func testConnectionLostWhileOffIsIgnored() {
        let pmset = FakePmset()
        let sut = makeGuard(pmset: pmset)

        sut.connectionLost(app)

        XCTAssertTrue(pmset.invocation.isEmpty)
    }

    // MARK: - Heartbeat and deadman

    func testDeadmanRevertsWhenHeartbeatStops() {
        let pmset = FakePmset()
        let scheduler = ManualScheduler()
        let sut = makeGuard(pmset: pmset, scheduler: scheduler)

        sut.set(true, owner: app)
        scheduler.fire()

        XCTAssertFalse(sut.isOn)
        XCTAssertFalse(pmset.isDisableSleepOn)
    }

    func testHeartbeatRearmsTheDeadman() {
        let scheduler = ManualScheduler()
        let sut = makeGuard(scheduler: scheduler)

        sut.set(true, owner: app)
        let armedAtSet = scheduler.scheduleCount
        sut.heartbeat(from: app)

        XCTAssertEqual(scheduler.scheduleCount, armedAtSet + 1)
        XCTAssertNotNil(scheduler.pending, "a fresh timer is armed, not the expired one")
    }

    func testHeartbeatWhileOffDoesNothing() {
        let scheduler = ManualScheduler()
        let sut = makeGuard(scheduler: scheduler)

        sut.heartbeat(from: app)

        XCTAssertNil(scheduler.pending)
        XCTAssertNil(sut.lastHeartbeatAt)
    }

    // MARK: - Recovery

    func testReconcileOnLaunchRevertsALeftoverToggle() {
        let pmset = FakePmset()
        let store = MemoryStore()
        store.state = ClamshellState(isClamshellOn: true, setAt: Date(timeIntervalSince1970: 0))
        let sut = makeGuard(pmset: pmset, store: store)

        sut.reconcileOnLaunch()

        XCTAssertEqual(pmset.invocation, [["-a", "disablesleep", "0"]])
        XCTAssertNil(store.state)
    }

    func testReconcileOnLaunchLeavesACleanMachineAlone() {
        let pmset = FakePmset()
        let sut = makeGuard(pmset: pmset, store: MemoryStore())

        sut.reconcileOnLaunch()

        XCTAssertTrue(pmset.invocation.isEmpty, "never touch a setting we did not set")
    }
}

/// `HelperClient.isAvailable` read the *global* socket path instead of its own until
/// 2026-09-11. Any client pointed elsewhere therefore reported the live root daemon
/// as reachable, and `LiddyRuntime`'s hard-battery-floor path sent a real `sleepNow`
/// to it from the test suite — which is why running `swift test` slept the Mac.
final class HelperClientPathTest: XCTestCase {
    func testAvailabilityFollowsThisClientsOwnPath() {
        let client = HelperClient(path: "/private/tmp/liddy-test-helper-\(UUID().uuidString).sock")
        XCTAssertFalse(client.isAvailable, "a socket that does not exist is never available")
    }

    func testSleepNowThrowsRatherThanDiallingAnAbsentHelper() {
        let client = HelperClient(path: "/private/tmp/liddy-test-helper-\(UUID().uuidString).sock")
        XCTAssertThrowsError(try client.sleepNow(reason: "test"))
    }
}

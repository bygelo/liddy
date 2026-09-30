import XCTest
@testable import LiddyKit

/// End to end through the real runtime, with a fake window server: the plan is tested
/// on its own in `ResourcePlanTest`, and this proves the runtime actually calls it and
/// — the part that would cost a user their windows — always gives them back.
final class ResourceSaverRuntimeTest: XCTestCase {
    final class FakeBackgrounder: AppBackgrounding {
        var running = ["Google Chrome", "Discord", "Finder"]
        var front: String?
        private(set) var hidden: Set<String> = []
        private(set) var hideCount = 0
        private(set) var unhideCount = 0

        func runningAppName() -> [String] { running }
        func frontmostAppName() -> String? { front }

        func hide(_ name: String) -> Bool {
            hideCount += 1
            hidden.insert(name)
            return true
        }

        func unhide(_ name: String) -> Bool {
            unhideCount += 1
            hidden.remove(name)
            return true
        }
    }

    private var logUrl: URL!

    override func setUp() {
        super.setUp()
        logUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("liddy-resource-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logUrl)
        super.tearDown()
    }

    private func makeRuntime(_ backgrounder: FakeBackgrounder, isEnabled: Bool = true) -> LiddyRuntime {
        var setting = Setting.default
        setting.isResourceSaverOn = isEnabled
        setting.backgroundApp = ["Google Chrome", "Discord"]
        // A dimmer wired to nothing: this test is about windows, and a real one would
        // reach for the machine's actual backlight.
        let dimmer = DisplayDimmer(
            readLevel: { nil }, writeLevel: { _ in false }, readLidClosed: { nil })
        return LiddyRuntime(
            setting: setting,
            log: ActivityLog(url: logUrl),
            helper: HelperClient(path: Self.deadHelperSocketPath),
            battery: { BatteryReading(percent: 90, isCharging: false, isOnMain: true) },
            thermal: { ThermalReading(level: .nominal) },
            dimmer: dimmer,
            backgrounder: backgrounder)
    }

    func testHoldBackgroundsTheConfiguredAppAndReleaseGivesThemBack() {
        let workspace = FakeBackgrounder()
        let runtime = makeRuntime(workspace)
        defer { runtime.shutdown() }

        runtime.beginHold(second: nil, mode: .manual)
        runtime.tickForTest()
        XCTAssertEqual(workspace.hidden, ["Google Chrome", "Discord"])

        runtime.endHold()
        runtime.tickForTest()
        XCTAssertTrue(workspace.hidden.isEmpty, "a finished run owes every window back")
    }

    /// Ten ticks, one hide each. A saver that re-hides on every tick fights a user who
    /// unhides Chrome to check something mid-run.
    func testRepeatedTicksHideOnce() {
        let workspace = FakeBackgrounder()
        let runtime = makeRuntime(workspace)
        defer { runtime.shutdown() }

        runtime.beginHold(second: nil, mode: .manual)
        for _ in 0..<10 { runtime.tickForTest() }

        XCTAssertEqual(workspace.hideCount, 2, "two apps, once each")
    }

    func testDisabledSaverTouchesNothing() {
        let workspace = FakeBackgrounder()
        let runtime = makeRuntime(workspace, isEnabled: false)
        defer { runtime.shutdown() }

        runtime.beginHold(second: nil, mode: .manual)
        runtime.tickForTest()

        XCTAssertEqual(workspace.hideCount, 0)
    }

    func testFrontmostAppIsLeftAlone() {
        let workspace = FakeBackgrounder()
        workspace.front = "Google Chrome"
        let runtime = makeRuntime(workspace)
        defer { runtime.shutdown() }

        runtime.beginHold(second: nil, mode: .manual)
        runtime.tickForTest()

        XCTAssertEqual(workspace.hidden, ["Discord"])
    }

    /// Quitting Liddy with somebody else's windows hidden is indistinguishable from
    /// that app crashing. `shutdown()` is the last chance to undo it.
    func testQuitRestoresEverythingItHid() {
        let workspace = FakeBackgrounder()
        let runtime = makeRuntime(workspace)

        runtime.beginHold(second: nil, mode: .manual)
        runtime.tickForTest()
        XCTAssertFalse(workspace.hidden.isEmpty)

        runtime.shutdown()
        XCTAssertTrue(workspace.hidden.isEmpty)
    }

    func testSnapshotNamesWhatIsBackgrounded() {
        let workspace = FakeBackgrounder()
        let runtime = makeRuntime(workspace)
        defer { runtime.shutdown() }

        runtime.beginHold(second: nil, mode: .manual)
        runtime.tickForTest()

        XCTAssertEqual(Set(runtime.snapshot.backgroundedApp), ["Google Chrome", "Discord"])
    }
}

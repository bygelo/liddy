import XCTest
@testable import LiddyKit

/// The rules worth protecting are all about restraint: touch only what was configured,
/// only while a hold is running, never what the user is looking at, and always give
/// back exactly what was taken.
final class ResourcePlanTest: XCTestCase {
    private let wanted = ["Google Chrome", "Discord", "Slack"]

    func testHidesTheConfiguredAppThatIsActuallyRunning() {
        let plan = ResourcePlan.plan(
            isEnabled: true, isHolding: true,
            wanted: wanted, running: ["Google Chrome", "Finder", "Discord"], hidden: [])

        XCTAssertEqual(plan.hide, ["Google Chrome", "Discord"])
        XCTAssertTrue(plan.unhide.isEmpty, "Slack is not running, so there is nothing to do about it")
    }

    func testDoesNothingWhileNotHolding() {
        let plan = ResourcePlan.plan(
            isEnabled: true, isHolding: false,
            wanted: wanted, running: ["Google Chrome"], hidden: [])
        XCTAssertEqual(plan, .doNothing)
    }

    func testDoesNothingWhenDisabled() {
        let plan = ResourcePlan.plan(
            isEnabled: false, isHolding: true,
            wanted: wanted, running: ["Google Chrome"], hidden: [])
        XCTAssertEqual(plan, .doNothing)
    }

    /// The release path. A run that ends must give back everything it took, or the
    /// user finds Chrome missing in the morning with no way to connect the two.
    func testReleaseGivesBackEverythingItTook() {
        let plan = ResourcePlan.plan(
            isEnabled: true, isHolding: false,
            wanted: wanted, running: ["Google Chrome", "Discord"], hidden: ["Google Chrome", "Discord"])
        XCTAssertEqual(plan.unhide, ["Google Chrome", "Discord"])
        XCTAssertTrue(plan.hide.isEmpty)
    }

    /// Turning the setting off mid-run is a restore, not an abandonment.
    func testDisablingMidRunRestores() {
        let plan = ResourcePlan.plan(
            isEnabled: false, isHolding: true,
            wanted: wanted, running: ["Google Chrome"], hidden: ["Google Chrome"])
        XCTAssertEqual(plan.unhide, ["Google Chrome"])
    }

    /// Ten ticks must hide once. Re-hiding an app the user deliberately unhid mid-run
    /// would be a fight the user cannot win.
    func testAlreadyHiddenIsNotHiddenAgain() {
        let plan = ResourcePlan.plan(
            isEnabled: true, isHolding: true,
            wanted: wanted, running: ["Google Chrome"], hidden: ["Google Chrome"])
        XCTAssertTrue(plan.hide.isEmpty)
    }

    /// A window vanishing under the pointer reads as a crash.
    func testNeverHidesTheFrontmostApp() {
        let plan = ResourcePlan.plan(
            isEnabled: true, isHolding: true,
            wanted: wanted, running: ["Google Chrome", "Discord"], hidden: [],
            frontmost: "Google Chrome")
        XCTAssertEqual(plan.hide, ["Discord"])
    }

    /// The user's own hidden windows are not Liddy's to restore.
    func testDoesNotUnhideSomethingItNeverHid() {
        let plan = ResourcePlan.plan(
            isEnabled: true, isHolding: false,
            wanted: wanted, running: ["Google Chrome"], hidden: [])
        XCTAssertEqual(plan, .doNothing)
    }

    /// An app that quit while hidden is dropped from the tracked set rather than
    /// waited on forever.
    func testQuitAppIsReleasedFromTracking() {
        let plan = ResourcePlan.plan(
            isEnabled: true, isHolding: true,
            wanted: wanted, running: ["Discord"], hidden: ["Google Chrome"])
        XCTAssertEqual(plan.unhide, ["Google Chrome"])
        XCTAssertEqual(plan.hide, ["Discord"])
    }

    func testMatchingIsCaseInsensitive() {
        let plan = ResourcePlan.plan(
            isEnabled: true, isHolding: true,
            wanted: ["google chrome"], running: ["Google Chrome"], hidden: [])
        XCTAssertEqual(plan.hide, ["google chrome"])
    }
}

/// With the lid shut there is no screen to look at, so the scope widens from the
/// configured list to everything that is not keeping the work alive. The risk is
/// obvious and the tests are all about what must survive it.
final class ClosedLidResourceTest: XCTestCase {
    private let running = ["Google Chrome", "Spotify", "Warp", "Claude", "Finder", "Notion"]

    private func plan(hidden: [String] = [], sessionApp: [String] = ["Claude"]) -> ResourcePlan {
        ResourcePlan.plan(
            isEnabled: true, isHolding: true,
            wanted: ["Google Chrome"], running: running, hidden: hidden,
            isLidClosed: true, sessionApp: sessionApp)
    }

    func testClosedLidBackgroundsEverythingIrrelevant() {
        XCTAssertEqual(Set(plan().hide), ["Google Chrome", "Spotify", "Notion"])
    }

    /// The one that would break the product: every agent session runs *inside* a
    /// terminal, so hiding the terminal hides the work the Mac is being held awake for.
    func testTerminalIsNeverBackgrounded() {
        XCTAssertFalse(plan().hide.contains("Warp"))
        XCTAssertTrue(ResourcePlan.neverBackground.contains("Terminal"))
        XCTAssertTrue(ResourcePlan.neverBackground.contains("Ghostty"))
    }

    func testAppWithALiveSessionIsNeverBackgrounded() {
        XCTAssertFalse(plan().hide.contains("Claude"))
    }

    func testLiddyAndFinderAreNeverBackgrounded() {
        XCTAssertFalse(plan().hide.contains("Finder"))
        XCTAssertTrue(ResourcePlan.neverBackground.contains("Liddy"))
    }

    /// Open lid, same everything else: back to the explicit list only. A user looking
    /// at their desktop does not want it rearranged.
    func testOpenLidStaysWithTheConfiguredList() {
        let open = ResourcePlan.plan(
            isEnabled: true, isHolding: true,
            wanted: ["Google Chrome"], running: running, hidden: [],
            isLidClosed: false, sessionApp: ["Claude"])
        XCTAssertEqual(open.hide, ["Google Chrome"])
    }

    func testAlreadyHiddenIsNotHiddenTwiceUnderTheWiderScope() {
        XCTAssertFalse(plan(hidden: ["Spotify"]).hide.contains("Spotify"))
    }

    /// Opening the lid must give back everything the closed-lid scope took, including
    /// apps that were never on the configured list.
    func testEverythingTakenComesBackWhenTheHoldEnds() {
        let release = ResourcePlan.plan(
            isEnabled: true, isHolding: false,
            wanted: ["Google Chrome"], running: running, hidden: ["Spotify", "Notion"],
            isLidClosed: false, sessionApp: [])
        XCTAssertEqual(Set(release.unhide), ["Spotify", "Notion"])
    }
}

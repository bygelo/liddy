import XCTest
@testable import LiddyKit

/// The parse half is locked against a row copied from this machine's IO registry, and
/// the policy half against the case that actually hurts: a restore that puts the panel
/// back to black because the dim level was saved twice.
final class DisplayBrightnessTest: XCTestCase {

    /// Real `ioreg -c AppleARMBacklight -r -d 1` output, trimmed to the one line that
    /// matters. Note the decoys on the same line: three other keys contain the word
    /// "rightness" and two of them are in completely different units.
    private let realRow = """
          "IODisplayParameters" = {"BrightnessMilliNits"={"min"=976,"value"=381794,"uncalMilliNits"=140000,"max"=1599999},"brightness"={"min"=0,"max"=65536,"value"=32768},"rawBrightness"={"min"=0,"max"=2047,"value"=1488},"BrightnessMicroAmps"={"min"=26,"max"=13799,"value"=3199}}
        """

    func testParsesTheSliderScaleNotTheMilliNitsDecoy() throws {
        let level = try XCTUnwrap(DisplayBrightness.parse(ioreg: realRow))
        XCTAssertEqual(level, 0.5, accuracy: 0.0001)
    }

    func testParsesZeroAndFull() {
        let dark = realRow.replacingOccurrences(
            of: "\"brightness\"={\"min\"=0,\"max\"=65536,\"value\"=32768}",
            with: "\"brightness\"={\"min\"=0,\"max\"=65536,\"value\"=0}")
        XCTAssertEqual(DisplayBrightness.parse(ioreg: dark), 0)

        let full = realRow.replacingOccurrences(
            of: "\"brightness\"={\"min\"=0,\"max\"=65536,\"value\"=32768}",
            with: "\"brightness\"={\"min\"=0,\"max\"=65536,\"value\"=65536}")
        XCTAssertEqual(DisplayBrightness.parse(ioreg: full), 1)
    }

    func testMissingPropertyIsNilNotZero() {
        XCTAssertNil(DisplayBrightness.parse(ioreg: "+-o AppleARMBacklight  <class AppleARMBacklight>"))
        XCTAssertNil(DisplayBrightness.parse(ioreg: ""))
    }

    /// A zero maximum would divide by zero and report a plausible level.
    func testZeroMaximumIsNil() {
        XCTAssertNil(DisplayBrightness.parse(ioreg: "\"brightness\"={\"min\"=0,\"max\"=0,\"value\"=0}"))
    }

    // MARK: - The policy

    func testClosingTheLidSavesTheLevelAndDims() {
        let plan = DimmingPlan.plan(isLidClosed: true, isEnabled: true, current: 0.7, saved: nil)
        XCTAssertEqual(plan, DimmingPlan(apply: 0, saved: 0.7))
    }

    /// The bug this exists to prevent: a second tick with the lid still shut must not
    /// re-save, or it saves the 0 it just wrote and the restore leaves the panel black.
    func testSecondTickWithTheLidShutChangesNothing() {
        let plan = DimmingPlan.plan(isLidClosed: true, isEnabled: true, current: 0, saved: 0.7)
        XCTAssertEqual(plan, .doNothing)
    }

    func testOpeningTheLidRestoresAndForgets() {
        let plan = DimmingPlan.plan(isLidClosed: false, isEnabled: true, current: 0, saved: 0.7)
        XCTAssertEqual(plan, DimmingPlan(apply: 0.7, saved: nil))
    }

    func testOpenLidWithNothingSavedIsLeftAlone() {
        XCTAssertEqual(
            DimmingPlan.plan(isLidClosed: false, isEnabled: true, current: 0.4, saved: nil),
            .doNothing)
    }

    /// Turning the setting off while the lid is shut still owes the user their screen.
    func testDisablingMidDimRestores() {
        let plan = DimmingPlan.plan(isLidClosed: true, isEnabled: false, current: 0, saved: 0.7)
        XCTAssertEqual(plan, DimmingPlan(apply: 0.7, saved: nil))
    }

    func testDisabledAndNothingSavedIsLeftAlone() {
        XCTAssertEqual(
            DimmingPlan.plan(isLidClosed: true, isEnabled: false, current: 0.5, saved: nil),
            .doNothing)
    }

    /// A level that cannot be read cannot be restored, so it is not dimmed either.
    func testUnreadableLevelIsNotDimmed() {
        XCTAssertEqual(
            DimmingPlan.plan(isLidClosed: true, isEnabled: true, current: nil, saved: nil),
            .doNothing)
    }

    /// A panel already at zero has nothing worth saving — dimming it would hand the
    /// restore a 0 and make "open the lid" a no-op forever.
    func testAlreadyDarkPanelIsNotDimmed() {
        XCTAssertEqual(
            DimmingPlan.plan(isLidClosed: true, isEnabled: true, current: 0, saved: nil),
            .doNothing)
    }
}

/// `AppleClamshellState` is the kernel's own answer to "is the lid shut", which is why
/// nothing here infers it from display count or power source.
final class LidStateTest: XCTestCase {
    func testLidClosedAndOpen() {
        XCTAssertEqual(ClamshellProbe.isLidClosed("\"AppleClamshellState\" = Yes"), true)
        XCTAssertEqual(ClamshellProbe.isLidClosed("      \"AppleClamshellState\" = No"), false)
    }

    func testAbsentIsNilNotFalse() {
        XCTAssertNil(ClamshellProbe.isLidClosed("\"AppleClamshellCausesSleep\" = No"))
        XCTAssertNil(ClamshellProbe.isLidClosed(""))
    }

    /// The two clamshell properties sit next to each other in the same dump and mean
    /// completely different things; reading the wrong one inverts the feature.
    func testDoesNotConfuseItselfWithCausesSleep() {
        let block = """
            |   "AppleClamshellCausesSleep" = Yes
            |   "AppleClamshellState" = No
            """
        XCTAssertEqual(ClamshellProbe.isLidClosed(block), false)
        XCTAssertEqual(ClamshellProbe.causesSleep(block), true)
    }
}

/// The stateful half: what the dimmer remembers between ticks. The fakes stand in for
/// the backlight so a test never touches the machine's actual screen.
final class DisplayDimmerTest: XCTestCase {
    final class FakePanel {
        var level: Double? = 0.7
        var lidClosed: Bool? = false
        var writeCount = 0
        var isWriteFailing = false

        func write(_ value: Double) -> Bool {
            guard !isWriteFailing else { return false }
            writeCount += 1
            level = value
            return true
        }
    }

    private func makeDimmer(_ panel: FakePanel) -> DisplayDimmer {
        DisplayDimmer(
            readLevel: { panel.level },
            writeLevel: { panel.write($0) },
            readLidClosed: { panel.lidClosed })
    }

    func testLidCloseDimsAndLidOpenRestores() {
        let panel = FakePanel()
        let dimmer = makeDimmer(panel)

        panel.lidClosed = true
        dimmer.update(isEnabled: true)
        XCTAssertEqual(panel.level, 0)
        XCTAssertEqual(dimmer.dimmedFrom, 0.7)

        panel.lidClosed = false
        dimmer.update(isEnabled: true)
        XCTAssertEqual(panel.level, 0.7)
        XCTAssertNil(dimmer.dimmedFrom)
    }

    /// Ten ticks with the lid shut must write once. The panel is a shared setting; a
    /// dimmer that rewrites it every 5 seconds fights the user's own brightness keys.
    func testRepeatedTicksWriteOnce() {
        let panel = FakePanel()
        let dimmer = makeDimmer(panel)
        panel.lidClosed = true

        for _ in 0..<10 { dimmer.update(isEnabled: true) }

        XCTAssertEqual(panel.writeCount, 1)
        XCTAssertEqual(dimmer.dimmedFrom, 0.7)
    }

    func testRestorePutsTheScreenBackWhateverTheLidSays() {
        let panel = FakePanel()
        let dimmer = makeDimmer(panel)
        panel.lidClosed = true
        dimmer.update(isEnabled: true)

        XCTAssertTrue(dimmer.restore())
        XCTAssertEqual(panel.level, 0.7)
        XCTAssertNil(dimmer.dimmedFrom)
        XCTAssertFalse(dimmer.restore(), "nothing left to restore")
    }

    /// An unreadable lid is not a closed lid — and if we are already dimmed when the
    /// reading goes away, the safe move is to give the screen back.
    func testUnknownLidStateRestoresRatherThanGuessing() {
        let panel = FakePanel()
        let dimmer = makeDimmer(panel)
        panel.lidClosed = true
        dimmer.update(isEnabled: true)

        panel.lidClosed = nil
        dimmer.update(isEnabled: true)

        XCTAssertEqual(panel.level, 0.7)
        XCTAssertNil(dimmer.dimmedFrom)
    }

    /// A failed write must not record a dim that never happened, or the restore would
    /// write a level the panel was never moved off.
    func testFailedWriteRemembersNothing() {
        let panel = FakePanel()
        let dimmer = makeDimmer(panel)
        panel.lidClosed = true
        panel.isWriteFailing = true

        dimmer.update(isEnabled: true)

        XCTAssertNil(dimmer.dimmedFrom)
        XCTAssertEqual(panel.level, 0.7)
    }
}

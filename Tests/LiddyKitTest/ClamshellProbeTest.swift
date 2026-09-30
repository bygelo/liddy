import XCTest
@testable import LiddyKit

/// The clamshell probe is the tie-breaker between what pmset *claims* and what
/// the kernel *does* — worth locking down because a silent false would let the
/// Mac sleep mid-run with no warning.
final class ClamshellProbeTest: XCTestCase {

    // MARK: - causesSleep

    /// A realistic ioreg block with tree characters — the format this probe
    /// actually has to parse on a running Mac.
    func testYesParsesFromRealIoreg() {
        let block = """
            | +-o IOPMrootDomain  <class IOPMrootDomain, id 0x8000203e0, registered, matched, active, busy 0 (0 ms), retain 7>
            |     {
            |       "AppleClamshellCausesSleep" = Yes
            |     }
            """
        XCTAssertTrue(ClamshellProbe.causesSleep(block) == true)
    }

    func testNoParsesFromRealIoreg() {
        let block = """
            | +-o IOPMrootDomain  <class IOPMrootDomain, id 0x8000203e0, registered, matched, active, busy 0 (0 ms), retain 7>
            |     {
            |       "AppleClamshellCausesSleep" = No
            |     }
            """
        XCTAssertTrue(ClamshellProbe.causesSleep(block) == false)
    }

    func testAbsentPropertyReturnsNil() {
        let block = """
            | +-o IOPMrootDomain  <class IOPMrootDomain, id 0x8000203e0>
            |     { "IORequestPowerState" = 2 }
            """
        XCTAssertNil(ClamshellProbe.causesSleep(block))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(ClamshellProbe.causesSleep(""))
    }

    /// Case-insensitive value matching — the kernel has been observed to capitalise
    /// inconsistently across macOS versions.
    func testLowercaseYesParsesToTrue() {
        let block = "\"AppleClamshellCausesSleep\" = yes"
        XCTAssertTrue(ClamshellProbe.causesSleep(block) == true)
    }

    func testLowercaseNoParsesToFalse() {
        let block = "\"AppleClamshellCausesSleep\" = no"
        XCTAssertTrue(ClamshellProbe.causesSleep(block) == false)
    }

    // MARK: - lever truth table

    func testLeverEffectiveWhenOnAndCausesSleepFalse() {
        XCTAssertEqual(
            ClamshellProbe.lever(isDisableSleepOn: true, causesSleep: false),
            .effective)
    }

    func testLeverIneffectiveWhenOnAndCausesSleepTrue() {
        XCTAssertEqual(
            ClamshellProbe.lever(isDisableSleepOn: true, causesSleep: true),
            .ineffective)
    }

    func testLeverUnknownWhenOff() {
        XCTAssertEqual(
            ClamshellProbe.lever(isDisableSleepOn: false, causesSleep: false),
            .unknown)
    }

    func testLeverUnknownWhenCausesSleepIsNil() {
        XCTAssertEqual(
            ClamshellProbe.lever(isDisableSleepOn: true, causesSleep: nil),
            .unknown)
    }
}

import XCTest
@testable import LiddyKit

/// Rows here are copied from real `ps -Ao pid=,pcpu=,pmem=,comm=` output on this Mac,
/// including the spaced app-bundle paths that broke `ProcessWatcher` the same way.
final class ProcessLoadTest: XCTestCase {
    private let realBlock = """
          401  12.3  1.4 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
          512   6.1  0.9 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/141/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper
          987  33.0  4.2 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
          113   0.4  0.2 /usr/sbin/cfprefsd
        """

    func testParsesEveryFieldOfARealRow() {
        let load = ProcessLoad.parse(realBlock)
        XCTAssertEqual(load.count, 4)
        XCTAssertEqual(load[0].pid, 401)
        XCTAssertEqual(load[0].cpuPercent, 12.3, accuracy: 0.001)
        XCTAssertEqual(load[0].memoryPercent, 1.4, accuracy: 0.001)
    }

    /// The failure this shares with `ProcessWatcher`: a path with spaces is not three
    /// fields and a command, it is three fields and *the rest of the line*.
    func testSpacedPathSurvivesParsing() {
        let load = ProcessLoad.parse(realBlock)
        XCTAssertEqual(load[2].name, "Visual Studio Code")
        XCTAssertEqual(load[3].name, "cfprefsd")
    }

    /// Every Chrome helper reports under the app that owns it, or the list shows eight
    /// rows of noise instead of one 18% answer.
    func testHelperProcessesCollapseOntoTheirApp() {
        let load = ProcessLoad.parse(realBlock)
        XCTAssertEqual(load[0].name, "Google Chrome")
        XCTAssertEqual(load[1].name, "Google Chrome")

        let top = ProcessLoad.top(load, limit: 4, minimumCpuPercent: 0)
        let chrome = top.first { $0.name == "Google Chrome" }
        XCTAssertEqual(chrome?.cpuPercent ?? 0, 18.4, accuracy: 0.001)
        XCTAssertEqual(chrome?.memoryPercent ?? 0, 2.3, accuracy: 0.001)
        XCTAssertEqual(chrome?.pid, 401, "the heaviest member's pid is the useful one")
    }

    func testMalformedRowIsSkippedNotFatal() {
        let load = ProcessLoad.parse("""
            garbage
            401 notanumber 1.4 /usr/bin/true
            402  5.0  1.0 /usr/bin/true
            """)
        XCTAssertEqual(load.count, 1)
        XCTAssertEqual(load[0].pid, 402)
    }

    func testEmptyInputIsEmptyOutput() {
        XCTAssertTrue(ProcessLoad.parse("").isEmpty)
    }

    func testQuietProcessIsDroppedByTheFloor() {
        let top = ProcessLoad.top(ProcessLoad.parse(realBlock), limit: 10, minimumCpuPercent: 5)
        XCTAssertFalse(top.contains { $0.name == "cfprefsd" })
    }

    func testSortedDescendingAndLimited() {
        let top = ProcessLoad.top(ProcessLoad.parse(realBlock), limit: 1, minimumCpuPercent: 0)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].name, "Visual Studio Code", "33% beats Chrome's summed 18.4%")
    }

    /// Two processes at the same percent must not swap places between samples.
    func testTiesBreakOnNameSoTheListHoldsStill() {
        let load = [
            ProcessLoad(pid: 1, name: "Zebra", cpuPercent: 10, memoryPercent: 1),
            ProcessLoad(pid: 2, name: "Alpha", cpuPercent: 10, memoryPercent: 1),
        ]
        XCTAssertEqual(ProcessLoad.top(load, minimumCpuPercent: 0).map(\.name), ["Alpha", "Zebra"])
    }

    func testDisplayIsRounded() {
        let entry = ProcessLoad(pid: 1, name: "Google Chrome", cpuPercent: 41.4, memoryPercent: 3)
        XCTAssertEqual(entry.display, "Google Chrome 41%")
    }
}

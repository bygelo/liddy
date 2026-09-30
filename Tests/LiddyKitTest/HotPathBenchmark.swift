import XCTest
@testable import LiddyKit

/// Times the calls the 5-second runtime tick makes. Prints, never asserts a number:
/// the point is a before/after figure on a real machine, and a wall-clock bound in
/// CI would be a flaky test. Run with `swift test --filter HotPathBenchmark`.
final class HotPathBenchmark: XCTestCase {
    private func time(_ label: String, count: Int = 20, _ body: () -> Void) {
        body() // warm
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<count { body() }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(count)
        print(String(format: "BENCH %-28@ %8.2f ms/call", label as NSString, ms))
    }

    func testTickHotPath() {
        time("ThermalReader.read") { _ = ThermalReader.read() }
        time("BatteryReader.read") { _ = BatteryReader.read() }
        time("ClamshellProbe.isLidClosed") { _ = ClamshellProbe.isLidClosed() }
        time("ProcessLoad.sample", count: 5) { _ = ProcessLoad.sample() }
        time("ProcessWatcher.processTable", count: 5) { _ = ProcessWatcher.processTable() }
        time("SessionScanner.live", count: 5) { _ = SessionScanner.live() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        time("claudeTranscript", count: 5) { _ = SessionScanner.claudeTranscript(root: home.appendingPathComponent(".claude")) }
        time("codexTranscript", count: 5) { _ = SessionScanner.codexTranscript(root: home.appendingPathComponent(".codex")) }
        time("cursorSession", count: 5) { _ = SessionScanner.cursorSession(root: home.appendingPathComponent(".cursor"), live: .init()) }
        time("SessionScanner.scan", count: 5) { _ = SessionScanner.scan(live: SessionScanner.live()) }
    }
}

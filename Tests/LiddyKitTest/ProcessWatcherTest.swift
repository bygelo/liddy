import XCTest
@testable import LiddyKit

/// These cases are all real `ps` rows observed on a normal Mac. Each one was a
/// false positive under substring matching, and each would have held the machine
/// awake indefinitely on an idle desk.
final class ProcessWatcherTest: XCTestCase {
    private func name(_ command: String) -> String {
        ProcessWatcher.executableName(from: command)
    }

    func testExecutableNameStripsPathAndArgument() {
        XCTAssertEqual(name("/Users/me/.local/bin/uv"), "uv")
        XCTAssertEqual(name("npm exec chrome-devtools-mcp@latest"), "npm")
        XCTAssertEqual(name("/Applications/CodexBar.app/Contents/MacOS/CodexBar"), "codexbar")
        XCTAssertEqual(name("python"), "python")
    }

    /// Real rows from `ps -Ao comm=` on macOS 15. An absolute path keeps its spaces;
    /// a bare command still gets its argument stripped. Getting this wrong reduced
    /// "Visual Studio Code" to `visual`, and the watch silently never fired.
    func testExecutableNameKeepsSpacedPathsIntact() {
        XCTAssertEqual(name("/Applications/Visual Studio Code.app/Contents/MacOS/Electron"), "electron")
        XCTAssertEqual(name("/Applications/My App.app/Contents/MacOS/My App"), "my app")
        XCTAssertEqual(name("/System/Library/CoreServices/Software Update.app/Contents/Resources/softwareupdated"), "softwareupdated")
        XCTAssertEqual(name("/usr/bin/python3"), "python3")
        XCTAssertEqual(name("npm"), "npm")
        XCTAssertEqual(name("  /Applications/My App.app/Contents/MacOS/My App  "), "my app")
    }

    /// A spaced path is watchable end to end, which is the whole point of the row.
    func testSpacedPathStillMatchesItsPattern() {
        XCTAssertTrue(ProcessWatcher.matches(
            executableName: name("/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            pattern: "electron"))
        XCTAssertTrue(ProcessWatcher.matches(
            executableName: name("/Users/me/Library/Application Support/Figma/FigmaAgent.app/Contents/MacOS/figma_agent"),
            pattern: "figma_agent"))
    }

    func testSystemDaemonNoLongerMatchesAnUnrelatedPattern() {
        // "appplaceholdersyncd" literally contains "rsync".
        XCTAssertFalse(ProcessWatcher.matches(
            executableName: name("/System/Library/CoreServices/appplaceholdersyncd"),
            pattern: "rsync"))
        XCTAssertFalse(ProcessWatcher.matches(
            executableName: name("/System/Library/Frameworks/Contacts.framework/Support/postersyncd"),
            pattern: "rsync"))
    }

    func testCameraAssistantDoesNotMatchUv() {
        XCTAssertFalse(ProcessWatcher.matches(
            executableName: name(".../UVCAssistant.systemextension/Contents/MacOS/UVCAssistant"),
            pattern: "uv"))
    }

    /// An always-running privileged helper must not read as "a Docker build".
    func testDockerHelperDaemonDoesNotMatchDocker() {
        XCTAssertFalse(ProcessWatcher.matches(
            executableName: name("/Library/PrivilegedHelperTools/com.docker.vmnetd"),
            pattern: "docker"))
    }

    /// A menu-bar app that is open all day must not read as an agent run.
    func testMenuBarAppDoesNotMatchAgentPattern() {
        XCTAssertFalse(ProcessWatcher.matches(
            executableName: name("/Applications/CodexBar.app/Contents/MacOS/CodexBar"),
            pattern: "codex"))
    }

    func testGenuineMatchStillWorks() {
        XCTAssertTrue(ProcessWatcher.matches(executableName: name("/opt/homebrew/bin/claude"), pattern: "claude"))
        XCTAssertTrue(ProcessWatcher.matches(executableName: name("npm exec tsx server.ts"), pattern: "npm"))
        XCTAssertTrue(ProcessWatcher.matches(executableName: name("/Users/me/.local/bin/uv"), pattern: "uv"))
        XCTAssertTrue(ProcessWatcher.matches(executableName: name("docker"), pattern: "docker"))
    }

    /// The one loosening worth keeping: versioned interpreter names.
    func testVersionSuffixStillMatches() {
        XCTAssertTrue(ProcessWatcher.matches(executableName: "python3", pattern: "python"))
        XCTAssertTrue(ProcessWatcher.matches(executableName: "python3.13", pattern: "python"))
        XCTAssertFalse(ProcessWatcher.matches(executableName: "pythonista", pattern: "python"))
    }

    /// Guards against a default list that quietly reintroduces an always-on daemon.
    func testDefaultPatternExcludesServerShapedTool() {
        let pattern = Set(Setting.default.watchPattern)
        for banned in ["ollama", "com.docker.backend", "colima", "lm-studio", "vite"] {
            XCTAssertFalse(pattern.contains(banned),
                           "\(banned) runs continuously — watching it by name holds the Mac awake forever")
        }
    }
}

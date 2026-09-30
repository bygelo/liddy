import XCTest
@testable import LiddyKit

/// The state machine is the feature: a colour per state is only worth having if the
/// state is right. Every case here is one the panel draws differently.
final class SessionStateTest: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(ageSecond: Double, isAlive: Bool = true) -> SessionState {
        AgentSession.state(
            lastActivityAt: now.addingTimeInterval(-ageSecond), now: now, isAlive: isAlive)
    }

    func testFreshTranscriptIsWorking() {
        XCTAssertEqual(state(ageSecond: 0), .working)
        XCTAssertEqual(state(ageSecond: 44), .working)
    }

    /// The state that earns the feature: alive, quiet, recently active — it is your turn.
    func testQuietButRecentIsYourTurn() {
        XCTAssertEqual(state(ageSecond: 46), .waiting)
        XCTAssertEqual(state(ageSecond: 899), .waiting)
    }

    func testLongQuietIsIdle() {
        XCTAssertEqual(state(ageSecond: 901), .idle)
    }

    /// A dead process is ended however fresh its transcript is — a transcript is just
    /// as fresh five seconds after you quit as five seconds before.
    func testDeadProcessIsEndedRegardlessOfFreshness() {
        XCTAssertEqual(state(ageSecond: 0, isAlive: false), .ended)
    }

    /// Clock skew, not prophecy.
    func testFutureStampIsNotIdle() {
        XCTAssertEqual(state(ageSecond: -30), .working)
    }

    func testOrderPutsWorkFirstThenNewest() {
        let old = AgentSession(tool: .claude, sessionId: "a", lastActivityAt: now.addingTimeInterval(-600), state: .waiting)
        let new = AgentSession(tool: .claude, sessionId: "b", lastActivityAt: now, state: .working)
        let running = AgentSession(tool: .grok, sessionId: "c", lastActivityAt: now.addingTimeInterval(-9000), state: .running)
        XCTAssertEqual(AgentSession.ordered([old, running, new]).map(\.sessionId), ["b", "c", "a"])
    }

    func testAgeDisplayIsCoarse() {
        let session = AgentSession(tool: .claude, sessionId: "a", lastActivityAt: now.addingTimeInterval(-90), state: .waiting)
        XCTAssertEqual(session.ageDisplay(now: now), "1m")
    }

    func testProjectNameComesFromTheDirectory() {
        let session = AgentSession(
            tool: .claude, sessionId: "abcdefgh-1234", directory: "/Users/me/Code/liddy",
            lastActivityAt: now, state: .working)
        XCTAssertEqual(session.projectDisplay, "liddy")
    }

    /// A directory containing a dash is why the path is read from the transcript rather
    /// than decoded from Claude's slug directory, which is lossy for exactly this name.
    func testDashedProjectNameSurvives() {
        let session = AgentSession(
            tool: .claude, sessionId: "x", directory: "/Users/me/Code/sisia-app",
            lastActivityAt: now, state: .working)
        XCTAssertEqual(session.projectDisplay, "sisia-app")
    }
}

/// Parsing is done against partial files on purpose — a transcript being written to
/// right now has a truncated last line, and those are the only ones worth reading.
final class SessionScannerTest: XCTestCase {
    func testReadsCwdAndBranchOutOfATruncatedHead() {
        let head = """
            {"type":"mode","mode":"normal","sessionId":"e3ee"}
            {"cwd":"/Users/me/Code/liddy","gitBranch":"main","version":"2.1.268"}
            {"type":"assistant","message":{"content":[{"text":"half a li
            """
        let meta = SessionScanner.metadata(inHead: head)
        XCTAssertEqual(meta.directory, "/Users/me/Code/liddy")
        XCTAssertEqual(meta.branch, "main")
    }

    func testMissingKeyIsNil() {
        let meta = SessionScanner.metadata(inHead: "{\"type\":\"mode\"}")
        XCTAssertNil(meta.directory)
        XCTAssertNil(meta.branch)
    }

    /// Claude names the file after the session uuid; Codex prefixes a timestamp.
    func testSessionIdFromEitherNamingScheme() {
        XCTAssertEqual(
            SessionScanner.sessionId(from: URL(fileURLWithPath: "/x/e3eeadc9-e431-49d9-9a34-fd06a67e4f61.jsonl")),
            "e3eeadc9-e431-49d9-9a34-fd06a67e4f61")
        XCTAssertEqual(
            SessionScanner.sessionId(from: URL(fileURLWithPath: "/x/rollout-2026-09-11T12-04-36-01a08ea3-84da-79c0-b784-15352f23b5b3.jsonl")),
            "01a08ea3-84da-79c0-b784-15352f23b5b3")
    }

    /// Real `lsof -Fn` output. The default table format is unparseable for the paths
    /// that matter here, all of which contain "Application Support".
    func testLsofFieldOutputPairsPidToDirectory() {
        let text = """
            p83418
            n/Users/me/Code/liddy
            p15508
            n/Users/me/Library/Application Support/Cursor/x
            """
        let found = SessionScanner.parseLsof(text)
        XCTAssertEqual(found[83418], "/Users/me/Code/liddy")
        XCTAssertEqual(found[15508], "/Users/me/Library/Application Support/Cursor/x")
    }

    func testCursorUpdatedAtIsMilliseconds() {
        let stamp = SessionScanner.cursorUpdatedAt("{\"schemaVersion\":1,\"updatedAtMs\":1787858565467}")
        XCTAssertEqual(stamp?.timeIntervalSince1970 ?? 0, 1787858565.467, accuracy: 0.01)
    }

    func testCursorMissingStampIsNil() {
        XCTAssertNil(SessionScanner.cursorUpdatedAt("{\"schemaVersion\":1}"))
    }

    /// Liveness falls back to "this tool is running somewhere" when no directory is
    /// known, because calling a live session ended is the worse mistake.
    func testLivenessFallsBackToToolPresence() {
        let live = SessionScanner.Live(directory: [:], tool: [.claude])
        XCTAssertTrue(live.isAlive(tool: .claude, directory: "/anywhere"))
        XCTAssertFalse(live.isAlive(tool: .codex, directory: "/anywhere"))
    }

    func testLivenessMatchesOnDirectoryWhenKnown() {
        let live = SessionScanner.Live(directory: [.claude: ["/Users/me/Code/liddy"]], tool: [.claude])
        XCTAssertTrue(live.isAlive(tool: .claude, directory: "/Users/me/Code/liddy"))
        XCTAssertFalse(live.isAlive(tool: .claude, directory: "/Users/me/Code/other"))
    }
}

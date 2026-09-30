import Foundation

/// A CLI agent Liddy can see sessions for.
///
/// Kept separate from `ServiceEndpoint` — that catalogue is about *APIs* and whether
/// they answer; this one is about *sessions* on this Mac and what they are doing. An
/// agent can have a healthy API and no session, or three sessions and a dead API, and
/// the panel has to be able to say both.
public enum AgentTool: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case cursor
    case grok

    public var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        case .grok:   return "Grok"
        }
    }

    /// Executable names that mean this tool is running, matched by
    /// `ProcessWatcher.matches` against a process basename.
    public var processName: [String] {
        switch self {
        case .claude: return ["claude"]
        case .codex:  return ["codex"]
        case .cursor: return ["cursor-agent"]
        case .grok:   return ["grok"]
        }
    }

    /// Bundle identifiers to look for, best first, so a pill can show the agent's real
    /// icon by asking the system for the copy already installed on this Mac. Measured
    /// from `/Applications` rather than guessed: Cursor ships as a ToDesktop bundle and
    /// Grok's desktop app is `com.anysphere.sand`, neither of which is derivable from
    /// the vendor name.
    public var bundleIdentifier: [String] {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex:  return ["com.openai.codex", "com.openai.chat", "com.steipete.codexbar"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"]
        case .grok:   return ["com.anysphere.sand", "com.x.grok", "ai.x.grok"]
        }
    }

    /// Fallback glyph when the app is not installed.
    public var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex:  return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .grok:   return "bolt.horizontal"
        }
    }

    /// The `service.<id>` this tool's API health is filed under.
    public var serviceId: String {
        switch self {
        case .claude: return "anthropic"
        case .codex:  return "openai"
        case .cursor: return "cursor"
        case .grok:   return "xai"
        }
    }
}

/// What a session is doing, as four states a colour can mean something specific about.
///
/// The distinction that earns the feature is **working vs waiting**. "Waiting" is a
/// session that is alive, has a transcript, and has not written to it — which on every
/// one of these tools means the same thing: it is your turn. That is the state worth
/// a colour, and no existing readout in this app could express it.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    /// Writing to its transcript right now.
    case working
    /// Alive, but this tool publishes no per-turn activity we can read — so "it is
    /// running" is the whole truth and the panel says exactly that. Grok's session
    /// file, for instance, records a pid and an open time and nothing since.
    case running
    /// Alive, quiet, recently active — almost always waiting on you.
    case waiting
    /// Alive but untouched long enough that nobody is in front of it.
    case idle
    /// No live process for it any more.
    case ended

    public var display: String {
        switch self {
        case .working: return "working"
        case .running: return "running"
        case .waiting: return "your turn"
        case .idle:    return "idle"
        case .ended:   return "ended"
        }
    }

    /// Sort weight. Working first, because the panel is read top-down and a run in
    /// progress is why it was opened; "your turn" second, because it is the one that
    /// wants the user to do something.
    public var rank: Int {
        switch self {
        case .working: return 0
        case .running: return 1
        case .waiting: return 2
        case .idle:    return 3
        case .ended:   return 4
        }
    }
}

/// One CLI agent session: which tool, in which project, doing what.
public struct AgentSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var tool: AgentTool
    public var sessionId: String
    /// The working directory the session was started in, straight out of its own
    /// transcript rather than decoded from a directory name.
    public var directory: String?
    public var branch: String?
    public var lastActivityAt: Date
    public var state: SessionState

    public init(
        tool: AgentTool,
        sessionId: String,
        directory: String? = nil,
        branch: String? = nil,
        lastActivityAt: Date,
        state: SessionState
    ) {
        self.id = "\(tool.rawValue):\(sessionId)"
        self.tool = tool
        self.sessionId = sessionId
        self.directory = directory
        self.branch = branch
        self.lastActivityAt = lastActivityAt
        self.state = state
    }

    /// The project name a human would use — the last path component of the working
    /// directory. Falls back to the short session id, which is at least unique.
    public var projectDisplay: String {
        guard let directory, !directory.isEmpty else { return String(sessionId.prefix(8)) }
        return (directory as NSString).lastPathComponent
    }

    /// "4s" / "12m" / "3h". Deliberately coarse: the panel is read at a glance, and a
    /// second-accurate age on a row that refreshes every 15 seconds is a lie anyway.
    public func ageDisplay(now: Date = Date()) -> String {
        let second = max(0, Int(now.timeIntervalSince(lastActivityAt)))
        if second < 60 { return "\(second)s" }
        if second < 3600 { return "\(second / 60)m" }
        return "\(second / 3600)h"
    }

    /// The whole state machine, as a pure function of two facts.
    ///
    /// Transcript mtime rather than CPU: an agent waiting on an API response sits near
    /// 0% CPU while genuinely working, which is the same reason `README` rejects a CPU
    /// floor for the hold itself. A transcript that grew two seconds ago is proof of
    /// work in a way a busy CPU never is.
    ///
    /// - Parameters:
    ///   - isAlive: whether a process for this tool is still running in this directory.
    ///   - workingWithinSecond: how recently the transcript must have grown to count as
    ///     working. 45s covers a long tool call or a slow model turn without flickering.
    ///   - idleAfterSecond: past this, nobody is sitting in front of it.
    public static func state(
        lastActivityAt: Date,
        now: Date,
        isAlive: Bool,
        workingWithinSecond: Int = 45,
        idleAfterSecond: Int = 900
    ) -> SessionState {
        guard isAlive else { return .ended }
        let age = now.timeIntervalSince(lastActivityAt)
        // A transcript stamped in the future is a clock skew, not a prophecy. Treat it
        // as fresh rather than letting a negative age fall through to idle.
        if age <= Double(workingWithinSecond) { return .working }
        if age <= Double(idleAfterSecond) { return .waiting }
        return .idle
    }

    /// Working first, then by most recent activity. Stable, so rows do not swap places
    /// between two samples that agree about everything.
    public static func ordered(_ session: [AgentSession]) -> [AgentSession] {
        session.sorted {
            if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            return $0.id < $1.id
        }
    }
}

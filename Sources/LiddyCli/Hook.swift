import Foundation
import LiddyKit

/// Claude Code integration — the agent-awareness idea taken to its conclusion.
///
/// Process matching asks "does something named `claude` exist?". A hook lets the
/// agent answer the better question: "am I working *right now*?"
///
/// The events matter. Hooking `SessionStart`/`SessionEnd` looks obvious and is wrong:
/// a session sitting open in a terminal overnight would hold the Mac awake with
/// nothing running — the same failure as watching a server process. So the claim is
/// per **turn**: `UserPromptSubmit` claims, `Stop` releases. The Mac is awake exactly
/// while Claude is producing output, and sleeps when it stops.
///
/// `SessionEnd` also releases, as a backstop, and every claim carries a TTL so a
/// crashed session cannot hold the Mac even if no release ever arrives.
enum Hook {
    /// Generous relative to a turn, short relative to a night. If Claude Code dies
    /// mid-turn, the lease expires on its own well before the battery matters.
    static let ttlSecond = 3600

    /// Hooks must never break the session they are attached to. Every path exits 0,
    /// including "Liddy is not running" — a keep-awake tool being absent is not a
    /// reason for someone's prompt to fail.
    static func run(_ argument: [String]) -> Never {
        guard let action = argument.first else {
            FileHandle.standardError.write(Data("usage: liddy hook claim|release|print|install\n".utf8))
            exit(0)
        }

        switch action {
        case "claim":   claimFromStdin()
        case "release": releaseFromStdin()
        case "print":   print(configJson())
        case "install": install(isProject: argument.contains("--project"))
        default:
            FileHandle.standardError.write(Data("liddy hook: unknown action '\(action)'\n".utf8))
        }
        exit(0)
    }

    // MARK: - Runtime side

    /// Claude Code passes the hook payload as JSON on stdin.
    private static func sessionKey() -> (key: String, label: String) {
        let data = FileHandle.standardInput.availableData
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let sessionId = payload?["session_id"] as? String ?? "unknown"
        let cwd = payload?["cwd"] as? String
        let project = cwd.map { ($0 as NSString).lastPathComponent } ?? "claude"
        return ("claude-code:\(sessionId)", "Claude Code · \(project)")
    }

    private static func claimFromStdin() {
        let (key, label) = sessionKey()
        _ = quietRequest(.claim(label: label, ttlSecond: ttlSecond, key: key))
    }

    private static func releaseFromStdin() {
        let (key, _) = sessionKey()
        _ = quietRequest(.releaseKey(key: key))
    }

    /// Best-effort: a missing app is fine and silent.
    private static func quietRequest(_ request: AppRequest) -> AppResponse? {
        let client = LineSocketClient(path: LiddyPath.appSocket.path)
        guard (try? client.connect()) != nil else { return nil }
        return try? client.roundTrip(request, expecting: AppResponse.self)
    }

    // MARK: - Config

    /// Absolute path: hooks do not necessarily run with the user's interactive PATH.
    private static var binaryPath: String {
        let path = CommandLine.arguments[0]
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path).standardized.path
    }

    private static func entry(_ action: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": "\(binaryPath) hook \(action)"]]]
    }

    static func configJson() -> String {
        let config: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [entry("claim")],
                "Stop": [entry("release")],
                "SessionEnd": [entry("release")],
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func install(isProject: Bool) {
        let url = isProject
            ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".claude/settings.json")
            : FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json")

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = parsed
        }

        var hook = root["hooks"] as? [String: Any] ?? [:]
        var addedCount = 0

        for (event, action) in [("UserPromptSubmit", "claim"), ("Stop", "release"), ("SessionEnd", "release")] {
            var list = hook[event] as? [[String: Any]] ?? []
            // Idempotent: re-running install must not stack a second copy.
            let isPresent = list.contains { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains("liddy hook") == true }
            }
            guard !isPresent else { continue }
            list.append(entry(action))
            hook[event] = list
            addedCount += 1
        }
        root["hooks"] = hook

        guard addedCount > 0 else {
            print("Liddy hooks already installed in \(url.path)")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            print("Installed \(addedCount) Liddy hook(s) into \(url.path)")
            print("Claude Code will now hold your Mac awake only while a turn is running.")
        } catch {
            FileHandle.standardError.write(Data("liddy hook: cannot write \(url.path): \(error)\n".utf8))
        }
    }
}

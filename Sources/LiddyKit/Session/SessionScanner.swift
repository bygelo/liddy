import Foundation

/// Finds live CLI agent sessions by reading the transcripts the tools already write.
///
/// **Why files and not processes.** A process tells you `claude` is running; it cannot
/// tell you which project, which branch, how many sessions, or whether the model is
/// mid-turn. Every one of these tools writes a JSONL transcript per session, stamps it
/// with the working directory, and appends to it as the turn progresses — so the
/// filesystem already holds the exact answer the panel wants, and the mtime is a better
/// activity signal than CPU could ever be.
///
/// Processes still matter for one thing: whether the session is *alive*. A transcript
/// is just as fresh five seconds after you quit the CLI as five seconds before, so
/// liveness is matched separately, by directory, in `Live`.
public struct SessionScanner: Sendable {
    /// Ignore transcripts older than this. A day of old sessions is not a status
    /// readout, and walking them costs more than the panel is worth.
    public static let horizonSecond: TimeInterval = 6 * 3600
    /// How much of a transcript to read looking for its metadata. Claude writes `cwd`
    /// within the first few lines; Codex writes it in line one. 64 KiB is far past both
    /// and bounds the read on a transcript that can reach hundreds of megabytes.
    public static let headByte = 64 * 1024

    /// What is running, so a transcript can be told from a session.
    public struct Live: Sendable, Equatable {
        /// Working directories of every live process, per tool.
        public var directory: [AgentTool: Set<String>]
        /// Tools that have at least one live process, even if its directory could not
        /// be read — `lsof` can fail on a process that exits mid-scan.
        public var tool: Set<AgentTool>
        /// Every live pid across the tools, for the sources that name a pid directly.
        public var pid: Set<Int32>

        public init(
            directory: [AgentTool: Set<String>] = [:],
            tool: Set<AgentTool> = [],
            pid: Set<Int32> = []
        ) {
            self.directory = directory
            self.tool = tool
            self.pid = pid
        }

        /// Whether a session in this directory is still running.
        ///
        /// Directory match when we have directories for the tool, tool-presence
        /// otherwise. The fallback is deliberate: reporting a live session as ended is
        /// the worse error of the two, because "ended" is the state a user acts on by
        /// going and restarting something that never stopped.
        public func isAlive(tool: AgentTool, directory path: String?) -> Bool {
            guard let known = self.directory[tool], !known.isEmpty else {
                return self.tool.contains(tool)
            }
            guard let path else { return self.tool.contains(tool) }
            return known.contains(path)
        }
    }

    public init() {}

    // MARK: - Claude Code

    /// `~/.claude/projects/<slug>/<session-uuid>.jsonl`.
    ///
    /// The directory name is a slug of the project path with every `/` replaced by `-`,
    /// which is lossy for any directory that contains a dash — `sisia-app` and
    /// `sisia/app` slug identically. So the path is read from the transcript's own
    /// `cwd` field instead, and the slug is used for nothing.
    public static func claudeTranscript(root: URL, now: Date = Date()) -> [URL] {
        projectTranscript(under: root.appendingPathComponent("projects"), now: now)
    }

    /// Two fixed levels, listed directly, with stale project directories skipped.
    ///
    /// This machine has 2,514 project directories and 6,597 entries beneath them, of
    /// which 47 directories had been touched inside the horizon. Walking all of them
    /// every 15 seconds cost 167 ms; the generic enumerator also descended into each
    /// session's own subdirectory before discarding it.
    ///
    /// A directory's mtime moves when a transcript is *created* in it, not when one is
    /// appended to, so skipping on directory age alone would lose a long run whose file
    /// was created before the horizon — the overnight session this app exists for. Two
    /// things cover that: directories that held a fresh transcript last time are always
    /// re-listed, and every `fullWalkSecond` the whole tree is walked regardless.
    static func projectTranscript(under root: URL, now: Date) -> [URL] {
        let fileManager = FileManager.default
        let key: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let project = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: key, options: [.skipsHiddenFiles])
        else { return [] }

        let cutoff = now.addingTimeInterval(-horizonSecond)
        let isFullWalk = freshDirectory.isFullWalkDue(root: root.path, now: now)
        let known = freshDirectory.known(root: root.path)
        var found: [URL] = []
        var fresh: Set<String> = []

        for directory in project {
            guard let value = try? directory.resourceValues(forKeys: Set(key)),
                  value.isDirectory == true
            else { continue }
            let isRecent = (value.contentModificationDate ?? .distantPast) > cutoff
            guard isFullWalk || isRecent || known.contains(directory.path) else { continue }
            guard let file = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for url in file where url.pathExtension == "jsonl" {
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, modified > cutoff
                else { continue }
                found.append(url)
                fresh.insert(directory.path)
            }
        }
        freshDirectory.record(root: root.path, fresh: fresh, isFullWalk: isFullWalk, now: now)
        return found
    }

    /// How often the pruned walk is replaced by a full one. The pruning is exact for
    /// every case but one: a transcript idle past the horizon that is then appended to
    /// again (a resumed session) in a directory nothing else touched. This bounds how
    /// late that one shows up.
    static let fullWalkSecond: TimeInterval = 120

    /// Per-root memory for `projectTranscript`. A class behind a lock rather than
    /// state on the scanner, because `scan` is a static entry point called from the
    /// runtime queue and from tests.
    final class FreshDirectory: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: Set<String>] = [:]
        private var lastFullWalk: [String: Date] = [:]

        func isFullWalkDue(root: String, now: Date) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let last = lastFullWalk[root] else { return true }
            return now.timeIntervalSince(last) >= SessionScanner.fullWalkSecond || now < last
        }

        func known(root: String) -> Set<String> {
            lock.lock(); defer { lock.unlock() }
            return known[root] ?? []
        }

        func record(root: String, fresh: Set<String>, isFullWalk: Bool, now: Date) {
            lock.lock(); defer { lock.unlock() }
            known[root] = fresh
            if isFullWalk { lastFullWalk[root] = now }
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            known = [:]; lastFullWalk = [:]
        }
    }
    static let freshDirectory = FreshDirectory()

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`.
    public static func codexTranscript(root: URL) -> [URL] {
        jsonl(under: root.appendingPathComponent("sessions"), depth: 4)
    }

    private static func jsonl(under root: URL, depth: Int) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        let cutoff = Date().addingTimeInterval(-horizonSecond)
        for case let url as URL in walker {
            if walker.level > depth { walker.skipDescendants(); continue }
            guard url.pathExtension == "jsonl" else { continue }
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified > cutoff
            else { continue }
            found.append(url)
        }
        return found
    }

    /// Pull `cwd` and `gitBranch` out of a transcript head.
    ///
    /// Hand-rolled rather than `JSONDecoder`: the head is a *partial* file — the last
    /// line is almost always truncated — so anything that insists on well-formed JSON
    /// fails on exactly the transcripts that are being written to right now, which are
    /// the only ones that matter.
    public static func metadata(inHead head: String) -> (directory: String?, branch: String?) {
        (value(of: "cwd", in: head), value(of: "gitBranch", in: head))
    }

    static func value(of key: String, in text: String) -> String? {
        guard let start = text.range(of: "\"\(key)\":\"") else { return nil }
        let tail = text[start.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let found = String(tail[..<end])
        return found.isEmpty ? nil : found
    }

    static func head(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: headByte)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `cwd` and `gitBranch` per transcript path, read once.
    ///
    /// Both are written in a transcript's first lines and never rewritten, so re-reading
    /// 64 KiB of every fresh transcript every 15 seconds re-derived the same two strings.
    /// Bounded by clearing: the fresh set is tens of files, so a cleared cache refills
    /// in one scan.
    final class HeadCache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: (directory: String?, branch: String?)] = [:]

        func metadata(of url: URL) -> (directory: String?, branch: String?) {
            lock.lock()
            if let hit = known[url.path] { lock.unlock(); return hit }
            lock.unlock()
            let read = SessionScanner.metadata(inHead: SessionScanner.head(of: url))
            // A head with no cwd yet is a transcript still being started; do not
            // remember the miss.
            guard read.directory != nil else { return read }
            lock.lock()
            if known.count > 512 { known.removeAll() }
            known[url.path] = read
            lock.unlock()
            return read
        }
    }
    static let headCache = HeadCache()

    /// Build one session per transcript.
    public static func session(
        from transcript: [URL],
        tool: AgentTool,
        live: Live,
        now: Date = Date()
    ) -> [AgentSession] {
        transcript.compactMap { url in
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            else { return nil }

            let (directory, branch) = headCache.metadata(of: url)
            return AgentSession(
                tool: tool,
                sessionId: sessionId(from: url),
                directory: directory,
                branch: branch,
                lastActivityAt: modified,
                state: AgentSession.state(
                    lastActivityAt: modified,
                    now: now,
                    isAlive: live.isAlive(tool: tool, directory: directory)))
        }
    }

    /// Claude names the file after the session UUID; Codex prefixes a timestamp. Both
    /// end in the UUID, so the trailing 36 characters are the id in either case.
    static func sessionId(from url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.count > 36 ? String(name.suffix(36)) : name
    }

    // MARK: - Cursor

    /// `~/.cursor/chats/<workspace-hash>/<session-uuid>/meta.json`.
    ///
    /// Cursor keeps the conversation in a SQLite `store.db` next door, which is not
    /// worth opening: `meta.json` already carries `cwd` and `updatedAtMs`, and the db's
    /// own mtime moves on every write. The later of the two is the activity stamp.
    public static func cursorSession(root: URL, live: Live, now: Date = Date()) -> [AgentSession] {
        let chat = root.appendingPathComponent("chats")
        guard let entry = try? FileManager.default.contentsOfDirectory(
            at: chat, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }

        let cutoff = now.addingTimeInterval(-horizonSecond)
        var found: [AgentSession] = []
        for workspace in entry {
            guard let session = try? FileManager.default.contentsOfDirectory(
                at: workspace, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for directory in session {
                let meta = directory.appendingPathComponent("meta.json")
                let store = directory.appendingPathComponent("store.db")
                // Stat before read. `updatedAtMs` is written into meta.json, so it can
                // be no later than that file's own mtime — a chat whose meta.json and
                // store.db are both older than the horizon cannot be inside it, and
                // most of the 684 chats here are. Reading every meta.json cost 132 ms.
                let metaWritten = (try? meta.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                let storeWritten = (try? store.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard max(metaWritten ?? .distantPast, storeWritten ?? .distantPast) > cutoff else { continue }
                guard let data = try? Data(contentsOf: meta) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                guard let stamp = cursorUpdatedAt(text) else { continue }
                let activity = max(stamp, storeWritten ?? stamp)
                guard activity > cutoff else { continue }

                let cwd = value(of: "cwd", in: text)
                found.append(AgentSession(
                    tool: .cursor,
                    sessionId: directory.lastPathComponent,
                    directory: cwd,
                    branch: nil,
                    lastActivityAt: activity,
                    state: AgentSession.state(
                        lastActivityAt: activity,
                        now: now,
                        isAlive: live.isAlive(tool: .cursor, directory: cwd))))
            }
        }
        return found
    }

    /// `"updatedAtMs":1787858565467` — milliseconds, unquoted, so it needs its own
    /// reader rather than `value(of:)`, which expects a quoted string.
    static func cursorUpdatedAt(_ text: String) -> Date? {
        guard let start = text.range(of: "\"updatedAtMs\":") else { return nil }
        let digit = text[start.upperBound...].prefix { $0.isNumber }
        guard let millisecond = Double(digit), millisecond > 0 else { return nil }
        return Date(timeIntervalSince1970: millisecond / 1000)
    }

    // MARK: - Grok

    /// `~/.grok/active_sessions.json` — the one tool here that publishes its live
    /// sessions outright, with a pid per session. It records no per-turn activity, so
    /// these land in `.running`: alive is all we honestly know.
    public static func grokSession(root: URL, livePid: Set<Int32>, now: Date = Date()) -> [AgentSession] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("active_sessions.json")),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return entry.compactMap { row in
            guard let id = row["session_id"] as? String else { return nil }
            let pid = (row["pid"] as? Int).map(Int32.init)
            // A stale row for a process that exited is the normal state of this file;
            // it is only rewritten when grok next starts or stops a session.
            let isAlive = pid.map { livePid.contains($0) } ?? false
            guard isAlive else { return nil }
            let openedAt = (row["opened_at"] as? String).flatMap(iso.date(from:)) ?? now
            return AgentSession(
                tool: .grok,
                sessionId: id,
                directory: row["cwd"] as? String,
                branch: nil,
                lastActivityAt: openedAt,
                state: .running)
        }
    }

    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Every session on this Mac, newest and busiest first.
    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        live: Live,
        now: Date = Date(),
        limit: Int = 8
    ) -> [AgentSession] {
        var found: [AgentSession] = []
        found += session(
            from: claudeTranscript(root: home.appendingPathComponent(".claude"), now: now),
            tool: .claude, live: live, now: now)
        found += session(
            from: codexTranscript(root: home.appendingPathComponent(".codex")),
            tool: .codex, live: live, now: now)
        found += cursorSession(root: home.appendingPathComponent(".cursor"), live: live, now: now)
        found += grokSession(
            root: home.appendingPathComponent(".grok"), livePid: live.pid, now: now)

        // Ended sessions are dropped rather than listed. The panel answers "what is
        // running", and a list that keeps yesterday's finished runs is the text the
        // user asked to have less of.
        return Array(AgentSession.ordered(found.filter { $0.state != .ended }).prefix(limit))
    }
}

extension SessionScanner {
    /// Which agent processes are running, and where.
    ///
    /// Two shell-outs, both cheap and both on the same 15-second cadence as the load
    /// sample: `ps` for the names, then one `lsof` for every matching pid at once.
    /// Per-pid `lsof` calls would be a dozen forks a tick for a readout.
    public static func live() -> Live {
        var pidByTool: [AgentTool: [Int32]] = [:]
        for row in ProcessWatcher.processTable() {
            let name = ProcessWatcher.executableName(from: row.command)
            for tool in AgentTool.allCases
            where tool.processName.contains(where: { ProcessWatcher.matches(executableName: name, pattern: $0) }) {
                pidByTool[tool, default: []].append(row.pid)
            }
        }
        guard !pidByTool.isEmpty else { return Live() }

        let cwdByPid = workingDirectory(of: pidByTool.values.flatMap { $0 })
        var directory: [AgentTool: Set<String>] = [:]
        for (tool, pid) in pidByTool {
            directory[tool] = Set(pid.compactMap { cwdByPid[$0] })
        }
        return Live(
            directory: directory,
            tool: Set(pidByTool.keys),
            pid: Set(pidByTool.values.flatMap { $0 }))
    }

    /// Read in-process with `PROC_PIDVNODEPATHINFO` — the `lsof -d cwd` spawn this
    /// replaced cost ~110 ms a scan. `parseLsof` stays for its tests and for anyone
    /// diffing against `lsof` by hand.
    static func workingDirectory(of pid: [Int32]) -> [Int32: String] {
        guard !pid.isEmpty else { return [:] }
        return NativeProcess.workingDirectory(of: pid)
    }

    /// `p<pid>` opens a record; the `n<path>` lines that follow belong to it.
    static func parseLsof(_ text: String) -> [Int32: String] {
        var found: [Int32: String] = [:]
        var current: Int32?
        for row in text.split(separator: "\n") {
            guard let marker = row.first else { continue }
            let value = String(row.dropFirst())
            switch marker {
            case "p": current = Int32(value)
            case "n": if let current, found[current] == nil { found[current] = value }
            default: break
            }
        }
        return found
    }
}

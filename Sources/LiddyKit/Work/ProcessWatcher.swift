import Foundation

/// Presence-based process detection.
///
/// The load-bearing decision: a matched process counts as working **by existing**,
/// never by CPU usage. An agent spends most of a long run near 0% CPU waiting on an
/// API response between tool calls, so a CPU threshold would drop the Mac out from
/// under it mid-task — the exact failure this whole tool exists to prevent.
public final class ProcessWatcher {
    private let queue = DispatchQueue(label: "com.liddy.processwatcher")
    private var timer: DispatchSourceTimer?

    public var intervalSecond: Int
    public var pattern: [String]

    /// Called on the watcher queue with the labels currently matched.
    public var onScan: (([String]) -> Void)?

    public init(pattern: [String], intervalSecond: Int = 10) {
        self.pattern = pattern
        self.intervalSecond = intervalSecond
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: self.queue)
            source.schedule(deadline: .now(), repeating: .seconds(self.intervalSecond))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.onScan?(self.scanOnce())
            }
            self.timer = source
            source.resume()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// Returns the matched pattern, not the process name, so the log reads
    /// "claude" rather than a full `comm=` path.
    public func scanOnce() -> [String] {
        let table = TickProfile.measure("processWatch") { Self.processTable() }
        guard !table.isEmpty else { return [] }
        let selfPid = ProcessInfo.processInfo.processIdentifier

        var matched: Set<String> = []
        for row in table where row.pid != selfPid {
            let name = Self.executableName(from: row.command)
            for candidate in pattern where !candidate.isEmpty {
                if Self.matches(executableName: name, pattern: candidate) {
                    matched.insert(candidate)
                }
            }
        }
        return matched.sorted()
    }

    /// Reduce a `ps -Ao comm=` row to the bare executable name.
    ///
    /// `comm=` returns two shapes on the same machine, measured on macOS 15: an
    /// **absolute path**, which may contain spaces and never carries arguments
    /// (`/Applications/Visual Studio Code.app/Contents/MacOS/Electron` — 166 such rows
    /// on this desk), and a **bare command with its argument** for anything invoked
    /// without a path (`npm run dev --host 127.0.0.1`). No absolute row was observed
    /// carrying a flag, so the leading `/` is what decides which rule applies.
    ///
    /// Splitting on the first space unconditionally — the previous implementation —
    /// reduced the spaced-path case to `visual`, so any watched tool installed at a
    /// spaced path silently never matched.
    public static func executableName(from command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed.hasPrefix("/")
            ? trimmed
            : trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? trimmed
        return (token as NSString).lastPathComponent.lowercased()
    }

    /// Exact match on the executable name, with a version suffix allowed.
    ///
    /// Substring matching on the full path is the obvious implementation and it is
    /// wrong in a way that quietly breaks everything: `rsync` matches macOS's own
    /// `appplaceholdersyncd`, `uv` matches `UVCAssistant`, `docker` matches the
    /// always-running `com.docker.vmnetd`. Any one of those holds the Mac awake
    /// permanently on an idle machine — the exact failure this tool exists to avoid.
    ///
    /// The version-suffix rule keeps `python3` and `python3.13` matching `python`,
    /// which is the only loosening that turned out to be worth having.
    public static func matches(executableName: String, pattern: String) -> Bool {
        let wanted = pattern.lowercased()
        if executableName == wanted { return true }
        guard executableName.hasPrefix(wanted) else { return false }
        let suffix = executableName.dropFirst(wanted.count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
    }

    public struct ProcessRow {
        public var pid: Int32
        public var command: String
    }

    /// Read in-process — see `NativeProcess` for why not `ps`, and for how closely the
    /// rows match what `ps -Ao pid=,comm=` printed.
    public static func processTable() -> [ProcessRow] {
        NativeProcess.allPid().compactMap { pid in
            NativeProcess.command(of: pid).map { ProcessRow(pid: pid, command: $0) }
        }
    }
}

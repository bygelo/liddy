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
    /// "claude" rather than a full argv line.
    public func scanOnce() -> [String] {
        let table = Self.processTable()
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

    /// Reduce a `ps` row to the bare executable name: first whitespace-separated
    /// token (`npm exec foo` → `npm`), then its last path component.
    static func executableName(from command: String) -> String {
        let token = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
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
    static func matches(executableName: String, pattern: String) -> Bool {
        let wanted = pattern.lowercased()
        if executableName == wanted { return true }
        guard executableName.hasPrefix(wanted) else { return false }
        let suffix = executableName.dropFirst(wanted.count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
    }

    struct ProcessRow {
        var pid: Int32
        var command: String
    }

    /// `ps` rather than `sysctl(KERN_PROC)`: it is stable across macOS releases, needs
    /// no entitlement, and this runs once every 10 seconds — not a hot path.
    static func processTable() -> [ProcessRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let space = trimmed.firstIndex(of: " "),
                      let pid = Int32(trimmed[trimmed.startIndex..<space])
                else { return nil }
                let command = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
                return ProcessRow(pid: pid, command: command)
            }
    }
}

import Foundation

/// One process's share of the machine, and the aggregation that makes that readable.
///
/// This is the "what is hampering performance" half of the panel. It deliberately does
/// **not** feed any decision: `README` §Agent awareness rejects CPU-threshold detection
/// outright, because an agent waiting on an API sits near 0% CPU and a CPU floor would
/// drop the Mac mid-task. Showing the user which app is cooking their laptop is a
/// different question from deciding whether to stay awake, and only the first one is
/// answered here.
public struct ProcessLoad: Codable, Sendable, Equatable {
    public var pid: Int32
    /// The app the user would recognise — "Google Chrome", not "Google Chrome Helper
    /// (Renderer)". See `appName(from:)`.
    public var name: String
    public var cpuPercent: Double
    public var memoryPercent: Double

    public init(pid: Int32, name: String, cpuPercent: Double, memoryPercent: Double) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
    }

    /// "Google Chrome 41%" — the shape the panel row needs, rounded because a tenth of
    /// a percent of CPU is noise dressed as precision.
    public var display: String { "\(name) \(Int(cpuPercent.rounded()))%" }

    /// `ps` rather than `host_processor_info` or a libproc walk: the same argument
    /// `ProcessWatcher` makes at its own call site — stable across releases, no
    /// entitlement, and this runs once every few seconds, not in a loop.
    /// One `ps` invocation, shared.
    ///
    /// Measured: `ps -Ao pid=,comm=` costs 6.8ms, the same call with `pcpu`/`pmem`
    /// costs 96ms — the percentages are what is expensive, not the process walk. The
    /// watcher only needs names, so it now reads this sample rather than forking its
    /// own; that removes a fork every 10 seconds and keeps the two views of the
    /// process table from disagreeing about what was running.
    public static func sample() -> [ProcessLoad] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,pcpu=,pmem=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Split exactly three fields off the front and treat everything after as the
    /// command.
    ///
    /// The command is a path that may contain spaces — 166 such rows on this machine —
    /// so a naive `split(separator: " ")` truncates `/Applications/Visual Studio
    /// Code.app/...` at "Visual". This is the same trap `ProcessWatcher` fell into.
    public static func parse(_ text: String) -> [ProcessLoad] {
        text.split(separator: "\n").compactMap { row -> ProcessLoad? in
            var field = row.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard field.count == 4 else { return nil }
            let command = String(field.removeLast())
            guard let pid = Int32(field[0]),
                  let cpu = Double(field[1]),
                  let memory = Double(field[2])
            else { return nil }
            return ProcessLoad(
                pid: pid,
                name: appName(from: command),
                cpuPercent: cpu,
                memoryPercent: memory)
        }
    }

    /// The owning app bundle's name, keeping its capitalisation.
    ///
    /// `ProcessWatcher.executableName(from:)` lowercases and takes the last path
    /// component, which is right for matching a watch pattern and wrong for a label a
    /// human reads. It also splits Chrome into a dozen entries: the renderers live at
    /// `…/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/Contents/MacOS/…`.
    /// Taking the **first** `.app` component collapses every helper back onto the app
    /// that owns them, which is the only grouping that makes the list worth reading.
    public static func appName(from command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        for component in trimmed.split(separator: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return (trimmed as NSString).lastPathComponent
    }

    /// Every process's CPU share summed and divided by the core count.
    ///
    /// `ps` reports `%cpu` per *core* — a single thread pinning one core of a ten-core
    /// machine reports 100%, not 10% — so the raw sum routinely exceeds 100 and is not
    /// a system load until it is divided. Clamped, because the sum of sampled averages
    /// can overshoot slightly.
    public static func systemCpuPercent(_ load: [ProcessLoad], coreCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Double {
        guard coreCount > 0 else { return 0 }
        let total = load.reduce(0) { $0 + $1.cpuPercent }
        return min(100, max(0, total / Double(coreCount)))
    }

    /// Collapse per-name, drop the quiet, and keep the loudest few.
    ///
    /// Summing is the point: Chrome's cost is the sum of its helpers, and a list that
    /// shows eight rows of "Google Chrome Helper" at 6% each hides the 48% answer.
    public static func top(
        _ load: [ProcessLoad],
        limit: Int = 3,
        minimumCpuPercent: Double = 5
    ) -> [ProcessLoad] {
        var merged: [String: ProcessLoad] = [:]
        for entry in load {
            guard var existing = merged[entry.name] else {
                merged[entry.name] = entry
                continue
            }
            // Keep the heaviest member's pid: it is the one worth quitting or
            // sampling if the user goes looking.
            if entry.cpuPercent > existing.cpuPercent { existing.pid = entry.pid }
            existing.cpuPercent += entry.cpuPercent
            existing.memoryPercent += entry.memoryPercent
            merged[entry.name] = existing
        }

        return merged.values
            .filter { $0.cpuPercent >= minimumCpuPercent }
            // Name as the tiebreak so the order is stable between samples; without it
            // two processes at the same percent swap places every few seconds and the
            // list appears to twitch on an idle machine.
            .sorted { ($0.cpuPercent, $1.name) > ($1.cpuPercent, $0.name) }
            .prefix(limit)
            .map { $0 }
    }
}

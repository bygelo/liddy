import Foundation

/// One line in the activity log. Append-only JSONL so the CLI, the menu bar and
/// `tail -f` all read the same file without a database.
public struct LogEntry: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case holdStarted
        case holdStopped
        case clamshellOn
        case clamshellOff
        case leaseAdded
        case leaseRemoved
        case safetyWarned
        case helperReverted
        case note
    }

    public var at: Date
    public var kind: Kind
    public var detail: String
    public var reason: StopReason?
    public var batteryPercent: Int?
    public var thermal: ThermalLevel?

    public init(
        at: Date = Date(),
        kind: Kind,
        detail: String,
        reason: StopReason? = nil,
        batteryPercent: Int? = nil,
        thermal: ThermalLevel? = nil
    ) {
        self.at = at
        self.kind = kind
        self.detail = detail
        self.reason = reason
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }
}

/// Append-only JSONL writer with a bounded tail read.
public final class ActivityLog {
    private let url: URL
    private let queue = DispatchQueue(label: "com.liddy.activitylog")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(url: URL = LiddyPath.activityLog) {
        self.url = url
        try? LiddyPath.ensureSupportDirectory()
    }

    public func append(_ entry: LogEntry) {
        queue.async { [url, encoder] in
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    /// Newest first, capped. Reads the whole file — fine at the sizes this reaches,
    /// and rotation is a follow-up rather than a v0 concern.
    public func recent(limit: Int = 50) -> [LogEntry] {
        queue.sync {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text
                .split(separator: "\n")
                .suffix(limit)
                .reversed()
                .compactMap { try? decoder.decode(LogEntry.self, from: Data($0.utf8)) }
        }
    }
}

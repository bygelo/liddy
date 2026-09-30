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

    /// Past this the file is rotated to `activity.1.jsonl` (one generation kept). The
    /// log had reached 488 KB after two weeks with nothing bounding it.
    public static let rotateByte: UInt64 = 1 << 20

    public func append(_ entry: LogEntry) {
        queue.async { [self] in
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let end = (try? handle.seekToEnd()) ?? 0
                try? handle.write(contentsOf: line)
                if end + UInt64(line.count) > Self.rotateByte { rotateLocked() }
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    private func rotateLocked() {
        let old = url.deletingPathExtension().appendingPathExtension("1.jsonl")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        cache = nil
    }

    /// Newest first, capped.
    ///
    /// Reads only the file's tail, and only when its size moved. The panel asks for
    /// this on every 5-second publish, and it used to read and split the whole file
    /// each time — half a megabyte, twelve times a minute, to show twelve lines. The
    /// size check keeps it right when another process (the CLI) appended.
    public func recent(limit: Int = 50) -> [LogEntry] {
        queue.sync {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if let cache, cache.size == size, cache.limit >= limit {
                return Array(cache.entry.prefix(limit))
            }
            // Log lines are a few hundred bytes; 1 KiB per wanted line is ample, and a
            // partial first line is dropped by the decode.
            let want = UInt64(max(limit, 1) * 1024)
            try? handle.seek(toOffset: size > want ? size - want : 0)
            let data = (try? handle.readToEnd()) ?? Data()
            let entry = data
                .split(separator: 0x0A)
                .suffix(limit)
                .reversed()
                .compactMap { try? decoder.decode(LogEntry.self, from: Data($0)) }
            cache = (size, limit, Array(entry))
            return Array(entry)
        }
    }

    private var cache: (size: UInt64, limit: Int, entry: [LogEntry])?
}

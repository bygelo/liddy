import Foundation

// MARK: - App ↔ CLI

/// Everything `liddy` can ask the running app to do. The app owns all state; the CLI
/// is a thin client, so a script and the menu bar always read one shared truth.
public enum AppRequest: Codable, Sendable {
    case status
    case start(second: Int?, mode: HoldMode)
    case stop
    case clamshell(isOn: Bool, second: Int?, mode: HoldMode)
    case autowatch(isOn: Bool)
    case watch(pattern: String)
    case unwatch(pattern: String)
    case pattern
    /// Explicit work lease — the agent-awareness path. An agent declares it is busy
    /// instead of being inferred from a process name at 0% CPU.
    case claim(label: String, ttlSecond: Int)
    case renew(token: String, ttlSecond: Int)
    case release(token: String)
    case lease
    case recentLog(limit: Int)
    case notify(title: String, body: String)
}

public enum AppResponse: Codable, Sendable {
    case ok(String)
    case failed(String)
    case snapshot(RuntimeSnapshot)
    case token(String)
    case text([String])
    case log([LogEntry])
}

// MARK: - App ↔ root helper

/// The privileged surface, kept as small as it can possibly be: two power settings
/// and a heartbeat. The helper does not run arbitrary commands on the app's behalf.
public enum HelperRequest: Codable, Sendable {
    /// Set `pmset -a disablesleep`. The helper starts a deadman timer when turning on.
    case setClamshell(isOn: Bool)
    /// Keep the deadman switch fed. Miss it and the helper reverts on its own.
    case heartbeat
    /// `pmset sleepnow` — the hard battery floor, which must win over every assertion.
    case sleepNow(reason: String)
    case status
}

public struct HelperStatus: Codable, Sendable {
    public var isClamshellOn: Bool
    public var isOwnedByLiddy: Bool
    public var secondSinceHeartbeat: Int?
    public var version: String

    public init(isClamshellOn: Bool, isOwnedByLiddy: Bool, secondSinceHeartbeat: Int?, version: String) {
        self.isClamshellOn = isClamshellOn
        self.isOwnedByLiddy = isOwnedByLiddy
        self.secondSinceHeartbeat = secondSinceHeartbeat
        self.version = version
    }
}

public enum HelperResponse: Codable, Sendable {
    case ok
    case failed(String)
    case status(HelperStatus)
}

// MARK: - Framing

public enum Wire {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// One JSON object per line. Newline framing keeps the protocol debuggable with `nc`.
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try decoder.decode(type, from: line)
    }
}

public enum SocketError: LocalizedError {
    case cannotCreate(String)
    case cannotBind(String)
    case cannotConnect(String)
    case timedOut
    case closed

    public var errorDescription: String? {
        switch self {
        case .cannotCreate(let m): return "cannot create socket: \(m)"
        case .cannotBind(let m):   return "cannot bind socket: \(m)"
        case .cannotConnect(let m):return "cannot connect: \(m)"
        case .timedOut:            return "timed out"
        case .closed:              return "connection closed"
        }
    }
}

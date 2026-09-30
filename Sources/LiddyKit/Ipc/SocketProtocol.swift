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
    ///
    /// `key` makes a claim idempotent: claiming twice with the same key renews the
    /// one lease rather than stacking two. That is what lets a hook fire on every
    /// turn without leaking a lease per turn.
    case claim(label: String, ttlSecond: Int, key: String?)
    case renew(token: String, ttlSecond: Int)
    case release(token: String)
    case releaseKey(key: String)
    case lease
    case recentLog(limit: Int)
    case notify(title: String, body: String)
    case settingList
    case updateSetting(SettingPatch)
    /// Waive the releasable safety rules for a bounded window. Never reaches the hard
    /// battery floor or critical heat behind a shut lid — see `SafetyGovernor`.
    case override(second: Int?)
    /// The same sweep the menu bar draws, as text. Shares one implementation with the
    /// panel so a script and the UI can never disagree about what is broken.
    case health
}

/// Only the fields a caller actually passed. Anything nil is left alone, so
/// `liddy set --soft-battery 25` cannot silently reset every other threshold.
public struct SettingPatch: Codable, Sendable {
    public var softBatteryPercent: Int?
    public var hardBatteryPercent: Int?
    public var idleReleaseSecond: Int?
    public var isChargingOnly: Bool?
    public var thermalCeiling: ThermalLevel?
    public var isNetworkProbeOn: Bool?
    public var isHealthPanelOn: Bool?
    public var isLidBrightnessOff: Bool?
    public var isResourceSaverOn: Bool?
    public var backgroundApp: [String]?

    public init(
        softBatteryPercent: Int? = nil,
        hardBatteryPercent: Int? = nil,
        idleReleaseSecond: Int? = nil,
        isChargingOnly: Bool? = nil,
        thermalCeiling: ThermalLevel? = nil,
        isNetworkProbeOn: Bool? = nil,
        isHealthPanelOn: Bool? = nil,
        isLidBrightnessOff: Bool? = nil,
        isResourceSaverOn: Bool? = nil,
        backgroundApp: [String]? = nil
    ) {
        self.softBatteryPercent = softBatteryPercent
        self.hardBatteryPercent = hardBatteryPercent
        self.idleReleaseSecond = idleReleaseSecond
        self.isChargingOnly = isChargingOnly
        self.thermalCeiling = thermalCeiling
        self.isNetworkProbeOn = isNetworkProbeOn
        self.isHealthPanelOn = isHealthPanelOn
        self.isLidBrightnessOff = isLidBrightnessOff
        self.isResourceSaverOn = isResourceSaverOn
        self.backgroundApp = backgroundApp
    }

    public var isEmpty: Bool {
        softBatteryPercent == nil && hardBatteryPercent == nil && idleReleaseSecond == nil
            && isChargingOnly == nil && thermalCeiling == nil && isNetworkProbeOn == nil
            && isHealthPanelOn == nil && isLidBrightnessOff == nil && isResourceSaverOn == nil && backgroundApp == nil
    }

    public func applied(to setting: Setting) -> Setting {
        var copy = setting
        if let softBatteryPercent { copy.softBatteryPercent = softBatteryPercent }
        if let hardBatteryPercent { copy.hardBatteryPercent = hardBatteryPercent }
        if let idleReleaseSecond { copy.idleReleaseSecond = idleReleaseSecond }
        if let isChargingOnly { copy.isChargingOnly = isChargingOnly }
        if let thermalCeiling { copy.thermalCeiling = thermalCeiling }
        if let isNetworkProbeOn { copy.isNetworkProbeOn = isNetworkProbeOn }
        if let isHealthPanelOn { copy.isHealthPanelOn = isHealthPanelOn }
        if let isLidBrightnessOff { copy.isLidBrightnessOff = isLidBrightnessOff }
        if let isResourceSaverOn { copy.isResourceSaverOn = isResourceSaverOn }
        if let backgroundApp { copy.backgroundApp = backgroundApp }
        return copy.normalized()
    }
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

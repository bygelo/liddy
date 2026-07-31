import Foundation

/// How a hold behaves once the work it was protecting goes quiet.
public enum HoldMode: String, Codable, Sendable, CaseIterable {
    /// Release the Mac once no lease has been active for `idleReleaseSecond`.
    case smart
    /// Hold for the full requested window regardless of what is running.
    case manual
}

/// Why a hold ended. Every session records exactly one of these — the whole point
/// is that a run which stopped overnight is never a mystery in the morning.
public enum StopReason: String, Codable, Sendable {
    case workFinished
    case timerExpired
    case batteryFloor
    case thermalCritical
    case userStopped
    case appQuit
    /// The helper's deadman switch fired: the app stopped heartbeating.
    case heartbeatLost

    public var summary: String {
        switch self {
        case .workFinished:     return "All watched work finished"
        case .timerExpired:     return "Session timer expired"
        case .batteryFloor:     return "Battery crossed the floor"
        case .thermalCritical:  return "Thermal state critical"
        case .userStopped:      return "Stopped by you"
        case .appQuit:          return "Liddy quit"
        case .heartbeatLost:    return "Heartbeat lost — reverted by helper"
        }
    }
}

/// Everything the menu bar, the CLI and the log need to answer "why is my Mac awake?".
public struct RuntimeSnapshot: Codable, Sendable {
    public var isAwakeHeld: Bool
    public var isAssertionActive: Bool
    public var isClamshellActive: Bool
    public var mode: HoldMode
    public var startedAt: Date?
    public var expiresAt: Date?
    /// Labels of every lease currently keeping the Mac awake. Singular by convention.
    public var activeLease: [String]
    public var battery: BatteryReading
    public var thermal: ThermalReading
    public var lastStopReason: StopReason?

    public init(
        isAwakeHeld: Bool = false,
        isAssertionActive: Bool = false,
        isClamshellActive: Bool = false,
        mode: HoldMode = .smart,
        startedAt: Date? = nil,
        expiresAt: Date? = nil,
        activeLease: [String] = [],
        battery: BatteryReading = .unknown,
        thermal: ThermalReading = .init(level: .nominal),
        lastStopReason: StopReason? = nil
    ) {
        self.isAwakeHeld = isAwakeHeld
        self.isAssertionActive = isAssertionActive
        self.isClamshellActive = isClamshellActive
        self.mode = mode
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.activeLease = activeLease
        self.battery = battery
        self.thermal = thermal
        self.lastStopReason = lastStopReason
    }

    public var runtimeSecond: Int {
        guard let startedAt else { return 0 }
        return Int(Date().timeIntervalSince(startedAt))
    }
}

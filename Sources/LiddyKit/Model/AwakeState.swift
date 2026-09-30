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
    case chargingOnly

    public var summary: String {
        switch self {
        case .workFinished:     return "All watched work finished"
        case .timerExpired:     return "Session timer expired"
        case .batteryFloor:     return "Battery crossed the floor"
        case .thermalCritical:  return "Thermal state critical"
        case .userStopped:      return "Stopped by you"
        case .appQuit:          return "Liddy quit"
        case .heartbeatLost:    return "Heartbeat lost, reverted by helper"
        case .chargingOnly:     return "Unplugged in charging-only mode"
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
    /// The last completed health sweep. nil until the first one lands, which is why
    /// the panel draws a "checking" state rather than a wall of green on open.
    public var health: HealthReport?
    /// Non-nil while the governor is refusing to let anything re-acquire a hold. The
    /// difference between "nothing wants the Mac awake" and "something does, and it is
    /// not being allowed" is the single most confusing state this tool has, so it is
    /// carried explicitly rather than inferred.
    public var blockedBy: StopReason?
    public var isAutoWatchOn: Bool
    /// The user turned the hold off by hand and nothing automatic may turn it back on.
    public var isUserPaused: Bool
    /// When "keep going anyway" lapses. nil when no override is running.
    public var overrideUntil: Date?
    /// The heaviest few apps right now, already collapsed per app. Visibility only —
    /// nothing in the governor reads this, deliberately (see `ProcessLoad`).
    public var topLoad: [ProcessLoad]
    /// Apps the resource saver is currently holding in the background, so the panel can
    /// say what it took rather than leaving the user to notice.
    public var backgroundedApp: [String]
    /// The backlight level the dimmer will restore when the lid opens, nil when it is
    /// not holding the panel down.
    public var dimmedFrom: Double?
    /// Whole-machine CPU, 0-100. Display only, like the temperature.
    public var cpuPercent: Double?
    /// Live CLI agent sessions — Tab Warden. Ordered working-first by `SessionScanner`.
    public var session: [AgentSession]

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
        lastStopReason: StopReason? = nil,
        health: HealthReport? = nil,
        blockedBy: StopReason? = nil,
        isAutoWatchOn: Bool = true,
        isUserPaused: Bool = false,
        overrideUntil: Date? = nil,
        topLoad: [ProcessLoad] = [],
        backgroundedApp: [String] = [],
        dimmedFrom: Double? = nil,
        session: [AgentSession] = [],
        cpuPercent: Double? = nil
    ) {
        self.session = session
        self.cpuPercent = cpuPercent
        self.topLoad = topLoad
        self.backgroundedApp = backgroundedApp
        self.dimmedFrom = dimmedFrom
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
        self.health = health
        self.blockedBy = blockedBy
        self.isAutoWatchOn = isAutoWatchOn
        self.isUserPaused = isUserPaused
        self.overrideUntil = overrideUntil
    }

    public var runtimeSecond: Int {
        guard let startedAt else { return 0 }
        return Int(Date().timeIntervalSince(startedAt))
    }

    /// How far through a timed session we are, 0...1. nil when nothing is timed —
    /// a smart-mode hold has no end to fill a bar toward.
    public var timerFraction: Double? {
        guard let startedAt, let expiresAt else { return nil }
        let total = expiresAt.timeIntervalSince(startedAt)
        guard total > 0 else { return nil }
        return min(1, max(0, Date().timeIntervalSince(startedAt) / total))
    }

    /// Rounded, not truncated. `Int()` throws away the fractional second, so a timer
    /// set to 8h reports 28799 the instant it starts and the menu reads "7h 59m left"
    /// — which looks like the button lost a minute somewhere.
    public var remainingSecond: Int? {
        guard let expiresAt else { return nil }
        return max(0, Int(expiresAt.timeIntervalSinceNow.rounded()))
    }

    /// How a countdown is written in the menu, split by where it is written.
    ///
    /// Lives here rather than in the view because it is pure string work with real
    /// edge cases — zero-padding, the last minute, the hour boundary — and a view is
    /// not a testable place to keep any of them.
    public struct RemainingDisplay: Equatable, Sendable {
        /// Goes inside the ring. **At most two digits**, so a fixed-width circle never
        /// has to scale its own type to fit — see `RingGauge`.
        public var value: String
        /// One character, beside the value.
        public var unit: String
        /// Goes under the ring, where there is room for the precision the ring drops.
        public var caption: String
    }

    public var remainingDisplay: RemainingDisplay? {
        guard timerFraction != nil, let second = remainingSecond else { return nil }
        let hour = second / 3600
        let minute = (second % 3600) / 60

        if hour > 0 {
            return RemainingDisplay(
                value: "\(hour)",
                unit: "h",
                // Zero-padded: an unpadded format wrote 8h00m as "8h0" and 7h05m as "7h5".
                caption: "\(hour)h \(String(format: "%02d", minute))m left")
        }
        if second == 0 {
            return RemainingDisplay(value: "0", unit: "m", caption: "releasing")
        }
        // Rounded up, so the final seconds read "1m" and not a "0m" that is still
        // holding — and the caption agrees with the ring rather than contradicting it.
        let roundedMinute = Int((Double(second) / 60).rounded(.up))
        return RemainingDisplay(
            value: "\(roundedMinute)",
            unit: "m",
            caption: second < 60 ? "under a minute left" : "\(minute)m left")
    }
}

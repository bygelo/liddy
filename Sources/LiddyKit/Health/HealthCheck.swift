import Foundation

/// The verdict of a single check. Ordered by how much it should worry you, which is
/// what makes `worst` a one-liner.
///
/// `.off` is deliberately *below* `.ok`: a check the user switched off must never
/// drag the overall verdict down, and a rolled-up group of nothing-but-off checks is
/// itself off rather than green.
public enum HealthState: String, Codable, Sendable, Comparable, CaseIterable {
    /// The check was not run — probing is disabled, or nothing needs it yet.
    case off
    case ok
    /// Ran, but the answer is not usable yet (first tick, still estimating).
    case unknown
    /// Working, but not the way it should be — slow, degraded, or reported as such.
    case degraded
    /// Not working.
    case down

    public var rank: Int {
        switch self {
        case .off:      return 0
        case .ok:       return 1
        case .unknown:  return 2
        case .degraded: return 3
        case .down:     return 4
        }
    }

    public static func < (lhs: HealthState, rhs: HealthState) -> Bool { lhs.rank < rhs.rank }

    public var display: String {
        switch self {
        case .off:      return "Off"
        case .ok:       return "OK"
        case .unknown:  return "Unknown"
        case .degraded: return "Degraded"
        case .down:     return "Down"
        }
    }

    /// SF Symbol for the dot beside a check row.
    public var symbolName: String {
        switch self {
        case .off:      return "minus.circle"
        case .ok:       return "checkmark.circle.fill"
        case .unknown:  return "questionmark.circle"
        case .degraded: return "exclamationmark.triangle.fill"
        case .down:     return "xmark.octagon.fill"
        }
    }

    /// Terminal glyph, for `liddy health` and `liddy doctor`.
    public var mark: String {
        switch self {
        case .off:      return "-"
        case .ok:       return "✓"
        case .unknown:  return "?"
        case .degraded: return "!"
        case .down:     return "✗"
        }
    }
}

/// Which panel section a check belongs to. Order is display order.
public enum HealthGroup: String, Codable, Sendable, CaseIterable {
    /// Liddy's own plumbing — the parts that make a hold trustworthy.
    case liddy
    /// The machine underneath: power, heat, disk.
    case device
    /// Link, DNS, internet.
    case network
    /// The services the work being protected actually depends on.
    case service

    public var display: String {
        switch self {
        case .liddy:   return "Liddy"
        case .device:  return "Device"
        case .network: return "Network"
        case .service: return "Service"
        }
    }
}

/// One answered question. `id` is stable across probe cycles so SwiftUI can animate a
/// row changing state instead of tearing the list down and rebuilding it.
/// A failing check's way out.
///
/// A diagnosis with no next step leaves the user stuck: the panel says "not in
/// /Applications" and the only way forward is to know what that means. Every remedy
/// here is one click that either fixes the thing or opens the exact place it is fixed —
/// never a dead end, and never a shell command the user has to retype.
public enum HealthRemedy: String, Codable, Sendable {
    /// Install the bundled root helper via the system authorisation prompt.
    case installHelper
    /// Reveal Liddy.app so it can be dragged to /Applications.
    case revealApp
    /// Open System Settings at Login Items.
    case openLoginItem
    /// Write the Claude Code hook.
    case installHook
    /// Clear a `disablesleep` nothing is watching.
    case clearDisableSleep
    /// Re-run every check now.
    case refresh
    /// The provider's own status page.
    case openStatusPage

    /// The button's label. A verb, so the row reads "Install…" rather than "Helper".
    public var title: String {
        switch self {
        case .installHelper:     return "Install…"
        case .revealApp:         return "Show in Finder"
        case .openLoginItem:     return "Open Settings"
        case .installHook:       return "Install hook"
        case .clearDisableSleep: return "Clear it"
        case .refresh:           return "Re-check"
        case .openStatusPage:    return "Status page"
        }
    }
}

public struct HealthCheck: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var group: HealthGroup
    public var label: String
    public var state: HealthState
    public var detail: String
    /// Round-trip time for checks that make a request. nil for local ones.
    public var latencyMillisecond: Int?
    /// What to offer when this check is not green. nil when there is genuinely nothing
    /// the app can do, which is rarer than it looks.
    public var remedy: HealthRemedy?

    public init(
        id: String,
        group: HealthGroup,
        label: String,
        state: HealthState,
        detail: String,
        latencyMillisecond: Int? = nil,
        remedy: HealthRemedy? = nil
    ) {
        self.remedy = remedy
        self.id = id
        self.group = group
        self.label = label
        self.state = state
        self.detail = detail
        self.latencyMillisecond = latencyMillisecond
    }

    public var line: String {
        let latency = latencyMillisecond.map { " (\($0)ms)" } ?? ""
        return "\(state.mark) \(label.padding(toLength: 20, withPad: " ", startingAt: 0)) \(detail)\(latency)"
    }
}

/// Everything the health panel draws, plus when it was taken.
public struct HealthReport: Codable, Sendable, Equatable {
    public var check: [HealthCheck]
    public var at: Date

    public init(check: [HealthCheck] = [], at: Date = Date()) {
        self.check = check
        self.at = at
    }

    public func check(in group: HealthGroup) -> [HealthCheck] {
        check.filter { $0.group == group }
    }

    /// The verdict for a group, and for the panel as a whole: the worst thing in it.
    /// One broken check is not averaged away by nine working ones.
    public func state(of group: HealthGroup) -> HealthState {
        Self.worst(of: check(in: group))
    }

    public var overall: HealthState { Self.worst(of: check) }

    public static func worst(of check: [HealthCheck]) -> HealthState {
        check.map(\.state).max() ?? .off
    }

    /// Checks worth interrupting someone about, worst first.
    public var problem: [HealthCheck] {
        check.filter { $0.state >= .degraded }.sorted { $0.state > $1.state }
    }
}

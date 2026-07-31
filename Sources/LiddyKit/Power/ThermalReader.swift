import Foundation

/// macOS's own thermal pressure signal, relabelled for humans.
///
/// Deliberately *only* this signal: third-party fan control is restricted on Apple
/// silicon, and reading SMC temperature directly has proven to misfire (a capped CPU
/// clock on a power-starved Intel Mac reads as heat when the machine is actually cool).
/// Liddy manages risk from the state the OS reports; it does not override hardware.
public enum ThermalLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    public var rank: Int {
        switch self {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        }
    }

    public var display: String {
        switch self {
        case .nominal:  return "Normal"
        case .fair:     return "Fair"
        case .serious:  return "Hot"
        case .critical: return "Very hot"
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rank < rhs.rank }

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:  self = .nominal
        case .fair:     self = .fair
        case .serious:  self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

public struct ThermalReading: Codable, Sendable, Equatable {
    public var level: ThermalLevel
    public init(level: ThermalLevel) { self.level = level }
}

public enum ThermalReader {
    public static func read() -> ThermalReading {
        ThermalReading(level: ThermalLevel(ProcessInfo.processInfo.thermalState))
    }
}

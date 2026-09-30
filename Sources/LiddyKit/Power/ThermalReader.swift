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
    /// macOS's throttling-pressure signal. Still the only input the governor acts on.
    public var level: ThermalLevel
    /// Die temperature, when it can be read. Display only — see `TemperatureReader`
    /// for why the two are kept apart rather than one derived from the other.
    public var celsius: Double?

    public init(level: ThermalLevel, celsius: Double? = nil) {
        self.level = level
        self.celsius = celsius
    }

    /// "84°", or the pressure word when no sensor answered.
    public var display: String {
        TemperatureReader.display(celsius) ?? level.display
    }
}

public enum ThermalReader {
    /// `ProcessInfo.thermalState` is not a field read.
    ///
    /// Measured in the running app at **13-15ms a call** — it crosses to `powerd` —
    /// and the tick called it twelve times a minute, which made it the single largest
    /// remaining cost after the sensor work. Foundation posts
    /// `thermalStateDidChangeNotification` whenever it changes, so the value is read
    /// once at startup and then only when the OS says it moved. Between notifications
    /// the cached answer is not stale, it is *the* answer.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var level: ThermalLevel?
        var observer: NSObjectProtocol?
    }
    private static let cache = Cache()

    private static func level() -> ThermalLevel {
        cache.lock.lock()
        if let known = cache.level {
            cache.lock.unlock()
            return known
        }
        if cache.observer == nil {
            cache.observer = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                cache.lock.lock()
                cache.level = ThermalLevel(ProcessInfo.processInfo.thermalState)
                cache.lock.unlock()
            }
        }
        cache.lock.unlock()

        let fresh = ThermalLevel(ProcessInfo.processInfo.thermalState)
        cache.lock.lock()
        cache.level = fresh
        cache.lock.unlock()
        return fresh
    }

    public static func read() -> ThermalReading {
        ThermalReading(level: level(), celsius: TemperatureReader.cpuCelsius())
    }
}

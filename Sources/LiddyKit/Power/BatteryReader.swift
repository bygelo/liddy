import Foundation
import IOKit.ps

public struct BatteryReading: Codable, Sendable, Equatable {
    /// nil on a desktop Mac with no internal battery.
    public var percent: Int?
    public var isCharging: Bool
    public var isOnMain: Bool
    /// IOKit's own estimate, in minutes. nil while it is still calculating, which it
    /// always is for the first minute or so after a power-source change.
    public var minuteRemaining: Int?

    public static let unknown = BatteryReading(percent: nil, isCharging: false, isOnMain: true)

    public init(percent: Int?, isCharging: Bool, isOnMain: Bool, minuteRemaining: Int? = nil) {
        self.percent = percent
        self.isCharging = isCharging
        self.isOnMain = isOnMain
        self.minuteRemaining = minuteRemaining
    }

    /// A Mac with no battery can never cross a battery floor.
    public func isBelow(_ threshold: Int) -> Bool {
        guard let percent else { return false }
        return percent < threshold
    }

    public var display: String {
        guard let percent else { return isOnMain ? "AC power" : "no battery" }
        return "\(percent)%\(isOnMain ? " (charging)" : "")"
    }

    /// "3:05" — the shape the system menu uses. nil when IOKit has no estimate yet.
    public var remainingDisplay: String? {
        guard let minuteRemaining, minuteRemaining > 0 else { return nil }
        return "\(minuteRemaining / 60):\(String(format: "%02d", minuteRemaining % 60))"
    }

    /// The caption under the battery ring: time remaining when IOKit will commit to
    /// one, and the power source when it will not.
    public var sourceDisplay: String {
        if let remainingDisplay {
            return isOnMain ? "\(remainingDisplay) to full" : "\(remainingDisplay) left"
        }
        if percent == nil { return isOnMain ? "AC power" : "no battery" }
        return isOnMain ? (isCharging ? "charging" : "plugged in") : "on battery"
    }
}

public enum BatteryReader {
    public static func read() -> BatteryReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unknown }

        for source in list {
            guard let raw = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue(),
                  let info = raw as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else { continue }

            let state = info[kIOPSPowerSourceStateKey] as? String
            let isOnMain = state == kIOPSACPowerValue
            let isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            // IOKit reports -1 while it is still estimating. Treat that as "no answer"
            // rather than rendering a negative time in the menu.
            let rawMinute = (isOnMain ? info[kIOPSTimeToFullChargeKey] : info[kIOPSTimeToEmptyKey]) as? Int
            let minuteRemaining = (rawMinute ?? -1) > 0 ? rawMinute : nil

            return BatteryReading(
                percent: percent,
                isCharging: isCharging,
                isOnMain: isOnMain,
                minuteRemaining: minuteRemaining
            )
        }
        return .unknown
    }
}

import Foundation
import IOKit.ps

public struct BatteryReading: Codable, Sendable, Equatable {
    /// nil on a desktop Mac with no internal battery.
    public var percent: Int?
    public var isCharging: Bool
    public var isOnMain: Bool

    public static let unknown = BatteryReading(percent: nil, isCharging: false, isOnMain: true)

    public init(percent: Int?, isCharging: Bool, isOnMain: Bool) {
        self.percent = percent
        self.isCharging = isCharging
        self.isOnMain = isOnMain
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
            return BatteryReading(percent: percent, isCharging: isCharging, isOnMain: isOnMain)
        }
        return .unknown
    }
}

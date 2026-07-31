import Foundation

public enum SafetyVerdict: Equatable, Sendable {
    /// Nothing to do.
    case proceed
    /// Still safe, but worth surfacing.
    case warn(String)
    /// Drop the hold and let macOS sleep normally.
    case release(StopReason)
    /// Force `pmset sleepnow`. Used only where a normal release is not enough —
    /// a closed lid at critical heat, or the last-resort battery floor.
    case forceSleep(StopReason)

    public var isStop: Bool {
        switch self {
        case .proceed, .warn: return false
        case .release, .forceSleep: return true
        }
    }

    public var reason: StopReason? {
        switch self {
        case .release(let r), .forceSleep(let r): return r
        case .proceed, .warn: return nil
        }
    }
}

/// Pure decision layer: readings in, verdict out. No IOKit, no side effects, so the
/// rules that decide whether an overnight run survives are directly testable.
public struct SafetyGovernor: Sendable {
    public var setting: Setting

    public init(setting: Setting) {
        self.setting = setting.normalized()
    }

    /// Evaluated most-severe first — a hard floor must win over every softer rule.
    public func evaluate(
        battery: BatteryReading,
        thermal: ThermalReading,
        isClamshellActive: Bool
    ) -> SafetyVerdict {
        // 1. Hard battery floor. Forced sleep, not a release: releasing only removes
        //    *our* assertion, and anything else holding one would ride the battery to
        //    a hard shutdown, which is exactly the lost-work case being prevented.
        if battery.isBelow(setting.hardBatteryPercent), !battery.isOnMain {
            return .forceSleep(.batteryFloor)
        }

        // 2. Critical heat with the lid shut: no airflow, so do not merely release.
        if thermal.level >= .critical {
            return isClamshellActive ? .forceSleep(.thermalCritical) : .release(.thermalCritical)
        }

        // 3. Soft battery floor — sleep normally while there is still headroom to
        //    write everything out and resume from where the work left off.
        if battery.isBelow(setting.softBatteryPercent), !battery.isOnMain {
            return .release(.batteryFloor)
        }

        // 4. Thermal ceiling the user chose (default: critical, handled above).
        if thermal.level >= setting.thermalCeiling {
            return .release(.thermalCritical)
        }

        // 5. Charging-only mode.
        if setting.isChargingOnly, !battery.isOnMain {
            return .release(.userStopped)
        }

        // Warnings — the run continues, but the menu bar should say something.
        if thermal.level >= .serious {
            return .warn("Thermal pressure \(thermal.level.display) — check airflow")
        }
        if let percent = battery.percent, !battery.isOnMain,
           percent < setting.softBatteryPercent + 10 {
            return .warn("Battery \(percent)% — will sleep at \(setting.softBatteryPercent)%")
        }
        return .proceed
    }
}

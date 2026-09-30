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
    ///
    /// - Parameter isOverrideActive: the user has said "keep going anyway".
    ///
    ///   The split this turns on is the one already encoded in the return type, which
    ///   is why the override needs no list of exceptions to maintain. `.release` rules
    ///   are *courtesy*: sleep while there is still headroom, back off when warm, stay
    ///   off battery if asked. Those are the user's call to waive — it is their Mac and
    ///   their unfinished job.
    ///
    ///   `.forceSleep` rules are not courtesy. The hard battery floor exists so a run
    ///   ends in a resumable sleep instead of a hard shutdown, and critical heat behind
    ///   a shut lid has no airflow to recover through. Waiving those does not express a
    ///   preference, it loses work or cooks hardware — so an override cannot reach them
    ///   at any setting.
    public func evaluate(
        battery: BatteryReading,
        thermal: ThermalReading,
        isClamshellActive: Bool,
        isOverrideActive: Bool = false
    ) -> SafetyVerdict {
        let verdict = rule(battery: battery, thermal: thermal, isClamshellActive: isClamshellActive)
        guard isOverrideActive, case .release(let reason) = verdict else { return verdict }
        return .warn("Overriding: \(reason.summary)")
    }

    private func rule(
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
            return .release(.chargingOnly)
        }

        // Warnings — the run continues, but the menu bar should say something.
        if thermal.level >= .serious {
            return .warn("Thermal pressure \(thermal.level.display). Check airflow")
        }
        if let percent = battery.percent, !battery.isOnMain,
           percent < setting.softBatteryPercent + 10 {
            return .warn("Battery \(percent)%, will sleep at \(setting.softBatteryPercent)%")
        }
        return .proceed
    }
}

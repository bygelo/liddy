import Foundation

/// User-tunable thresholds. Both battery floors are on for everyone — the whole
/// safety argument collapses if the guardrail is the paid part.
public struct Setting: Codable, Sendable, Equatable {
    /// Soft floor: release the hold and let the Mac sleep normally.
    public var softBatteryPercent: Int
    /// Hard floor: force `pmset sleepnow` regardless of who holds an assertion,
    /// so a run ends in a resumable sleep instead of a sudden shutdown.
    public var hardBatteryPercent: Int
    /// Release when thermal pressure reaches this level or worse.
    public var thermalCeiling: ThermalLevel
    /// Smart mode: how long every lease must be gone before releasing.
    public var idleReleaseSecond: Int
    /// Only hold while on mains power.
    public var isChargingOnly: Bool
    /// Executable name that counts as live work. Matched exactly against the
    /// process's basename (see `ProcessWatcher.matches`), not as a substring.
    public var watchPattern: [String]

    public static let softBatteryRange = 15...50
    public static let hardBatteryRange = 4...8
    public static let maxSessionSecond = 8 * 3600

    public static let `default` = Setting(
        softBatteryPercent: 20,
        hardBatteryPercent: 4,
        thermalCeiling: .critical,
        idleReleaseSecond: 600,
        isChargingOnly: false,
        // Only task-shaped processes — things that start, do work, and exit.
        //
        // Server-shaped tools are deliberately absent: `ollama serve`, the Docker
        // Desktop backend, colima and a `vite` dev server all run for as long as
        // they are installed and open, so watching them by name would hold the Mac
        // awake permanently on an idle machine. Those cases belong to `liddy claim`,
        // where the thing doing the work says when it starts and stops.
        watchPattern: [
            "claude", "codex", "cursor-agent", "aider",
            "xcodebuild", "swift-frontend", "cargo", "rustc", "make", "ninja", "gradle",
            "npm", "pnpm", "yarn", "tsc", "esbuild",
            "python", "pytest", "uv", "poetry",
            "docker", "ffmpeg", "rsync", "pandoc",
        ]
    )

    public init(
        softBatteryPercent: Int,
        hardBatteryPercent: Int,
        thermalCeiling: ThermalLevel,
        idleReleaseSecond: Int,
        isChargingOnly: Bool,
        watchPattern: [String]
    ) {
        self.softBatteryPercent = softBatteryPercent
        self.hardBatteryPercent = hardBatteryPercent
        self.thermalCeiling = thermalCeiling
        self.idleReleaseSecond = idleReleaseSecond
        self.isChargingOnly = isChargingOnly
        self.watchPattern = watchPattern
    }

    /// Clamp anything a hand-edited config file could get wrong. A soft floor below
    /// the hard floor would silently disable the soft stop, so it is raised, not trusted.
    public func normalized() -> Setting {
        var copy = self
        copy.hardBatteryPercent = hardBatteryPercent.clamped(to: Setting.hardBatteryRange)
        copy.softBatteryPercent = softBatteryPercent.clamped(to: Setting.softBatteryRange)
        if copy.softBatteryPercent <= copy.hardBatteryPercent {
            copy.softBatteryPercent = Setting.softBatteryRange.lowerBound
        }
        copy.idleReleaseSecond = max(30, idleReleaseSecond)
        return copy
    }
}

extension Setting {
    public static var storeUrl: URL {
        LiddyPath.supportDirectory.appendingPathComponent("setting.json")
    }

    public static func load() -> Setting {
        guard let data = try? Data(contentsOf: storeUrl),
              let decoded = try? JSONDecoder().decode(Setting.self, from: data)
        else { return .default }
        return decoded.normalized()
    }

    public func save() throws {
        try LiddyPath.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(normalized()).write(to: Setting.storeUrl, options: .atomic)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Every on-disk path Liddy owns, in one place.
public enum LiddyPath {
    public static var supportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".liddy", isDirectory: true)
    }

    /// App ↔ CLI socket. User-owned, mode 0600.
    public static var appSocket: URL {
        supportDirectory.appendingPathComponent("liddy.sock")
    }

    /// App ↔ root helper socket. Created by the helper, chowned to the install user.
    public static let helperSocketPath = "/var/run/liddy-helper.sock"

    public static var activityLog: URL {
        supportDirectory.appendingPathComponent("activity.jsonl")
    }

    /// Helper-side record of whether *we* are the one holding disablesleep, so a
    /// helper restart can tell "Liddy left this on" from "the user set it by hand".
    public static let helperStatePath = "/var/db/liddy/helper-state.json"

    public static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

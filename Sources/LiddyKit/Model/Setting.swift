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
    /// Turn the internal display's backlight down while the lid is shut, and put it
    /// back when the lid opens. A closed panel that is still lit is watts and heat
    /// spent on a screen nobody can see.
    public var isLidBrightnessOff: Bool
    /// Hide the apps in `backgroundApp` while a hold is running, and unhide them when
    /// it ends. Hiding is what macOS itself uses to make an app a candidate for App
    /// Nap — occluded windows stop drawing, timers coalesce, and the CPU that was
    /// going into a background Chrome goes into the work instead.
    public var isResourceSaverOn: Bool
    /// Application names to background while a hold runs. Matched against the running
    /// application's localized name, so these are the names in the Dock — "Google
    /// Chrome", not "chrome".
    public var backgroundApp: [String]
    /// Draw the health checks in the panel at all.
    ///
    /// Off by default after a direct user report that the panel was mostly text. The
    /// checks still RUN — a failing one still turns the menu-bar glyph into a warning
    /// triangle and still appears as a single line here — but a wall of green rows
    /// nobody reads is exactly the text that was asked to go.
    public var isHealthPanelOn: Bool
    /// Whether the health panel is allowed to touch the network — DNS, and a HEAD to
    /// the API of whichever agent is currently holding a lease. Off makes Liddy
    /// completely silent on the wire; the local half of the panel still works.
    public var isNetworkProbeOn: Bool

    public static let softBatteryRange = 15...50
    public static let hardBatteryRange = 4...8
    public static let maxSessionSecond = 8 * 3600

    /// A ceiling of `.nominal` is not a strict setting, it is a brick: the governor
    /// asks `thermal.level >= ceiling`, and every possible level is `>= .nominal`, so
    /// the Mac would be released the instant anything tried to hold it — permanently,
    /// since the condition can never clear. `.fair` is the lowest ceiling that leaves
    /// a reachable "everything is fine" state.
    public static let thermalCeilingChoice: [ThermalLevel] = [.fair, .serious, .critical]

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
        ],
        isNetworkProbeOn: true,
        // Off by default, unlike the other two. This one reaches outside Liddy and
        // moves windows that belong to somebody else's app; a power tool a user opts
        // into, not a default they discover by watching Chrome vanish.
        isHealthPanelOn: false,
        isLidBrightnessOff: true,
        isResourceSaverOn: false,
        backgroundApp: ["Google Chrome", "Discord", "Slack", "Spotify"]
    )

    public init(
        softBatteryPercent: Int,
        hardBatteryPercent: Int,
        thermalCeiling: ThermalLevel,
        idleReleaseSecond: Int,
        isChargingOnly: Bool,
        watchPattern: [String],
        isNetworkProbeOn: Bool = true,
        isHealthPanelOn: Bool = false,
        isLidBrightnessOff: Bool = true,
        isResourceSaverOn: Bool = false,
        backgroundApp: [String] = Setting.defaultBackgroundApp
    ) {
        self.softBatteryPercent = softBatteryPercent
        self.hardBatteryPercent = hardBatteryPercent
        self.thermalCeiling = thermalCeiling
        self.idleReleaseSecond = idleReleaseSecond
        self.isChargingOnly = isChargingOnly
        self.watchPattern = watchPattern
        self.isNetworkProbeOn = isNetworkProbeOn
        self.isHealthPanelOn = isHealthPanelOn
        self.isLidBrightnessOff = isLidBrightnessOff
        self.isResourceSaverOn = isResourceSaverOn
        self.backgroundApp = backgroundApp
    }

    public static let defaultBackgroundApp = ["Google Chrome", "Discord", "Slack", "Spotify"]

    /// Decoded field by field with a fallback per key.
    ///
    /// Synthesized `Codable` fails the whole decode when one key is missing, and
    /// `Setting.load()` swallows that into `.default` — so adding a field would
    /// silently reset every threshold a user had tuned. Every new field from here on
    /// must be read with `decodeIfPresent`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Setting.default
        softBatteryPercent = try container.decodeIfPresent(Int.self, forKey: .softBatteryPercent)
            ?? fallback.softBatteryPercent
        hardBatteryPercent = try container.decodeIfPresent(Int.self, forKey: .hardBatteryPercent)
            ?? fallback.hardBatteryPercent
        thermalCeiling = try container.decodeIfPresent(ThermalLevel.self, forKey: .thermalCeiling)
            ?? fallback.thermalCeiling
        idleReleaseSecond = try container.decodeIfPresent(Int.self, forKey: .idleReleaseSecond)
            ?? fallback.idleReleaseSecond
        isChargingOnly = try container.decodeIfPresent(Bool.self, forKey: .isChargingOnly)
            ?? fallback.isChargingOnly
        watchPattern = try container.decodeIfPresent([String].self, forKey: .watchPattern)
            ?? fallback.watchPattern
        isNetworkProbeOn = try container.decodeIfPresent(Bool.self, forKey: .isNetworkProbeOn)
            ?? fallback.isNetworkProbeOn
        isHealthPanelOn = try container.decodeIfPresent(Bool.self, forKey: .isHealthPanelOn)
            ?? fallback.isHealthPanelOn
        isLidBrightnessOff = try container.decodeIfPresent(Bool.self, forKey: .isLidBrightnessOff)
            ?? fallback.isLidBrightnessOff
        isResourceSaverOn = try container.decodeIfPresent(Bool.self, forKey: .isResourceSaverOn)
            ?? fallback.isResourceSaverOn
        backgroundApp = try container.decodeIfPresent([String].self, forKey: .backgroundApp)
            ?? fallback.backgroundApp
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
        // Clamped here rather than in the picker so the CLI and a hand-edited
        // setting.json get the same protection — `liddy set --thermal-ceiling nominal`
        // could otherwise wedge the app into never holding again.
        if copy.thermalCeiling < .fair { copy.thermalCeiling = .fair }
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

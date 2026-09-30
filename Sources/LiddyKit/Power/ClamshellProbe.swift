import Foundation
import IOKit
import IOKit

/// Read-only `ioreg` probe for the kernel's clamshell-sleep property.
///
/// `pmset -a disablesleep` is the lever Liddy pulls, but on Apple Silicon the
/// lever may be disconnected from the mechanism. This probe reads the ground
/// truth from IOKit so `liddy doctor` can tell whether the lever actually works.
public enum ClamshellProbe {
    /// Read one `IOPMrootDomain` property straight out of the IO registry.
    ///
    /// The text path below shells out to `/usr/sbin/ioreg`, and a fork + exec + full
    /// registry dump + parse costs **34ms of CPU** — measured in the running app, where
    /// it was 0.68% of a core all by itself, the largest single cost left after the
    /// sensor and thermal caches. The registry is a C API; asking it for one key is
    /// microseconds and allocates nothing.
    ///
    /// `ioreg` stays as the fallback and as the thing the pure parsers are tested
    /// against: it is the same data, and a text fixture is how the parse rules are
    /// locked without a Mac in the loop.
    static func registryFlag(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        else { return nil }

        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }

    /// Raw `ioreg` output for `IOPMrootDomain`.
    public static func output() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-c", "IOPMrootDomain", "-d", "1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// One boolean property of `IOPMrootDomain`, read in-process.
    ///
    /// The no-argument `isLidClosed()` runs on every 5-second tick, and spawning
    /// `ioreg` and parsing its text cost 87 ms a call — more than the rest of the tick
    /// together. This is the same registry entry `ioreg` prints, read directly. The
    /// text parsers stay, for `output()` and for the tests that pin real `ioreg` rows.
    static func rootDomainFlag(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }

    /// Whether the kernel says clamshell causes sleep.
    ///
    /// The real line looks like:
    ///     "AppleClamshellCausesSleep" = Yes
    /// with arbitrary leading whitespace and vertical-bar tree characters before it.
    /// Returns `true` for `Yes`, `false` for `No`, and `nil` when the property is
    /// absent or unparseable — nil means "could not tell", never a silent false.
    public static func causesSleep() -> Bool? { rootDomainFlag("AppleClamshellCausesSleep") }

    public static func causesSleep(_ text: String) -> Bool? {
        let lower = text.lowercased()
        guard lower.contains("appleclamshellcausessleep") else { return nil }
        for row in text.split(separator: "\n") where row.lowercased().contains("appleclamshellcausessleep") {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.lastIndex(of: "=") else { continue }
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch value.lowercased() {
            case "yes": return true
            case "no": return false
            default: return nil
            }
        }
        return nil
    }

    /// Whether the lid is physically shut, from `AppleClamshellState`.
    ///
    /// The kernel answers this directly, so nothing here has to infer a closed lid from
    /// display count or power source — both of which are wrong the moment an external
    /// monitor is plugged in. nil means the property was absent: could not tell.
    public static func isLidClosed() -> Bool? { rootDomainFlag("AppleClamshellState") }

    public static func isLidClosed(_ text: String) -> Bool? {
        for row in text.split(separator: "\n") where row.lowercased().contains("appleclamshellstate") {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.lastIndex(of: "=") else { continue }
            switch String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces).lowercased() {
            case "yes": return true
            case "no": return false
            default: return nil
            }
        }
        return nil
    }

    public enum ClamshellLever {
        case effective
        case ineffective
        case unknown

        public var display: String {
            switch self {
            case .effective: return "effective"
            case .ineffective: return "ineffective"
            case .unknown: return "unknown"
            }
        }
    }

    /// Whether the `disablesleep` lever is actually doing its job.
    ///
    /// You cannot judge the lever while it is not pulled (`isDisableSleepOn` false),
    /// so that is always `.unknown`. When pulled, `causesSleep == false` means the
    /// lever is effective and `causesSleep == true` means it is inert.
    public static func lever(isDisableSleepOn: Bool, causesSleep: Bool?) -> ClamshellLever {
        guard isDisableSleepOn else { return .unknown }
        guard let causesSleep else { return .unknown }
        return causesSleep ? .ineffective : .effective
    }
}

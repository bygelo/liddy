import Foundation
import IOKit

/// Read-only `pmset -g`, shared by `liddy doctor` and the live health panel so the
/// two can never disagree about whether the Mac is allowed to sleep.
///
/// Nothing here writes. Every state change goes through the root helper.
public enum PmsetReader {
    public static func output() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `IOPMrootDomain`'s own `SleepDisabled`, which is what `pmset -g disablesleep`
    /// reports — without the fork.
    ///
    /// `output()` costs 82ms of wall time and a subprocess; this is a registry read.
    /// The health sweep asked for it on every pass, and `liddy doctor` asks twice. The
    /// text path stays for the CLI's full dump and as what the parser below is tested
    /// against.
    public static func isDisableSleepOnFromRegistry() -> Bool? {
        ClamshellProbe.registryFlag("SleepDisabled")
    }

    /// Registry first, text second. Same answer, 5000× cheaper.
    public static func isDisableSleepOn() -> Bool {
        isDisableSleepOnFromRegistry() ?? isDisableSleepOn(output())
    }

    /// `pmset -g` omits `disablesleep` entirely when it is 0, so absent means normal
    /// sleep — it is not an inconclusive reading.
    public static func isDisableSleepOn(_ text: String) -> Bool {
        for row in text.split(separator: "\n") where row.lowercased().contains("disablesleep") {
            return row.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return false
    }

    /// macOS names every process holding a sleep assertion on the `sleep` row. Useful
    /// for the common confusion of "Liddy released, so why is my Mac still awake?" —
    /// usually a stray `caffeinate` from three deploys ago.
    public static func assertionHolder(_ text: String = output()) -> String {
        for row in text.split(separator: "\n") where row.contains("sleep prevented by") {
            guard let open = row.firstIndex(of: "("), let close = row.lastIndex(of: ")") else { continue }
            return String(row[row.index(after: open)..<close])
                .replacingOccurrences(of: "sleep prevented by ", with: "")
        }
        return ""
    }
}

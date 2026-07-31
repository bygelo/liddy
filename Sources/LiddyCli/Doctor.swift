import Foundation
import LiddyKit

/// `liddy doctor` — answer "is this actually set up, and is anything stuck?"
///
/// The last check is the one that matters: a leftover `disablesleep 1` with no helper
/// running means the Mac cannot sleep at all and nothing is watching it. That state is
/// the whole hazard of closed-lid work, so it is reported loudly and with the fix.
enum Doctor {
    private static func line(_ isOk: Bool?, _ label: String, _ detail: String) {
        let mark = isOk == nil ? "•" : (isOk! ? "✓" : "✗")
        print("  \(mark) \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(detail)")
    }

    static func run() {
        print("liddy doctor\n")

        print("CLI")
        line(true, "binary", CommandLine.arguments[0])
        let isOnPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .contains { FileManager.default.isExecutableFile(atPath: "\($0)/liddy") }
        line(isOnPath, "on PATH", isOnPath ? "yes" : "no — run Script/install-cli.sh")

        print("\nApp")
        let socketPath = LiddyPath.appSocket.path
        let isSocketPresent = FileManager.default.fileExists(atPath: socketPath)
        line(isSocketPresent, "socket", isSocketPresent ? socketPath : "missing — is Liddy.app running?")

        if isSocketPresent {
            let client = LineSocketClient(path: socketPath)
            if (try? client.connect()) != nil,
               let response = try? client.roundTrip(AppRequest.status, expecting: AppResponse.self),
               case .snapshot(let snap) = response {
                line(true, "responding", "yes")
                line(nil, "holding", snap.activeLease.isEmpty ? "nothing" : snap.activeLease.joined(separator: ", "))
                line(nil, "battery", snap.battery.display)
                line(nil, "thermal", snap.thermal.level.display)
            } else {
                line(false, "responding", "socket exists but no reply — stale socket?")
            }
        }

        print("\nHelper (needed only for closed-lid)")
        let isBinaryPresent = FileManager.default.fileExists(atPath: "/usr/local/libexec/liddy-helper")
        line(isBinaryPresent, "installed", isBinaryPresent ? "/usr/local/libexec/liddy-helper" : "no — Script/install-helper.sh")
        let isHelperSocketPresent = FileManager.default.fileExists(atPath: LiddyPath.helperSocketPath)
        line(isHelperSocketPresent, "running", isHelperSocketPresent ? LiddyPath.helperSocketPath : "not running")

        if isHelperSocketPresent {
            let client = LineSocketClient(path: LiddyPath.helperSocketPath)
            if (try? client.connect()) != nil,
               let response = try? client.roundTrip(HelperRequest.status, expecting: HelperResponse.self),
               case .status(let status) = response {
                line(true, "reachable", "v\(status.version), clamshell \(status.isClamshellOn ? "ON" : "off")")
            } else {
                line(false, "reachable", "no reply (permission? check /var/log/liddy-helper.log)")
            }
        }

        print("\nSystem")
        // `pmset -g` omits disablesleep entirely when it is 0, so absent means
        // normal sleep — it is not an inconclusive reading.
        if pmsetDisableSleep() {
            line(false, "disablesleep", "1 — YOUR MAC CANNOT SLEEP")
            if !isHelperSocketPresent {
                print("""

                  ⚠️  disablesleep is on but the Liddy helper is not running, so nothing
                     is watching it. Your Mac will not sleep at all until this is cleared:

                       sudo pmset -a disablesleep 0
                """)
            }
        } else {
            line(true, "disablesleep", "not set — normal sleep")
        }

        let holder = sleepAssertionHolder()
        line(nil, "keeping awake", holder.isEmpty ? "nothing" : holder)

        let setting = Setting.load()
        print("\nSetting")
        line(nil, "soft battery floor", "\(setting.softBatteryPercent)%")
        line(nil, "hard battery floor", "\(setting.hardBatteryPercent)%")
        line(nil, "thermal ceiling", setting.thermalCeiling.rawValue)
        line(nil, "idle release", "\(setting.idleReleaseSecond)s")
        line(nil, "watch pattern", "\(setting.watchPattern.count) entries")
    }

    private static func pmsetOutput() -> String {
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

    private static func pmsetDisableSleep() -> Bool {
        for row in pmsetOutput().split(separator: "\n")
        where row.lowercased().contains("disablesleep") {
            return row.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return false
    }

    /// macOS names every process holding a sleep assertion on the `sleep` row. Useful
    /// for the common confusion of "Liddy released, so why is my Mac still awake?" —
    /// usually a stray `caffeinate` from three deploys ago.
    private static func sleepAssertionHolder() -> String {
        for row in pmsetOutput().split(separator: "\n") where row.contains("sleep prevented by") {
            guard let open = row.firstIndex(of: "("), let close = row.lastIndex(of: ")") else { continue }
            return String(row[row.index(after: open)..<close])
                .replacingOccurrences(of: "sleep prevented by ", with: "")
        }
        return ""
    }
}

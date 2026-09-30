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
        line(isOnPath, "on PATH", isOnPath ? "yes" : "no. Run Script/install-cli.sh")

        print("\nApp")
        let isInApplications = FileManager.default.fileExists(atPath: AppInstall.applicationsPath)
        line(isInApplications, "in Applications",
             isInApplications
                ? AppInstall.applicationsPath
                : "missing. Drag Liddy.app to /Applications")
        let socketPath = LiddyPath.appSocket.path
        let isSocketPresent = FileManager.default.fileExists(atPath: socketPath)
        line(isSocketPresent, "socket", isSocketPresent ? socketPath : "missing. Is Liddy.app running?")

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
                line(false, "responding", "socket exists but no reply. Stale socket?")
            }
        }

        print("\nHelper (needed only for closed-lid)")
        let isBinaryPresent = FileManager.default.fileExists(atPath: "/usr/local/libexec/liddy-helper")
        line(isBinaryPresent, "installed", isBinaryPresent ? "/usr/local/libexec/liddy-helper" : "no. Run Script/install-helper.sh")
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
        let pmsetText = PmsetReader.output()
        if PmsetReader.isDisableSleepOn(pmsetText) {
            line(false, "disablesleep", "1. YOUR MAC CANNOT SLEEP")
            if !isHelperSocketPresent {
                print("""

                  ⚠️  disablesleep is on but the Liddy helper is not running, so nothing
                     is watching it. Your Mac will not sleep at all until this is cleared:

                       sudo pmset -a disablesleep 0
                """)
            }
        } else {
            line(true, "disablesleep", "not set, normal sleep")
        }

        let holder = PmsetReader.assertionHolder(pmsetText)
        line(nil, "keeping awake", holder.isEmpty ? "nothing" : holder)

        // The load-bearing question this whole product rests on: does the lever we
        // pull still move anything? `pmset` will happily report disablesleep=1 on a
        // machine where the lid magnet forces sleep in hardware, so the kernel's own
        // property is the only honest answer. Reported as three states, never two —
        // with disablesleep off there is nothing to judge, and saying so beats
        // inventing a verdict.
        let causesSleep = ClamshellProbe.causesSleep()
        let lever = ClamshellProbe.lever(
            isDisableSleepOn: PmsetReader.isDisableSleepOn(pmsetText),
            causesSleep: causesSleep
        )
        let kernelReading = causesSleep.map { $0 ? "yes" : "no" } ?? "property not found"
        switch lever {
        case .effective:
            line(true, "clamshell lever", "effective (kernel: clamshell causes sleep = \(kernelReading))")
        case .ineffective:
            line(false, "clamshell lever", "INEFFECTIVE — disablesleep is on but the kernel still sleeps on lid close")
        case .unknown:
            line(nil, "clamshell lever", "unknown, disablesleep is off (kernel: clamshell causes sleep = \(kernelReading))")
        }

        let isHookInstalled = HealthProbe.isClaudeHookInstalled()
        line(isHookInstalled, "claude hook", isHookInstalled ? "installed" : "not installed. Run liddy hook install")

        let setting = Setting.load()
        print("\nSetting")
        line(nil, "soft battery floor", "\(setting.softBatteryPercent)%")
        line(nil, "hard battery floor", "\(setting.hardBatteryPercent)%")
        line(nil, "thermal ceiling", setting.thermalCeiling.rawValue)
        line(nil, "idle release", "\(setting.idleReleaseSecond)s")
        line(nil, "network probe", setting.isNetworkProbeOn ? "on" : "off")
        line(nil, "watch pattern", "\(setting.watchPattern.count) entries")

        print("\nRun `liddy health` for the live network and service checks.")
    }
}

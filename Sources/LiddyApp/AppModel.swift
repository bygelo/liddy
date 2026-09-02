import Foundation
import SwiftUI
import UserNotifications
import LiddyKit

/// Bridges the runtime to SwiftUI and hosts the socket the CLI talks to.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = RuntimeSnapshot()
    @Published private(set) var recentEntry: [LogEntry] = []
    @Published private(set) var recentSample: [MetricSample] = []
    @Published private(set) var setting: Setting = .default
    @Published var alert: String?

    /// Which sections are open. These live here rather than as `@State` in the view
    /// because the window has to resize itself when one opens, and the panel
    /// controller can only see state it can subscribe to. Keeping them here also means
    /// a section you opened is still open the next time you click the icon.
    @Published var isAgentExpanded = false
    @Published var isHealthExpanded = false
    @Published var isActivityExpanded = false
    @Published var isSettingExpanded = false

    /// How many samples the sparkline draws. Also the width of the strip in bars.
    static let sparklineSampleCount = 48

    /// `nonisolated` on purpose: the runtime is internally queue-confined and safe to
    /// call from any thread, and the CLI socket handler must reach it without hopping
    /// to the main actor — a `liddy status` in a script cannot wait on UI work.
    nonisolated private let runtime = LiddyRuntime()
    private var server: LineSocketServer?

    init() {
        runtime.onChange = { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = snapshot
                self.recentEntry = self.runtime.recentLog(limit: 12)
                self.recentSample = self.runtime.recentSample(limit: Self.sparklineSampleCount)
                // The panel draws thresholds, not just readings — a battery ring that
                // turns amber at the soft floor has to know where the floor moved to.
                self.setting = self.runtime.currentSetting
                self.refreshHelperReadiness()
            }
        }
        runtime.onAlert = { [weak self] message in
            Task { @MainActor in
                self?.alert = message
                self?.notify(message)
            }
        }
    }

    func start() {
        runtime.start()
        startServer()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        snapshot = runtime.snapshot
        recentEntry = runtime.recentLog(limit: 12)
        recentSample = runtime.recentSample(limit: Self.sparklineSampleCount)
        setting = runtime.currentSetting
        runtime.refreshHealth()
    }

    /// Wired to app termination. Anything turned on must come back off here — the
    /// helper's deadman switch is the backstop, not the plan.
    func shutdown() {
        server?.stop()
        runtime.shutdown()
    }

    // MARK: - Menu actions

    func toggleAwake() {
        if snapshot.isAwakeHeld {
            runtime.endHold(reason: .userStopped)
        } else {
            runtime.beginHold(second: nil, mode: .smart)
        }
    }

    func toggleClamshell(second: Int?) {
        do {
            try runtime.setClamshell(!snapshot.isClamshellActive, second: second, mode: .smart)
        } catch {
            alert = error.localizedDescription
        }
    }

    func hold(forSecond second: Int) {
        // A duration is an explicit promise, not a maximum for a smart hold that can
        // release as soon as its idle window expires.
        runtime.beginHold(second: second, mode: .manual)
    }

    /// The one control the panel leads with. Collapses what used to be two switches,
    /// and makes the impossible fourth combination unrepresentable rather than merely
    /// refused after the fact.
    func select(mode: ModeSelector.Mode) {
        alert = nil
        switch mode {
        case .sleep:
            if snapshot.isClamshellActive { toggleClamshell(second: nil) }
            if snapshot.isAwakeHeld { runtime.endHold(reason: .userStopped) }

        case .awake:
            // Stepping down from lid-shut has to drop the privileged toggle first, or
            // the Mac keeps ignoring the lid while the panel says it is only awake.
            if snapshot.isClamshellActive { toggleClamshell(second: nil) }
            runtime.beginHold(second: nil, mode: .smart)

        case .lid:
            // Picking a capability you do not have yet should install it, not scold
            // you. The password prompt is a better answer than an error banner.
            guard HelperInstaller.isInstalled else {
                installHelper()
                guard isHelperReady else { return }
                toggleClamshell(second: 8 * 3600)
                return
            }
            if !snapshot.isClamshellActive { toggleClamshell(second: 8 * 3600) }
        }
    }

    func override(second: Int) {
        alert = nil
        runtime.setOverride(second: second)
    }

    func cancelOverride() {
        runtime.clearOverride()
        runtime.endHold(reason: .userStopped)
    }

    func refreshHealth() {
        alert = nil
        // Refresh means "look again at everything", which includes which agent apps
        // are installed — otherwise a freshly installed Cursor keeps its placeholder
        // glyph until the app restarts.
        AppIconResolver.forget()
        runtime.refreshHealth()
    }

    func setNetworkProbe(_ isOn: Bool) {
        _ = runtime.updateSetting(SettingPatch(isNetworkProbeOn: isOn))
        runtime.refreshHealth()
    }

    func setAutoWatch(_ isOn: Bool) {
        runtime.setAutoWatch(isOn)
    }

    // MARK: - Helper

    /// Whether closed-lid mode can be offered at all.
    @Published private(set) var isHelperReady = HelperInstaller.isInstalled
    @Published private(set) var isInstallingHelper = false

    func installHelper() {
        guard !isInstallingHelper else { return }
        isInstallingHelper = true
        alert = nil
        do {
            try HelperInstaller.install()
            isHelperReady = true
            // The daemon is new, so the health panel's helper row is stale.
            runtime.refreshHealth()
        } catch HelperInstaller.Failure.cancelled {
            // Dismissing the password prompt is a decision, not an error to report back.
        } catch {
            alert = error.localizedDescription
        }
        isInstallingHelper = false
    }

    /// Re-checked on every runtime publish so the row updates if the helper is
    /// installed or removed from outside the app — `Script/install-helper.sh` in a
    /// Terminal, or `uninstall-helper.sh`.
    private func refreshHelperReadiness() {
        let isReady = HelperInstaller.isInstalled
        if isReady != isHelperReady { isHelperReady = isReady }
    }

    /// Applied to the live governor, not just saved — see `LiddyRuntime.updateSetting`.
    /// The health sweep re-runs because several checks are read against these
    /// thresholds, so a floor you just moved should recolour the panel now rather than
    /// at the next 30-second sweep.
    func updateSetting(_ patch: SettingPatch) {
        setting = runtime.updateSetting(patch)
        runtime.refreshHealth()
    }

    // MARK: - CLI server

    private func startServer() {
        try? LiddyPath.ensureSupportDirectory()
        let server = LineSocketServer(path: LiddyPath.appSocket.path) { [weak self] line in
            guard let self else { return nil }
            let request = (try? Wire.decode(AppRequest.self, from: line)) ?? .status
            let response = self.handleSync(request)
            return try? Wire.encoder.encode(response)
        }
        do {
            try server.start(mode: 0o600)
            self.server = server
            runtime.setSocketBound(true)
        } catch {
            // Swallowing this is what made the failure invisible: the app runs fine,
            // the menu looks normal, and every `liddy` command reports "Liddy is not
            // running" with no way to tell that apart from the app being closed.
            runtime.setSocketBound(false, detail: error.localizedDescription)
            alert = "CLI socket unavailable: \(error.localizedDescription)"
        }
    }

    /// Runs on a socket connection queue. The runtime is internally queue-confined,
    /// so this hops to it rather than to the main actor — a `liddy status` in a
    /// script must not be able to block on UI work.
    nonisolated private func handleSync(_ request: AppRequest) -> AppResponse {
        switch request {
        case .status:
            return .snapshot(runtime.snapshot)

        case .start(let second, let mode):
            runtime.beginHold(second: second, mode: mode)
            return .ok("keep-awake on (\(mode.rawValue))")

        case .stop:
            runtime.endHold(reason: .userStopped)
            return .ok("keep-awake off")

        case .clamshell(let isOn, let second, let mode):
            do {
                try runtime.setClamshell(isOn, second: second, mode: mode)
                return .ok("closed-lid \(isOn ? "on" : "off")")
            } catch {
                return .failed(error.localizedDescription)
            }

        case .autowatch(let isOn):
            runtime.setAutoWatch(isOn)
            return .ok("auto-watch \(isOn ? "on" : "off")")

        case .watch(let pattern):
            runtime.addPattern(pattern)
            return .ok("watching \(pattern)")

        case .unwatch(let pattern):
            runtime.removePattern(pattern)
            return .ok("stopped watching \(pattern)")

        case .pattern:
            return .text(runtime.currentPattern)

        case .claim(let label, let ttlSecond, let key):
            return .token(runtime.claim(label: label, ttlSecond: ttlSecond, key: key))

        case .releaseKey(let key):
            return runtime.release(key: key) ? .ok("released") : .failed("no lease for key")

        case .settingList:
            let setting = runtime.currentSetting
            return .text([
                "soft-battery   \(setting.softBatteryPercent)%",
                "hard-battery   \(setting.hardBatteryPercent)%",
                "thermal-ceiling \(setting.thermalCeiling.rawValue)",
                "idle-release   \(setting.idleReleaseSecond)s",
                "charging-only  \(setting.isChargingOnly)",
                "network-probe  \(setting.isNetworkProbeOn)",
            ])

        case .updateSetting(let patch):
            let setting = runtime.updateSetting(patch)
            return .ok("soft-battery \(setting.softBatteryPercent)%, "
                       + "hard-battery \(setting.hardBatteryPercent)%, "
                       + "thermal-ceiling \(setting.thermalCeiling.rawValue), "
                       + "idle-release \(setting.idleReleaseSecond)s, "
                       + "charging-only \(setting.isChargingOnly), "
                       + "network-probe \(setting.isNetworkProbeOn)")

        case .renew(let token, let ttlSecond):
            return runtime.renew(token: token, ttlSecond: ttlSecond)
                ? .ok("renewed")
                : .failed("unknown or expired token, claim again")

        case .release(let token):
            return runtime.release(token: token) ? .ok("released") : .failed("unknown token")

        case .lease:
            let lease = runtime.activeLease
            return .text(lease.isEmpty ? ["nothing claimed"] : lease.map(\.display))

        case .recentLog(let limit):
            return .log(runtime.recentLog(limit: limit))

        case .override(let second):
            guard let second else {
                runtime.clearOverride()
                return .ok("override cancelled")
            }
            runtime.setOverride(second: second)
            return .ok("keeping going for \(min(second, LiddyRuntime.maxOverrideSecond))s. "
                       + "hard battery floor and critical heat still apply")

        case .health:
            // Blocks this connection's queue until the sweep lands — see `healthNow`.
            guard let report = runtime.healthNow() else {
                return .text(["checking… run again in a moment"])
            }
            var line: [String] = []
            for group in HealthGroup.allCases {
                let check = report.check(in: group)
                guard !check.isEmpty else { continue }
                line.append("\(group.display.uppercased())  [\(report.state(of: group).display)]")
                line += check.map { "  \($0.line)" }
            }
            line.append("")
            line.append("overall: \(report.overall.display) · checked \(report.at.formatted(date: .omitted, time: .standard))")
            return .text(line)

        case .notify(let title, let body):
            notify("\(title): \(body)")
            return .ok("sent")
        }
    }

    nonisolated private func notify(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Liddy"
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

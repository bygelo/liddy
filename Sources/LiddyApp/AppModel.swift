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
    /// `LIDDY_MEASURE_PANEL` opens every disclosure, so the measurement covers the
    /// tallest the panel can get rather than its resting height — which is the case
    /// that ran off the screen.
    /// Which page the panel is showing. Replaces the four disclosure flags.
    /// `LIDDY_TAB=health` opens the panel on a given page, so the measurement harness
    /// can check every page rather than only the default one.
    @Published var tab: PanelTab = ProcessInfo.processInfo.environment["LIDDY_TAB"]
        .flatMap(PanelTab.init(rawValue:)) ?? .now
    @Published var isHealthExpanded = ProcessInfo.processInfo.environment["LIDDY_EXPAND_ALL"] != nil

    @Published var isActivityExpanded = ProcessInfo.processInfo.environment["LIDDY_EXPAND_ALL"] != nil
    @Published var isSettingExpanded = ProcessInfo.processInfo.environment["LIDDY_EXPAND_ALL"] != nil
    /// Open at Login is an OS-level bit, not a field in `setting.json`. Published so
    /// the toggle reflects a change made in System Settings while the panel is open.
    @Published var isOpenAtLogin = LoginItem.isEnabled
    @Published var loginItemNeedsApproval = false

    /// Login Items resolve the app by path. A copy outside `/Applications` would
    /// register, then vanish the next time that path is replaced.
    var canOpenAtLogin: Bool { LoginItem.canRegister }

    /// How many samples the sparkline draws. Also the width of the strip in bars.
    static let sparklineSampleCount = 48

    /// `nonisolated` on purpose: the runtime is internally queue-confined and safe to
    /// call from any thread, and the CLI socket handler must reach it without hopping
    /// to the main actor — a `liddy status` in a script cannot wait on UI work.
    /// The app target is the only one with a window server, so it is the only one that
    /// passes a real `AppBackgrounding`. The CLI keeps the no-op.
    nonisolated private let runtime = LiddyRuntime(backgrounder: WorkspaceBackgrounder())
    private var server: LineSocketServer?

    init() {
        runtime.onChange = { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                // The menu-bar icon is derived from this, so it is always assigned.
                self.snapshot = snapshot
                // Everything below is drawn only inside the panel, and it was being
                // recomputed eighteen times a minute with the panel shut: the activity
                // log re-read, the 48-sample sparkline series copied, the setting
                // re-loaded, the helper's install state stat'ed and a Login Items query
                // made. None of it has a reader until the panel opens, and the panel
                // does a full refresh when it does.
                guard self.isPanelVisible else { return }
                self.refreshPanelData()
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
        refreshLoginItem()
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
        runtime.beginHold(second: second, mode: .smart)
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

    /// Passed straight through: the panel being on screen is what decides whether the
    /// runtime samples the readings only the panel shows.
    nonisolated func setPanelVisible(_ isVisible: Bool) {
        runtime.setPanelVisible(isVisible)
        Task { @MainActor in
            self.isPanelVisible = isVisible
            if isVisible { self.refreshPanelData() }
        }
    }

    /// Readings with no reader while the panel is shut.
    private func refreshPanelData() {
        recentEntry = runtime.recentLog(limit: 12)
        recentSample = runtime.recentSample(limit: Self.sparklineSampleCount)
        // The panel draws thresholds, not just readings — a battery ring that turns
        // amber at the soft floor has to know where the floor moved to.
        setting = runtime.currentSetting
        refreshHelperReadiness()
        refreshLoginItem()
    }

    private var isPanelVisible = false

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

    func setOpenAtLogin(_ isOn: Bool) {
        alert = nil
        do {
            try LoginItem.setEnabled(isOn)
        } catch {
            alert = error.localizedDescription
        }
        refreshLoginItem()
    }

    /// Run a failing check's way out.
    ///
    /// One entry point rather than a closure per row, so every remedy is visible in one
    /// place and none of them can quietly become a dead end. Each one either performs
    /// the fix or opens the exact place it is performed — never prints a command.
    func apply(_ remedy: HealthRemedy) {
        switch remedy {
        case .installHelper:
            installHelper()
        case .revealApp:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Bundle.main.bundlePath)])
        case .openLoginItem:
            openLoginItemSettings()
        case .installHook:
            installClaudeHook()
        case .clearDisableSleep:
            // Through the runtime, never by shelling out to pmset: the helper owns that
            // toggle and its deadman switch is the reason it is safe to own.
            runtime.clearStuckClamshell()
            refreshHealth()
        case .refresh:
            refreshHealth()
        case .openStatusPage:
            if let url = URL(string: "https://status.anthropic.com") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Runs the **bundled CLI's** `hook install`, rather than a second copy of the
    /// JSON-merging logic.
    ///
    /// That merge is genuinely fiddly — it has to be idempotent against a settings file
    /// the user also edits, across three hook events — and two implementations of it
    /// would drift. `Contents/Helpers/liddy` is the same binary the docs tell people to
    /// run, so the button and the command cannot disagree.
    private func installClaudeHook() {
        guard let cli = Bundle.main.url(forAuxiliaryExecutable: "liddy")
                ?? Bundle.main.builtInPlugInsURL.map({ $0.deletingLastPathComponent().appendingPathComponent("Helpers/liddy") })
        else {
            alert = "Bundled liddy CLI not found. Run liddy hook install in a terminal."
            return
        }

        let process = Process()
        process.executableURL = cli
        process.arguments = ["hook", "install"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            alert = process.terminationStatus == 0
                ? "Claude Code hook installed. New sessions hold the Mac per turn."
                : "Could not write ~/.claude/settings.json. Run liddy hook install to see why."
        } catch {
            alert = "Could not run the bundled CLI: \(error.localizedDescription)"
        }
        refreshHealth()
    }

    func openLoginItemSettings() {
        LoginItem.openSystemSettings()
    }

    private func refreshLoginItem() {
        let isEnabled = LoginItem.isEnabled
        let needsApproval = LoginItem.status == .requiresApproval
        if isEnabled != isOpenAtLogin { isOpenAtLogin = isEnabled }
        if needsApproval != loginItemNeedsApproval { loginItemNeedsApproval = needsApproval }
    }

    // MARK: - CLI server

    /// True when something is already listening on the app socket.
    ///
    /// `LineSocketServer.start` opens with `unlink(path)`, which is right for a stale
    /// socket left by a crash and catastrophic for a live one: a second instance
    /// deletes the running app's socket and binds its own, and the first instance keeps
    /// a listener on an inode with no name. Every `liddy` command then reports "Liddy is
    /// not running" while the menu bar still shows it running. Measured on 2026-09-11 by
    /// doing exactly that.
    static func isAnotherInstanceListening() -> Bool {
        let probe = LineSocketClient(path: LiddyPath.appSocket.path)
        guard (try? probe.connect(timeoutSecond: 1)) != nil else { return false }
        probe.disconnect()
        return true
    }

    private func startServer() {
        try? LiddyPath.ensureSupportDirectory()
        guard !Self.isAnotherInstanceListening() else {
            runtime.setSocketBound(false, detail: "another Liddy is already running")
            return
        }
        let server = LineSocketServer(path: LiddyPath.appSocket.path) { [weak self] line, _ in
            guard let self else { return nil }
            // A decode failure used to fall back to `.status`, so a typo'd or
            // version-skewed request got a plausible full snapshot back and the
            // protocol bug stayed invisible. Now it is named on the wire — which is
            // the difference between a lease API a third party can implement and one
            // that lies to them.
            let request: AppRequest
            do {
                request = try Wire.decode(AppRequest.self, from: line)
            } catch {
                return try? Wire.encoder.encode(AppResponse.failed("bad request: \(error)"))
            }
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

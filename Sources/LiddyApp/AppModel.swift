import Foundation
import SwiftUI
import UserNotifications
import LiddyKit

/// Bridges the runtime to SwiftUI and hosts the socket the CLI talks to.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = RuntimeSnapshot()
    @Published private(set) var recentEntry: [LogEntry] = []
    @Published var alert: String?

    /// `nonisolated` on purpose: the runtime is internally queue-confined and safe to
    /// call from any thread, and the CLI socket handler must reach it without hopping
    /// to the main actor — a `liddy status` in a script cannot wait on UI work.
    nonisolated private let runtime = LiddyRuntime()
    private var server: LineSocketServer?

    init() {
        runtime.onChange = { [weak self] snapshot in
            Task { @MainActor in
                self?.snapshot = snapshot
                self?.recentEntry = self?.runtime.recentLog(limit: 12) ?? []
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

    // MARK: - CLI server

    private func startServer() {
        try? LiddyPath.ensureSupportDirectory()
        let server = LineSocketServer(path: LiddyPath.appSocket.path) { [weak self] line in
            guard let self else { return nil }
            let request = (try? Wire.decode(AppRequest.self, from: line)) ?? .status
            let response = self.handleSync(request)
            return try? Wire.encoder.encode(response)
        }
        try? server.start(mode: 0o600)
        self.server = server
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
            ])

        case .updateSetting(let patch):
            let setting = runtime.updateSetting(patch)
            return .ok("soft-battery \(setting.softBatteryPercent)%, "
                       + "hard-battery \(setting.hardBatteryPercent)%, "
                       + "thermal-ceiling \(setting.thermalCeiling.rawValue), "
                       + "idle-release \(setting.idleReleaseSecond)s, "
                       + "charging-only \(setting.isChargingOnly)")

        case .renew(let token, let ttlSecond):
            return runtime.renew(token: token, ttlSecond: ttlSecond)
                ? .ok("renewed")
                : .failed("unknown or expired token — claim again")

        case .release(let token):
            return runtime.release(token: token) ? .ok("released") : .failed("unknown token")

        case .lease:
            let lease = runtime.activeLease
            return .text(lease.isEmpty ? ["nothing claimed"] : lease.map(\.display))

        case .recentLog(let limit):
            return .log(runtime.recentLog(limit: limit))

        case .notify(let title, let body):
            notify("\(title) — \(body)")
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

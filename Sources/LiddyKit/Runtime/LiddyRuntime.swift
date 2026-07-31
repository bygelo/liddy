import Foundation

/// The brain. Owns every piece of hold state and is the only thing allowed to decide
/// that the Mac may sleep again.
///
/// Shape of the loop, once every `tickIntervalSecond`:
///   read battery + thermal → ask the governor → apply the verdict → check the timer
///   → in smart mode, check whether every lease has been gone long enough to release.
public final class LiddyRuntime {
    public static let tickIntervalSecond = 5

    private let queue = DispatchQueue(label: "com.liddy.runtime")
    private var timer: DispatchSourceTimer?

    private let assertion = PowerAssertion()
    private let registry = LeaseRegistry()
    private let helper: HelperClient
    private let log: ActivityLog
    private var watcher: ProcessWatcher

    private var setting: Setting
    private var governor: SafetyGovernor

    private var isHeld = false
    private var isClamshellActive = false
    private var isAutoWatchOn = true
    private var mode: HoldMode = .smart
    private var startedAt: Date?
    private var expiresAt: Date?
    private var lastLeaseSeenAt: Date?
    private var lastStopReason: StopReason?
    private var lastWarning: String?

    /// Fired on every state change so the menu bar can redraw.
    public var onChange: ((RuntimeSnapshot) -> Void)?
    /// Fired for user-visible safety events. The app turns these into notifications.
    public var onAlert: ((String) -> Void)?

    public init(setting: Setting = .load(), log: ActivityLog = ActivityLog(), helper: HelperClient = HelperClient()) {
        self.setting = setting.normalized()
        self.governor = SafetyGovernor(setting: setting)
        self.log = log
        self.helper = helper
        self.watcher = ProcessWatcher(pattern: setting.watchPattern)

        self.watcher.onScan = { [weak self] label in
            self?.queue.async { self?.applyScan(label) }
        }
        self.helper.onDisconnect = { [weak self] in
            self?.queue.async { self?.handleHelperLoss() }
        }
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: self.queue)
            source.schedule(deadline: .now(), repeating: .seconds(Self.tickIntervalSecond))
            source.setEventHandler { [weak self] in self?.tick() }
            self.timer = source
            source.resume()
            if self.isAutoWatchOn { self.watcher.start() }
        }
    }

    /// Called on quit. Everything this tool turns on must be turned back off here.
    public func shutdown() {
        queue.sync {
            timer?.cancel(); timer = nil
            watcher.stop()
            if isClamshellActive { setClamshellLocked(false) }
            if isHeld { stopLocked(reason: .appQuit) }
            helper.disconnect()
        }
    }

    // MARK: - Commands

    public func beginHold(second: Int?, mode: HoldMode) {
        queue.async { [weak self] in self?.beginHoldLocked(second: second, mode: mode) }
    }

    public func endHold(reason: StopReason = .userStopped) {
        queue.async { [weak self] in self?.stopLocked(reason: reason) }
    }

    /// Turning closed-lid on implies a hold — there is no useful state where the lid
    /// is allowed to stay open but nothing is keeping the machine awake.
    public func setClamshell(_ isOn: Bool, second: Int?, mode: HoldMode) throws {
        try queue.sync {
            if isOn {
                guard helper.isAvailable else {
                    throw LiddyError.helperMissing
                }
                try helper.connect()
                beginHoldLocked(second: second, mode: mode)
                try setClamshellLockedThrowing(true)
            } else {
                setClamshellLocked(false)
            }
        }
    }

    public func setAutoWatch(_ isOn: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isAutoWatchOn = isOn
            if isOn {
                self.watcher.start()
            } else {
                self.watcher.stop()
                self.registry.replaceProcessLease([])
            }
            self.publish()
        }
    }

    public func addPattern(_ pattern: String) {
        queue.async { [weak self] in
            guard let self, !pattern.isEmpty else { return }
            guard !self.setting.watchPattern.contains(pattern) else { return }
            self.setting.watchPattern.append(pattern)
            self.watcher.pattern = self.setting.watchPattern
            try? self.setting.save()
            self.publish()
        }
    }

    public func removePattern(_ pattern: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.setting.watchPattern.removeAll { $0 == pattern }
            self.watcher.pattern = self.setting.watchPattern
            try? self.setting.save()
            self.publish()
        }
    }

    public var currentPattern: [String] { queue.sync { setting.watchPattern } }

    // MARK: - Lease (the agent-awareness path)

    /// An explicit declaration of live work. Preferred over process matching: the
    /// agent itself knows whether it is mid-task, and a TTL means a crashed claimer
    /// stops holding the Mac on its own without anything having to notice it died.
    public func claim(label: String, ttlSecond: Int) -> String {
        queue.sync {
            let lease = registry.claim(label: label, ttlSecond: ttlSecond)
            log.append(LogEntry(kind: .leaseAdded, detail: "claim \(label) ttl \(ttlSecond)s"))
            if !isHeld { beginHoldLocked(second: nil, mode: .smart) }
            lastLeaseSeenAt = Date()
            publish()
            return lease.token
        }
    }

    public func renew(token: String, ttlSecond: Int) -> Bool {
        queue.sync {
            let renewed = registry.renew(token: token, ttlSecond: ttlSecond)
            if renewed { lastLeaseSeenAt = Date() }
            return renewed
        }
    }

    public func release(token: String) -> Bool {
        queue.sync {
            let released = registry.release(token: token)
            if released {
                log.append(LogEntry(kind: .leaseRemoved, detail: token))
                publish()
            }
            return released
        }
    }

    public var activeLease: [WorkLease] { queue.sync { registry.active } }

    public func recentLog(limit: Int) -> [LogEntry] { log.recent(limit: limit) }

    public var snapshot: RuntimeSnapshot { queue.sync { makeSnapshot() } }

    // MARK: - Internals (all queue-confined)

    private func beginHoldLocked(second: Int?, mode: HoldMode) {
        self.mode = mode
        if let second {
            expiresAt = Date().addingTimeInterval(TimeInterval(min(second, Setting.maxSessionSecond)))
        } else {
            expiresAt = nil
        }

        guard !isHeld else { publish(); return }

        guard assertion.acquire(reason: "Liddy is protecting a running job") else {
            log.append(LogEntry(kind: .note, detail: "could not create power assertion"))
            return
        }
        isHeld = true
        startedAt = Date()
        lastLeaseSeenAt = Date()
        lastStopReason = nil
        log.append(LogEntry(
            kind: .holdStarted,
            detail: "mode \(mode.rawValue)" + (second.map { ", timer \($0)s" } ?? ", no timer"),
            batteryPercent: BatteryReader.read().percent,
            thermal: ThermalReader.read().level
        ))
        publish()
    }

    private func stopLocked(reason: StopReason) {
        if isClamshellActive { setClamshellLocked(false) }
        guard isHeld else { return }

        assertion.release()
        isHeld = false
        let heldSecond = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        startedAt = nil
        expiresAt = nil
        lastStopReason = reason
        registry.releaseAll()

        log.append(LogEntry(
            kind: .holdStopped,
            detail: "\(reason.summary) after \(heldSecond)s",
            reason: reason,
            batteryPercent: BatteryReader.read().percent,
            thermal: ThermalReader.read().level
        ))
        publish()
    }

    private func setClamshellLockedThrowing(_ isOn: Bool) throws {
        try helper.setClamshell(isOn: isOn)
        isClamshellActive = isOn
        log.append(LogEntry(kind: isOn ? .clamshellOn : .clamshellOff, detail: "disablesleep \(isOn ? 1 : 0)"))
        publish()
    }

    private func setClamshellLocked(_ isOn: Bool) {
        do {
            try setClamshellLockedThrowing(isOn)
        } catch {
            // Failing to turn it *off* is the dangerous direction. The helper's deadman
            // switch is the backstop: dropping the connection makes it revert anyway.
            if !isOn {
                helper.disconnect()
                isClamshellActive = false
                log.append(LogEntry(kind: .helperReverted, detail: "revert delegated to helper deadman switch"))
            }
            onAlert?("Closed-lid toggle failed: \(error.localizedDescription)")
        }
    }

    private func handleHelperLoss() {
        guard isClamshellActive else { return }
        isClamshellActive = false
        log.append(LogEntry(kind: .helperReverted, detail: "helper connection lost", reason: .heartbeatLost))
        onAlert?("Lost the Liddy helper — closed-lid protection is off. Open the lid before moving your Mac.")
        publish()
    }

    private func applyScan(_ label: [String]) {
        registry.replaceProcessLease(label)
        if !label.isEmpty {
            lastLeaseSeenAt = Date()
            if !isHeld && isAutoWatchOn {
                beginHoldLocked(second: nil, mode: .smart)
            }
        }
        publish()
    }

    private func tick() {
        let battery = BatteryReader.read()
        let thermal = ThermalReader.read()

        // Safety runs whenever the lid is held shut, even with no hold of our own —
        // a stale disablesleep is exactly the state that needs a floor watching it.
        guard isHeld || isClamshellActive else { return }

        switch governor.evaluate(battery: battery, thermal: thermal, isClamshellActive: isClamshellActive) {
        case .forceSleep(let reason):
            log.append(LogEntry(
                kind: .safetyWarned,
                detail: "forcing sleep: \(reason.summary)",
                reason: reason,
                batteryPercent: battery.percent,
                thermal: thermal.level
            ))
            onAlert?("Sleeping your Mac: \(reason.summary)")
            stopLocked(reason: reason)
            try? helper.sleepNow(reason: reason.summary)
            return

        case .release(let reason):
            onAlert?("Releasing your Mac: \(reason.summary)")
            stopLocked(reason: reason)
            return

        case .warn(let message):
            if message != lastWarning {
                lastWarning = message
                log.append(LogEntry(kind: .safetyWarned, detail: message,
                                    batteryPercent: battery.percent, thermal: thermal.level))
                onAlert?(message)
            }

        case .proceed:
            lastWarning = nil
        }

        if let expiresAt, Date() >= expiresAt {
            stopLocked(reason: .timerExpired)
            return
        }

        // Smart mode: release once every lease has been gone for the idle window.
        if mode == .smart {
            if registry.isEmpty {
                let idleSince = lastLeaseSeenAt ?? startedAt ?? Date()
                if Date().timeIntervalSince(idleSince) >= TimeInterval(setting.idleReleaseSecond) {
                    stopLocked(reason: .workFinished)
                    return
                }
            } else {
                lastLeaseSeenAt = Date()
            }
        }

        publish()
    }

    private func makeSnapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            isAwakeHeld: isHeld,
            isAssertionActive: assertion.isActive,
            isClamshellActive: isClamshellActive,
            mode: mode,
            startedAt: startedAt,
            expiresAt: expiresAt,
            activeLease: registry.active.map(\.display),
            battery: BatteryReader.read(),
            thermal: ThermalReader.read(),
            lastStopReason: lastStopReason
        )
    }

    private func publish() {
        let snapshot = makeSnapshot()
        DispatchQueue.main.async { [onChange] in onChange?(snapshot) }
    }
}

public enum LiddyError: LocalizedError {
    case helperMissing
    case appNotRunning

    public var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "The Liddy helper is not installed. Run Script/install-helper.sh first."
        case .appNotRunning:
            return "Liddy is not running. Open Liddy.app, or use `liddy -- <command>`."
        }
    }
}

import Foundation

/// The brain. Owns every piece of hold state and is the only thing allowed to decide
/// that the Mac may sleep again.
///
/// Shape of the loop, once every `tickIntervalSecond`:
///   read battery + thermal → ask the governor → apply the verdict → check the timer
///   → in smart mode, check whether every lease has been gone long enough to release.
///
/// `@unchecked Sendable` states the invariant the whole class already runs on and
/// that `AppModel` already depends on with its `nonisolated` handle: every mutable
/// field is touched only from `queue`, and the two callbacks are set once at init
/// before `start()`. The health sweep is the first path that makes the compiler ask
/// — it awaits an actor and comes back on a different thread — but the rule it has
/// to obey is the same one every other path here obeys.
public final class LiddyRuntime: @unchecked Sendable {
    public static let tickIntervalSecond = 5
    /// Health is checked far less often than state is published: the local half is
    /// cheap but spawns `pmset`, and the remote half puts packets on the wire. Every
    /// six ticks is frequent enough to catch a dropped network inside half a minute.
    public static let healthEveryTick = 6

    private let queue = DispatchQueue(label: "com.liddy.runtime")
    private var timer: DispatchSourceTimer?

    private let assertion = PowerAssertion()
    private let registry = LeaseRegistry()
    private let helper: HelperClient
    private let log: ActivityLog
    private var watcher: ProcessWatcher
    private let history = MetricHistory()
    private let networkPath = NetworkPathObserver()
    /// `lazy` only because it needs `networkPath`, which is not available to a stored
    /// initializer. Touched exclusively from `queue`.
    private lazy var probe = HealthProbe(path: networkPath)
    private var health: HealthReport?
    private var isProbeRunning = false
    private var isProbeQueued = false
    /// Callers blocked on a fresh sweep. Drained on `queue` when one lands.
    private var healthWaiter: [(HealthReport) -> Void] = []
    private var tickCount = 0
    private var lastHealthProblem: Set<String> = []
    /// Checks already notified about, so a sustained outage alerts once rather than
    /// every 30 seconds until it clears.
    private var alertedProblem: Set<String> = []
    private var isSocketBound = false

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
    /// Set when the governor forces a stop, and held until conditions genuinely
    /// recover. See `beginHoldLocked` for what this exists to prevent.
    private var safetyLock: StopReason?
    /// Set when the user turns the hold off by hand.
    ///
    /// Without it, "Keep awake" off is meaningless whenever auto-watch is on: the
    /// watched processes are still running, so the next scan re-acquires within ten
    /// seconds and the switch flips itself back on while you are looking at it. Off has
    /// to stay off until *you* say otherwise.
    private var isUserPaused = false
    /// "Keep going anyway", and when it lapses.
    ///
    /// Always bounded. An override with no expiry is just a disabled safety rule that
    /// nobody remembers turning off, and the whole argument for this tool is that its
    /// guardrails are not the optional part.
    private var overrideUntil: Date?

    /// Fired on every state change so the menu bar can redraw.
    public var onChange: ((RuntimeSnapshot) -> Void)?
    /// Fired for user-visible safety events. The app turns these into notifications.
    public var onAlert: ((String) -> Void)?

    /// Injected so the loop can be driven deterministically in a test. The safety
    /// rules are the whole product, and "release, then let auto-watch re-acquire two
    /// seconds later" was a bug that no amount of governor-level testing could catch —
    /// it only exists in the interaction between the governor, the watcher and the
    /// hold. Testing that requires being able to say what the battery is.
    private let readBattery: () -> BatteryReading
    private let readThermal: () -> ThermalReading

    public init(
        setting: Setting = .load(),
        log: ActivityLog = ActivityLog(),
        helper: HelperClient = HelperClient(),
        battery: @escaping () -> BatteryReading = BatteryReader.read,
        thermal: @escaping () -> ThermalReading = ThermalReader.read
    ) {
        self.readBattery = battery
        self.readThermal = thermal
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
        networkPath.start()
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
        networkPath.stop()
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

    /// The app tells the runtime whether the CLI socket actually bound. Losing that
    /// bind is silent otherwise: every `liddy` command reports "Liddy is not running"
    /// while the app sits there running perfectly well.
    public func setSocketBound(_ isBound: Bool, detail: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isSocketBound = isBound
            if !isBound {
                self.log.append(LogEntry(
                    kind: .note, detail: "CLI socket not bound\(detail.map { ": \($0)" } ?? "")"))
            }
            // Re-check straight away rather than leaving the first sweep's answer up
            // for half a minute — that sweep ran before the socket existed.
            self.refreshHealthLocked(battery: readBattery(), thermal: readThermal())
            self.publish()
        }
    }

    /// Waive the releasable safety rules for a bounded window and resume holding.
    ///
    /// Capped rather than trusted: an override is a considered risk, and the longer it
    /// runs unattended the less considered it is.
    public static let maxOverrideSecond = 2 * 3600

    public func setOverride(second: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            let window = min(max(60, second), Self.maxOverrideSecond)
            self.overrideUntil = Date().addingTimeInterval(TimeInterval(window))
            self.log.append(LogEntry(
                kind: .safetyWarned,
                detail: "override for \(window)s"
                    + (self.safetyLock.map { " despite \($0.summary.lowercased())" } ?? ""),
                batteryPercent: self.readBattery().percent,
                thermal: self.readThermal().level))
            // Clears the lock and the pause, and starts holding again — the override is
            // pointless if the thing it unblocks does not then run.
            self.beginHoldLocked(second: nil, mode: .smart, isUserInitiated: true)
        }
    }

    public func clearOverride() {
        queue.async { [weak self] in self?.clearOverrideLocked(detail: "override cancelled") }
    }

    private func clearOverrideLocked(detail: String) {
        guard overrideUntil != nil else { return }
        overrideUntil = nil
        log.append(LogEntry(kind: .note, detail: detail))
        publish()
    }

    private var isOverrideActive: Bool {
        guard let overrideUntil else { return false }
        return Date() < overrideUntil
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

    public var currentSetting: Setting { queue.sync { setting } }

    /// Applied to the live governor immediately, not just on next launch — a floor
    /// you just raised should protect the run you are in the middle of.
    public func updateSetting(_ patch: SettingPatch) -> Setting {
        queue.sync {
            setting = patch.applied(to: setting)
            governor = SafetyGovernor(setting: setting)
            try? setting.save()
            log.append(LogEntry(kind: .note, detail: "setting updated"))
            publish()
            return setting
        }
    }

    // MARK: - Lease (the agent-awareness path)

    /// An explicit declaration of live work. Preferred over process matching: the
    /// agent itself knows whether it is mid-task, and a TTL means a crashed claimer
    /// stops holding the Mac on its own without anything having to notice it died.
    public func claim(label: String, ttlSecond: Int, key: String? = nil) -> String {
        queue.sync {
            let isNew: Bool
            if let key {
                let token = LeaseRegistry.token(forKey: key)
                isNew = !registry.active.contains { $0.token == token }
            } else {
                isNew = true
            }
            let lease = registry.claim(label: label, ttlSecond: ttlSecond, key: key)
            // A per-turn hook re-claims constantly; logging every renewal would bury
            // the entries that explain why a run stopped.
            if isNew {
                log.append(LogEntry(kind: .leaseAdded, detail: "claim \(label) ttl \(ttlSecond)s"))
            }
            // A claim is somebody asking out loud, so it lifts a manual pause — a script
            // that says "I am working now" should be honoured, and the alternative is a
            // pause you set last Tuesday silently costing you an overnight run. It does
            // *not* lift a safety lock: the battery does not care who asked.
            isUserPaused = false

            // The lease is recorded either way — the work is real and the panel should
            // say so — but a claim does not override a safety stop. Otherwise an agent
            // hook firing every turn walks straight through the battery floor.
            if !isHeld && safetyLock == nil {
                beginHoldLocked(second: nil, mode: .smart, isUserInitiated: false)
            }
            lastLeaseSeenAt = Date()
            publish()
            return lease.token
        }
    }

    public func release(key: String) -> Bool {
        release(token: LeaseRegistry.token(forKey: key))
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

    public func recentSample(limit: Int) -> [MetricSample] { queue.sync { history.recent(limit: limit) } }

    // MARK: - Health

    /// Force a sweep now — the menu's Refresh button. Returns immediately; the result
    /// arrives through `onChange` like every other state update, so the UI redraws
    /// itself rather than waiting on the network.
    public func refreshHealth(completion: ((HealthReport) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            if let completion { self.healthWaiter.append(completion) }
            self.refreshHealthLocked(battery: readBattery(), thermal: readThermal())
        }
    }

    public var currentHealth: HealthReport? { queue.sync { health } }

    /// Blocking variant for `liddy health`.
    ///
    /// The CLI is synchronous and one-shot: returning the *previous* sweep means
    /// `liddy set --network-probe off && liddy health` prints a sweep that still
    /// probed the network, which reads as the setting having been ignored. A command
    /// that says "here is the state" has to have looked.
    ///
    /// Must not be called from `queue`. The socket handler it serves runs on its own
    /// connection queue, which is exactly why that handler is not main-actor bound.
    public func healthNow(timeoutSecond: Int = 10) -> HealthReport? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReportBox()
        refreshHealth { report in
            box.value = report
            semaphore.signal()
        }
        // On timeout, fall back to the last completed sweep rather than printing
        // nothing — a stale answer labelled with its own timestamp still beats silence.
        _ = semaphore.wait(timeout: .now() + .seconds(timeoutSecond))
        return box.value ?? currentHealth
    }

    private func refreshHealthLocked(battery: BatteryReading, thermal: ThermalReading) {
        // One sweep at a time — the remote half can take seconds on a bad network, and
        // stacking sweeps would put a growing pile of HEAD requests on the wire. A
        // request that arrives mid-sweep is remembered rather than dropped: dropping it
        // makes the menu's Refresh button do nothing, and leaves the first sweep's
        // startup-transient answers on screen (the app binds its CLI socket just after
        // the runtime's first tick, so that sweep always reports it as missing).
        guard !isProbeRunning else { isProbeQueued = true; return }
        isProbeRunning = true
        isProbeQueued = false

        let context = HealthContext(
            isAwakeHeld: isHeld,
            isAssertionActive: assertion.isActive,
            isClamshellActive: isClamshellActive,
            isSocketBound: isSocketBound,
            isHelperConnected: helper.isConnected,
            helperVersion: helper.lastKnownVersion,
            activeLease: registry.active.map(\.label),
            battery: battery,
            thermal: thermal,
            setting: setting
        )

        let probe = self.probe
        Task { [weak self] in
            let report = await probe.run(context: context)
            self?.queue.async {
                guard let self else { return }
                self.isProbeRunning = false
                self.health = report
                let waiter = self.healthWaiter
                self.healthWaiter.removeAll()
                waiter.forEach { $0(report) }
                self.announce(report)
                self.publish()
                if self.isProbeQueued {
                    self.refreshHealthLocked(
                        battery: self.readBattery(), thermal: self.readThermal())
                }
            }
        }
    }

    /// Notify once per confirmed failure, and only while something is actually being
    /// protected. A red row on an idle Mac is information; a red row at 3am during an
    /// eight-hour run is the reason this panel exists.
    ///
    /// A check must be down on **two consecutive sweeps** before it is worth a
    /// notification — the same two-strikes rule the network probe applies to itself,
    /// extended to alerting so it also covers the local checks. Without it, every
    /// launch fired "CLI socket — not bound": the first sweep runs from the runtime's
    /// own first tick, which happens before the app has bound the socket, so the alarm
    /// was true for about a second and wrong by the time anyone read it.
    private func announce(_ report: HealthReport) {
        let broken = Set(report.check.filter { $0.state == .down }.map(\.id))
        let confirmed = broken.intersection(lastHealthProblem)
        defer {
            lastHealthProblem = broken
            // Forget anything that recovered, so a future failure can alert again.
            alertedProblem.formIntersection(broken)
        }
        guard isHeld || isClamshellActive else { return }

        for check in report.check
        where confirmed.contains(check.id) && !alertedProblem.contains(check.id) {
            alertedProblem.insert(check.id)
            log.append(LogEntry(kind: .safetyWarned, detail: "health: \(check.label): \(check.detail)"))
            onAlert?("\(check.label): \(check.detail)")
        }
    }

    // MARK: - Internals (all queue-confined)

    /// Stop re-arming until the machine recovers.
    private func engageSafetyLockLocked(_ reason: StopReason) {
        guard safetyLock == nil else { return }
        safetyLock = reason
        log.append(LogEntry(kind: .safetyWarned, detail: "holding back: \(reason.summary)", reason: reason))
    }

    private func clearSafetyLockLocked() {
        guard let reason = safetyLock else { return }
        safetyLock = nil
        log.append(LogEntry(kind: .note, detail: "recovered from \(reason.summary), holds allowed again"))
        publish()
    }

    /// - Parameter isUserInitiated: a hold the user asked for by hand clears the lock
    ///   and is always attempted — the governor still gets the next word a few seconds
    ///   later, so an unsafe override stops again immediately and says why, once,
    ///   instead of looping. An *automatic* hold is refused outright when the governor
    ///   would only undo it, which also covers the cold-start case the lock alone
    ///   misses: at 15% on battery with nothing yet held, there is no lock to consult,
    ///   and the first claim would otherwise acquire an assertion for one tick.
    private func beginHoldLocked(second: Int?, mode: HoldMode, isUserInitiated: Bool = true) {
        if isUserInitiated {
            clearSafetyLockLocked()
            isUserPaused = false
        } else {
            let verdict = governor.evaluate(
                battery: readBattery(), thermal: readThermal(), isClamshellActive: isClamshellActive)
            if let reason = verdict.reason {
                engageSafetyLockLocked(reason)
                publish()
                return
            }
        }
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
            batteryPercent: readBattery().percent,
            thermal: readThermal().level
        ))
        publish()
    }

    private func stopLocked(reason: StopReason) {
        // Only a hand-made stop pauses. A timer running out or work finishing is the
        // system doing its job, and the next real workload should hold normally.
        if reason == .userStopped { isUserPaused = true }
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
            batteryPercent: readBattery().percent,
            thermal: readThermal().level
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
        onAlert?("Lost the Liddy helper. Closed-lid protection is off, so open the lid before moving your Mac.")
        publish()
    }

    private func applyScan(_ label: [String]) {
        registry.replaceProcessLease(label)
        if !label.isEmpty {
            lastLeaseSeenAt = Date()
            // `safetyLock` is the whole reason this condition is not just `!isHeld`.
            // The watched processes are still running *because* the governor released
            // the Mac rather than killing anything, so without the lock this line
            // re-acquires the hold ~10s after every safety stop, the next tick stops it
            // again, and the floor becomes a 10-second flap that never actually lets the
            // Mac sleep — while re-notifying the user on every cycle.
            if !isHeld && isAutoWatchOn && safetyLock == nil && !isUserPaused {
                beginHoldLocked(second: nil, mode: .smart, isUserInitiated: false)
            }
        }
        publish()
    }

    private func tick() {
        let battery = readBattery()
        let thermal = readThermal()

        // Sampled and probed before the safety guard below, not after: an idle Mac is
        // exactly when you want to look at the panel and see that the network and the
        // helper are fine *before* kicking off an overnight run.
        history.append(MetricSample(
            at: Date(),
            leaseCount: registry.active.count,
            batteryPercent: battery.percent,
            thermalRank: thermal.level.rank,
            isHeld: isHeld
        ))

        tickCount += 1
        if tickCount % Self.healthEveryTick == 1 {
            refreshHealthLocked(battery: battery, thermal: thermal)
        }

        // Lock maintenance runs *before* the guard below, because a lock is held while
        // nothing is held — that is the point of it. Checked here, it lifts on its own
        // as soon as the machine recovers.
        if overrideUntil != nil && !isOverrideActive {
            clearOverrideLocked(detail: "override expired, safety rules back on")
        }

        if safetyLock != nil {
            let verdict = governor.evaluate(
                battery: battery, thermal: thermal, isClamshellActive: isClamshellActive)
            // Cleared only on `.proceed`, never on `.warn`, and that is where the
            // hysteresis comes from: the governor already warns until the battery is
            // 10 points clear of the floor, so a release at 25% does not re-arm until
            // 35% or mains power. Clearing on `.warn` would re-acquire at 26% and drop
            // again at 25% — the same flap in slower motion.
            if verdict == .proceed { clearSafetyLockLocked() }
        }

        // Safety runs whenever the lid is held shut, even with no hold of our own —
        // a stale disablesleep is exactly the state that needs a floor watching it.
        guard isHeld || isClamshellActive else { return }

        switch governor.evaluate(
            battery: battery,
            thermal: thermal,
            isClamshellActive: isClamshellActive,
            isOverrideActive: isOverrideActive
        ) {
        case .forceSleep(let reason):
            // A forced stop voids the override outright. These are the rules an
            // override was never allowed to reach, and leaving it armed afterwards
            // would waive the *next* releasable rule on the way down as well.
            clearOverrideLocked(detail: "override void, \(reason.summary.lowercased())")
            engageSafetyLockLocked(reason)
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
            engageSafetyLockLocked(reason)
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

    // MARK: - Test seams

    /// Run one loop iteration synchronously, instead of waiting out the 5s timer.
    func tickForTest() { queue.sync { tick() } }

    /// Deliver a process scan as the watcher would, without a real `ps`.
    func applyScanForTest(_ label: [String]) { queue.sync { applyScan(label) } }

    private func makeSnapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            isAwakeHeld: isHeld,
            isAssertionActive: assertion.isActive,
            isClamshellActive: isClamshellActive,
            mode: mode,
            startedAt: startedAt,
            expiresAt: expiresAt,
            activeLease: registry.active.map(\.display),
            battery: readBattery(),
            thermal: readThermal(),
            lastStopReason: lastStopReason,
            health: health,
            blockedBy: safetyLock,
            isAutoWatchOn: isAutoWatchOn,
            isUserPaused: isUserPaused,
            overrideUntil: isOverrideActive ? overrideUntil : nil
        )
    }

    private func publish() {
        let snapshot = makeSnapshot()
        DispatchQueue.main.async { [onChange] in onChange?(snapshot) }
    }
}

/// Carries a sweep across the semaphore in `healthNow`. A plain captured `var` cannot
/// be mutated from an escaping closure under strict-concurrency checking.
private final class ReportBox: @unchecked Sendable {
    var value: HealthReport?
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

import Foundation

/// The `pmset` invocation, behind a protocol so a test can assert what the guard
/// would have run without touching the machine's real power settings.
public protocol PmsetRunning: AnyObject {
    /// - Returns: true iff `pmset` exited 0.
    func run(_ argument: [String]) -> Bool
}

/// Where the "we left `disablesleep` on" note lives across a helper restart.
public protocol ClamshellStateStoring: AnyObject {
    func load() -> ClamshellState?
    func save(_ state: ClamshellState?)
}

/// Deferred work with exactly one pending item — the deadman timer. Injected so a
/// test can fire the timer instead of waiting 15 seconds for it.
public protocol DelayScheduling: AnyObject {
    func schedule(afterSecond: Int, _ work: @escaping () -> Void)
    func cancel()
}

public struct ClamshellState: Codable, Sendable, Equatable {
    public var isClamshellOn: Bool
    public var setAt: Date

    public init(isClamshellOn: Bool, setAt: Date) {
        self.isClamshellOn = isClamshellOn
        self.setAt = setAt
    }
}

/// Liddy's one privileged lever, with the deadman switch that gives it back.
///
/// This type used to live inside the `LiddyHelper` executable, where no test could
/// import it — which is how the connection-ownership bug below shipped unnoticed.
///
/// **Connection ownership is the load-bearing rule here.** The deadman reverts when
/// *the client that armed it* goes away, not when *any* client does. Reverting on any
/// disconnect meant `liddy doctor` — which opens a second connection to read the
/// helper's status and then closes it — silently ended a live closed-lid session:
/// checking whether lid mode worked broke lid mode.
public final class ClamshellGuard {
    private let pmset: PmsetRunning
    private let store: ClamshellStateStoring
    private let scheduler: DelayScheduling
    private let deadmanSecond: Int
    private let now: () -> Date
    private let log: (String) -> Void

    private let lock = NSLock()
    private var isOnLocked = false
    private var lastHeartbeatAtLocked: Date?
    /// The connection that armed the toggle. Only its disconnect is a deadman event.
    private var ownerLocked: ConnectionId?

    public init(
        pmset: PmsetRunning,
        store: ClamshellStateStoring,
        scheduler: DelayScheduling,
        deadmanSecond: Int,
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.pmset = pmset
        self.store = store
        self.scheduler = scheduler
        self.deadmanSecond = deadmanSecond
        self.now = now
        self.log = log
    }

    public var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        return isOnLocked
    }

    public var lastHeartbeatAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return lastHeartbeatAtLocked
    }

    /// Called at startup: if we left `disablesleep` on, put it back. This is the
    /// recovery path for the case where even the helper died.
    public func reconcileOnLaunch() {
        guard let state = store.load(), state.isClamshellOn else { return }
        log("found leftover disablesleep from \(state.setAt), reverting")
        _ = pmset.run(["-a", "disablesleep", "0"])
        store.save(nil)
    }

    /// Set the toggle. `owner` is the connection asking for it; when turning the
    /// toggle on, that connection becomes the one the deadman watches.
    @discardableResult
    public func set(_ wanted: Bool, owner: ConnectionId? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return setLocked(wanted, owner: owner)
    }

    private func setLocked(_ wanted: Bool, owner: ConnectionId?) -> Bool {
        guard pmset.run(["-a", "disablesleep", wanted ? "1" : "0"]) else {
            log("pmset disablesleep \(wanted ? 1 : 0) FAILED")
            return false
        }
        isOnLocked = wanted
        store.save(wanted ? ClamshellState(isClamshellOn: true, setAt: now()) : nil)
        log("disablesleep \(wanted ? 1 : 0)")
        if wanted {
            if let owner { ownerLocked = owner }
            lastHeartbeatAtLocked = now()
            armDeadman()
        } else {
            scheduler.cancel()
            lastHeartbeatAtLocked = nil
            ownerLocked = nil
        }
        return true
    }

    /// A heartbeat both re-arms the deadman and claims ownership: an app that
    /// reconnected after a crash is the live owner, whatever armed the toggle first.
    public func heartbeat(from owner: ConnectionId? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard isOnLocked else { return }
        if let owner { ownerLocked = owner }
        lastHeartbeatAtLocked = now()
        armDeadman()
    }

    /// A connection closed. No grace period for the owner — a closed connection is
    /// unambiguous — and no effect at all for anyone else.
    public func connectionLost(_ id: ConnectionId) {
        lock.lock(); defer { lock.unlock() }
        guard isOnLocked else { return }
        guard let owner = ownerLocked, owner == id else {
            log("connection \(id.raw) closed, not the owner. Leaving disablesleep on")
            return
        }
        log("owning client disconnected while disablesleep was on, reverting now")
        _ = setLocked(false, owner: nil)
    }

    private func armDeadman() {
        scheduler.cancel()
        scheduler.schedule(afterSecond: deadmanSecond) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.isOnLocked else { return }
            self.log("no heartbeat for \(self.deadmanSecond)s, reverting disablesleep")
            _ = self.setLocked(false, owner: nil)
        }
    }
}

// MARK: - Live implementations

/// Runs the real `/usr/bin/pmset`.
public final class LivePmsetRunner: PmsetRunning {
    public init() {}

    public func run(_ argument: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = argument
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Persists the leftover-toggle note as JSON at a fixed path.
public final class FileClamshellStateStore: ClamshellStateStoring {
    private let url: URL

    public init(path: String = LiddyPath.helperStatePath) {
        self.url = URL(fileURLWithPath: path)
    }

    public func load() -> ClamshellState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Wire.decoder.decode(ClamshellState.self, from: data)
    }

    public func save(_ state: ClamshellState?) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let state else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? Wire.encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// One pending `DispatchWorkItem` on a private serial queue.
public final class QueueDelayScheduler: DelayScheduling {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: DispatchWorkItem?

    public init(label: String = "com.liddy.helper.deadman") {
        self.queue = DispatchQueue(label: label)
    }

    public func schedule(afterSecond: Int, _ work: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        pending?.cancel()
        let item = DispatchWorkItem(block: work)
        pending = item
        queue.asyncAfter(deadline: .now() + .seconds(afterSecond), execute: item)
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        pending?.cancel()
        pending = nil
    }
}

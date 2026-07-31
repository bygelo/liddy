import Foundation

/// One reason the Mac is being held awake.
///
/// Everything that can hold the Mac — a matched process, an explicit agent claim, a
/// wrapped command — is the same shape, so "why awake?" is answered by listing leases
/// rather than by special-casing each feature.
public struct WorkLease: Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// Discovered by name from the process table.
        case process
        /// Declared explicitly over the socket by an agent or a script.
        case claim
        /// A command wrapped by `liddy -- <command>`.
        case command
    }

    public var token: String
    public var label: String
    public var source: Source
    /// nil means "lives as long as the thing backing it" (process-backed leases).
    public var expiresAt: Date?
    public var startedAt: Date

    public init(token: String, label: String, source: Source, expiresAt: Date?, startedAt: Date = Date()) {
        self.token = token
        self.label = label
        self.source = source
        self.expiresAt = expiresAt
        self.startedAt = startedAt
    }

    public func isExpired(asOf now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    public var display: String {
        switch source {
        case .process: return label
        case .claim:   return "\(label) (claimed)"
        case .command: return "\(label) (command)"
        }
    }
}

/// The set of live leases. Process-backed leases are replaced wholesale on every
/// scan; claimed leases survive until they expire or are released.
public final class LeaseRegistry {
    private var store: [String: WorkLease] = [:]
    private let lock = NSLock()

    public init() {}

    public var active: [WorkLease] {
        lock.lock()
        defer { lock.unlock() }
        prune()
        return store.values.sorted { $0.startedAt < $1.startedAt }
    }

    public var isEmpty: Bool { active.isEmpty }

    /// Swap in the current process-backed set, preserving `startedAt` for anything
    /// still running so the log shows how long a build has genuinely been going.
    public func replaceProcessLease(_ label: [String]) {
        lock.lock()
        defer { lock.unlock() }

        let wanted = Set(label)
        for (token, lease) in store where lease.source == .process && !wanted.contains(lease.label) {
            store.removeValue(forKey: token)
        }
        for name in wanted {
            let token = "process:\(name)"
            guard store[token] == nil else { continue }
            store[token] = WorkLease(token: token, label: name, source: .process, expiresAt: nil)
        }
    }

    /// - Parameter key: when given, the lease is keyed rather than random, so
    ///   claiming again with the same key renews the existing lease instead of
    ///   stacking a second one. A per-turn hook depends on this: without it, every
    ///   turn would leak a lease that outlives the work it represented.
    @discardableResult
    public func claim(
        label: String,
        ttlSecond: Int,
        source: WorkLease.Source = .claim,
        key: String? = nil
    ) -> WorkLease {
        lock.lock()
        defer { lock.unlock() }

        let token = key.map { Self.token(forKey: $0) } ?? "\(source.rawValue):\(UUID().uuidString)"
        let expiresAt = Date().addingTimeInterval(TimeInterval(max(1, ttlSecond)))

        if var existing = store[token] {
            existing.expiresAt = expiresAt
            existing.label = label
            store[token] = existing
            return existing
        }

        let lease = WorkLease(token: token, label: label, source: source, expiresAt: expiresAt)
        store[token] = lease
        return lease
    }

    public static func token(forKey key: String) -> String { "claim:key:\(key)" }

    @discardableResult
    public func release(key: String) -> Bool {
        release(token: Self.token(forKey: key))
    }

    /// Push a claimed lease's expiry out. Returns false if the token is unknown or
    /// already reaped — the caller should re-claim rather than assume it is held.
    public func renew(token: String, ttlSecond: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var lease = store[token], lease.source != .process else { return false }
        lease.expiresAt = Date().addingTimeInterval(TimeInterval(max(1, ttlSecond)))
        store[token] = lease
        return true
    }

    @discardableResult
    public func release(token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return store.removeValue(forKey: token) != nil
    }

    public func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
    }

    private func prune() {
        let now = Date()
        for (token, lease) in store where lease.isExpired(asOf: now) {
            store.removeValue(forKey: token)
        }
    }
}

import Foundation

/// One AI agent's line in the panel: is it working right now, and is its API up.
///
/// The two halves are independent and both matter. An agent that is working while its
/// API is down is a run that is burning battery for nothing; an agent that is idle
/// while its API is fine is just an agent you are not using. Collapsing them into a
/// single "status" would lose exactly the case worth waking up for.
public struct AgentStatus: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    /// Fallback glyph, used when the agent's app is not installed on this Mac.
    public var symbolName: String
    /// Candidates for the real app icon, best first. Resolved in the app layer.
    public var bundleIdentifier: [String]
    /// Holding at least one lease — the Mac is awake partly because of this agent.
    public var isWorking: Bool
    /// The lease labels attributed to this agent, for the tooltip.
    public var leaseLabel: [String]
    /// nil when the API was not probed. Idle agents are not probed on purpose: the
    /// alternative is six outbound requests every 30 seconds from a power utility.
    public var serviceState: HealthState?
    public var serviceDetail: String?
    public var latencyMillisecond: Int?

    public init(
        id: String,
        label: String,
        symbolName: String,
        bundleIdentifier: [String] = [],
        isWorking: Bool,
        leaseLabel: [String] = [],
        serviceState: HealthState? = nil,
        serviceDetail: String? = nil,
        latencyMillisecond: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.symbolName = symbolName
        self.bundleIdentifier = bundleIdentifier
        self.isWorking = isWorking
        self.leaseLabel = leaseLabel
        self.serviceState = serviceState
        self.serviceDetail = serviceDetail
        self.latencyMillisecond = latencyMillisecond
    }

    public var workDisplay: String {
        guard isWorking else { return "idle" }
        return leaseLabel.count > 1 ? "working ×\(leaseLabel.count)" : "working"
    }

    public var serviceDisplay: String {
        guard let serviceState else { return "not checked" }
        switch serviceState {
        case .ok:       return latencyMillisecond.map { "API ok · \($0)ms" } ?? "API ok"
        case .degraded: return "API slow"
        case .down:     return "API unreachable"
        case .unknown:  return "API unknown"
        case .off:      return "not checked"
        }
    }

    /// Pure: fold the lease list and the finished health sweep into one row per agent.
    ///
    /// Working agents sort first — the panel is read top-down, and what is running now
    /// is the reason anyone opened it.
    public static func build(
        activeLease: [String],
        health: HealthReport?,
        catalog: [ServiceEndpoint] = ServiceEndpoint.known
    ) -> [AgentStatus] {
        let haystack = activeLease.map { (raw: $0, lowered: $0.lowercased()) }

        let status = catalog.map { endpoint -> AgentStatus in
            let matched = haystack
                .filter { entry in endpoint.leaseMatch.contains { entry.lowered.contains($0) } }
                .map(\.raw)
            let check = health?.check.first { $0.id == "service.\(endpoint.id)" }
            return AgentStatus(
                id: endpoint.id,
                label: endpoint.label,
                symbolName: endpoint.symbolName,
                bundleIdentifier: endpoint.bundleIdentifier,
                isWorking: !matched.isEmpty,
                leaseLabel: matched,
                serviceState: check?.state,
                serviceDetail: check?.detail,
                latencyMillisecond: check?.latencyMillisecond
            )
        }

        return status.sorted { lhs, rhs in
            if lhs.isWorking != rhs.isWorking { return lhs.isWorking }
            return lhs.label < rhs.label
        }
    }
}

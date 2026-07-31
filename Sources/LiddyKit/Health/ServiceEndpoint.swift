import Foundation

/// An API the protected work depends on. Liddy probes reachability only — it never
/// sends credentials, and it never asks for a response body it doesn't parse.
///
/// A 401 from an unauthenticated request is a *success*: the question being answered
/// is "can this machine reach the service", not "is my key valid".
public struct ServiceEndpoint: Sendable, Equatable {
    public let id: String
    public let label: String
    public let url: URL
    /// Lowercased fragments matched against active lease labels. A lease named
    /// "Claude Code · liddy" pulls in the Anthropic endpoint; nothing else does.
    public let leaseMatch: [String]
    /// Probed on every cycle regardless of what is running.
    public let isAlwaysProbed: Bool
    /// Bundle identifiers to look for, best first, so the panel can show the agent's
    /// **real** icon by asking the system for the copy already installed on this Mac.
    /// Kept as plain strings: `LiddyKit` does not link AppKit, and the resolution
    /// happens in the app layer where `NSWorkspace` lives.
    public let bundleIdentifier: [String]

    public init(
        id: String,
        label: String,
        url: URL,
        leaseMatch: [String],
        isAlwaysProbed: Bool = false,
        bundleIdentifier: [String] = []
    ) {
        self.id = id
        self.label = label
        self.url = url
        self.leaseMatch = leaseMatch
        self.isAlwaysProbed = isAlwaysProbed
        self.bundleIdentifier = bundleIdentifier
    }

    /// Anthropic is always probed because Liddy's only first-party integration is the
    /// Claude Code hook — if that agent's API is down, an overnight run protected by
    /// Liddy is burning battery for nothing. Every other provider is probed only while
    /// its agent is actually holding a lease, so an idle Mac makes no outbound requests
    /// beyond the one.
    public static let known: [ServiceEndpoint] = [
        ServiceEndpoint(
            id: "anthropic",
            label: "Claude",
            url: URL(string: "https://api.anthropic.com/v1/models")!,
            leaseMatch: ["claude"],
            isAlwaysProbed: true,
            bundleIdentifier: ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        ),
        ServiceEndpoint(
            id: "openai",
            label: "Codex",
            url: URL(string: "https://api.openai.com/v1/models")!,
            leaseMatch: ["codex", "openai", "chatgpt"],
            bundleIdentifier: ["com.openai.codex", "com.openai.chat"]
        ),
        ServiceEndpoint(
            id: "google",
            label: "Antigravity",
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!,
            leaseMatch: ["gemini", "antigravity"],
            bundleIdentifier: ["com.google.antigravity"]
        ),
        ServiceEndpoint(
            id: "xai",
            label: "Grok",
            url: URL(string: "https://api.x.ai/v1/models")!,
            leaseMatch: ["grok", "xai"],
            bundleIdentifier: ["com.x.grok", "ai.x.grok"]
        ),
        ServiceEndpoint(
            id: "cursor",
            label: "Cursor",
            url: URL(string: "https://api2.cursor.sh/")!,
            leaseMatch: ["cursor"],
            bundleIdentifier: ["com.todesktop.230313mzl4w4u92"]
        ),
        ServiceEndpoint(
            id: "copilot",
            label: "Copilot",
            url: URL(string: "https://api.githubcopilot.com/")!,
            leaseMatch: ["copilot"],
            bundleIdentifier: ["com.github.githubapp", "com.microsoft.copilot-mac", "com.microsoft.VSCode"]
        ),
    ]

    /// Fallback glyph, used only when the agent's app is not installed and there is no
    /// real icon to show. Generic shapes on purpose: this is the stand-in for a logo,
    /// not an imitation of one.
    public var symbolName: String {
        switch id {
        case "anthropic": return "sparkle"
        case "openai":    return "chevron.left.forwardslash.chevron.right"
        case "google":    return "circle.hexagongrid"
        case "xai":       return "x.circle"
        case "cursor":    return "cursorarrow.rays"
        case "copilot":   return "airplane"
        default:          return "cpu"
        }
    }

    /// Pure: which endpoints this set of lease labels calls for.
    public static func selected(
        forLease lease: [String],
        from catalog: [ServiceEndpoint] = known
    ) -> [ServiceEndpoint] {
        let haystack = lease.map { $0.lowercased() }
        return catalog.filter { endpoint in
            if endpoint.isAlwaysProbed { return true }
            return endpoint.leaseMatch.contains { needle in
                haystack.contains { $0.contains(needle) }
            }
        }
    }
}

/// Anthropic's public status page. Reachability says the network works; this says
/// whether the provider itself admits to a problem — the two fail independently, and
/// only one of them is something you can fix at 2am.
public enum ServiceStatusPage {
    public static let anthropic = URL(string: "https://status.anthropic.com/api/v2/status.json")!

    /// Statuspage's `indicator`: none | minor | major | critical.
    public static func state(forIndicator indicator: String) -> HealthState {
        switch indicator.lowercased() {
        case "none":                       return .ok
        case "minor":                      return .degraded
        case "major", "critical":          return .down
        default:                           return .unknown
        }
    }

    /// Pure: pull `status.indicator` and `status.description` out of a statuspage body.
    public static func parse(_ data: Data) -> (state: HealthState, description: String)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = root["status"] as? [String: Any],
              let indicator = status["indicator"] as? String
        else { return nil }
        let description = status["description"] as? String ?? indicator
        return (state(forIndicator: indicator), description)
    }
}

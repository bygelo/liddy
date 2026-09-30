import Foundation

/// Which apps to push into the background for the duration of a hold, and which to
/// give back afterwards.
///
/// **Hiding, not killing and not suspending.** `SIGSTOP` genuinely frees the CPU and
/// genuinely corrupts a browser session, a call, or an upload; `renice` cannot be undone
/// without root, so a "temporary" deprioritise would outlive the run that asked for it.
/// Hiding an app is the mechanism macOS itself uses to make one a candidate for App Nap:
/// occluded windows stop drawing, timers coalesce, and the work the user actually
/// launched gets the cycles and the thermal headroom. It is also the only one of the
/// three that `unhide` fully reverses.
///
/// Pure, so the rules that matter — never touch the app in front of the user, never
/// hide something twice, always give back exactly what was taken — are testable without
/// a window server.
public struct ResourcePlan: Equatable, Sendable {
    public var hide: [String]
    /// Apps to give back: unhide them and stop tracking them. Includes apps that quit
    /// while hidden — unhiding a process that no longer exists is a no-op, and dropping
    /// them from the tracked set is the point.
    public var unhide: [String]

    public static let doNothing = ResourcePlan(hide: [], unhide: [])

    public init(hide: [String], unhide: [String]) {
        self.hide = hide
        self.unhide = unhide
    }

    public var isEmpty: Bool { hide.isEmpty && unhide.isEmpty }

    /// Apps that are never backgrounded, whatever the scope.
    ///
    /// Terminals are the load-bearing entry: every agent session in Tab Warden runs
    /// *inside* one, so hiding the terminal hides the work Liddy is holding the Mac
    /// awake for. The rest are apps where hiding is either useless (Finder) or actively
    /// confusing (Liddy hiding itself).
    public static let neverBackground = [
        "Liddy", "Finder", "System Settings", "Activity Monitor",
        "Warp", "Warp+", "Terminal", "iTerm2", "Ghostty", "Alacritty", "kitty", "WezTerm",
        "Cursor", "Visual Studio Code", "Code", "Xcode", "Antigravity", "Windsurf",
        "Claude", "ChatGPT", "Grok", "Grok Bot", "CodexBar",
    ]

    /// - Parameters:
    ///   - isEnabled: the user's setting.
    ///   - isHolding: whether Liddy is holding the Mac awake right now. The whole
    ///     feature is scoped to a run; outside one, nobody asked us to move windows.
    ///   - wanted: the configured app name, as shown in the Dock.
    ///   - running: the localized names of every running application.
    ///   - hidden: what THIS feature hid and has not given back. Not "what is hidden" —
    ///     an app the user hid themselves is theirs, and unhiding it on release would
    ///     be Liddy rearranging a desktop it was never asked to touch.
    ///   - frontmost: the app the user is looking at, if any. Never hidden, because a
    ///     window vanishing under the pointer reads as a crash.
    ///   - isLidClosed: widens the scope from the configured list to *everything
    ///     irrelevant*. With the lid shut there is no screen to look at, so an app that
    ///     is not hosting live work has no reason to be drawing at all — and this is
    ///     exactly the window in which its CPU costs battery and heat behind a closed
    ///     panel with no airflow. With the lid open the scope stays the explicit list,
    ///     because then the user *is* looking at their desktop.
    ///   - sessionApp: apps tied to a live agent session, from Tab Warden. Never hidden
    ///     for the same reason as the terminals in `neverBackground`.
    public static func plan(
        isEnabled: Bool,
        isHolding: Bool,
        wanted: [String],
        running: [String],
        hidden: [String],
        frontmost: String? = nil,
        isLidClosed: Bool = false,
        sessionApp: [String] = []
    ) -> ResourcePlan {
        // Give everything back the moment either condition drops. Order matters: this
        // runs before the enabled check so that turning the setting off mid-run is a
        // restore rather than an abandonment.
        guard isEnabled, isHolding else {
            return hidden.isEmpty ? .doNothing : ResourcePlan(hide: [], unhide: hidden)
        }

        let runningKey = Set(running.map { $0.lowercased() })
        let hiddenKey = Set(hidden.map { $0.lowercased() })
        let frontKey = frontmost?.lowercased()

        let keep = Set((neverBackground + sessionApp).map { $0.lowercased() })

        // Closed lid: everything running that is not keeping the work alive.
        // Open lid: only what the user listed.
        let candidate = isLidClosed
            ? running.filter { !keep.contains($0.lowercased()) }
            : wanted.filter { runningKey.contains($0.lowercased()) }

        let target = candidate
            .filter { !hiddenKey.contains($0.lowercased()) }
            .filter { $0.lowercased() != frontKey }

        // An app that quit while hidden is no longer ours to give back, and asking the
        // workspace to unhide a dead process is a no-op that would otherwise sit in the
        // hidden list for the rest of the session.
        let vanished = hidden.filter { !runningKey.contains($0.lowercased()) }

        return ResourcePlan(hide: target, unhide: vanished)
    }
}

/// The window-server half of the resource saver, behind a protocol so `LiddyKit` — and
/// every test in it — stays free of AppKit. The live implementation lives in the app
/// target, which is the only place that has a workspace to talk to.
public protocol AppBackgrounding: AnyObject {
    /// Localized names of every running application, as shown in the Dock.
    func runningAppName() -> [String]
    /// The app the user is looking at, if any.
    func frontmostAppName() -> String?
    @discardableResult func hide(_ name: String) -> Bool
    @discardableResult func unhide(_ name: String) -> Bool
}

/// Used by the CLI and by every test that does not care about the feature. Reports
/// nothing running, so `ResourcePlan` decides to do nothing — the correct behaviour for
/// a process with no window server, rather than a crash or a silent partial action.
public final class NoAppBackgrounding: AppBackgrounding {
    public init() {}
    public func runningAppName() -> [String] { [] }
    public func frontmostAppName() -> String? { nil }
    public func hide(_ name: String) -> Bool { false }
    public func unhide(_ name: String) -> Bool { false }
}

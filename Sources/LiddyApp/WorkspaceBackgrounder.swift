import AppKit
import LiddyKit

/// The live `AppBackgrounding`: `NSWorkspace` plus `NSRunningApplication.hide()`.
///
/// This is the only file in the project that can move another application's windows,
/// and it is deliberately three lines of logic with no policy in it. What to hide, when,
/// and what to give back is `ResourcePlan`'s job, where it is testable; this class only
/// knows how to ask the window server.
///
/// `hide()` rather than a signal: see `ResourcePlan` for why `SIGSTOP` and `renice` were
/// both rejected. Hiding is also the only one macOS itself treats as a hint — occluded
/// windows stop drawing and the app becomes a candidate for App Nap.
final class WorkspaceBackgrounder: AppBackgrounding {
    private var application: [NSRunningApplication] {
        // Only apps with a UI. A background daemon has no windows to hide, and asking
        // for its localized name is how you get a nil-titled row in the panel.
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    private func find(_ name: String) -> NSRunningApplication? {
        application.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
    }

    func runningAppName() -> [String] {
        application.compactMap(\.localizedName)
    }

    func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    @discardableResult
    func hide(_ name: String) -> Bool {
        guard let app = find(name), !app.isHidden else { return false }
        return app.hide()
    }

    @discardableResult
    func unhide(_ name: String) -> Bool {
        // Not `activate`: giving an app its windows back is not the same as putting it
        // in front of whatever the user is doing now.
        guard let app = find(name) else { return false }
        return app.unhide()
    }
}

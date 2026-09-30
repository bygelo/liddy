import Foundation

/// Where Liddy.app has to live for macOS to treat it as an installed app.
///
/// Liddy is `LSUIElement` — no Dock icon, no app switcher entry. The only way back
/// to it after a reboot is Spotlight, Login Items, or knowing the path. All three
/// of those look in `/Applications`. A build left in `dist/` works until you log
/// out, and then it is gone: that is the bug this type exists to name.
public enum AppInstall {
    public static let applicationsPath = "/Applications/Liddy.app"

    /// True when this process is the copy in `/Applications`, not a sibling in
    /// `dist/` or a `swift run` binary. Login Items and a stable Spotlight hit
    /// both require that.
    public static func isInApplications(_ bundlePath: String) -> Bool {
        let path = (bundlePath as NSString).standardizingPath
        return path == applicationsPath || path.hasPrefix(applicationsPath + "/")
    }

    /// `swift run` and a SwiftPM `.build` product are not a user-facing install.
    /// Reporting those as "not in Applications" would nag every developer rebuild.
    public static func isDevBuild(_ bundlePath: String) -> Bool {
        let path = (bundlePath as NSString).standardizingPath
        return path.contains("/.build/") || !path.contains(".app")
    }

    /// The health-panel row. Injected `bundlePath` so a test can state the location
    /// instead of depending on whichever bundle XCTest happens to be.
    public static func healthCheck(bundlePath: String) -> HealthCheck {
        if isInApplications(bundlePath) {
            return HealthCheck(
                id: "liddy.install", group: .liddy, label: "Install",
                state: .ok, detail: applicationsPath)
        }
        if isDevBuild(bundlePath) {
            return HealthCheck(
                id: "liddy.install", group: .liddy, label: "Install",
                state: .off, detail: "dev build")
        }
        return HealthCheck(
            id: "liddy.install", group: .liddy, label: "Install",
            state: .degraded,
            detail: "not in /Applications. Open at Login needs it there",
            remedy: .revealApp)
    }
}

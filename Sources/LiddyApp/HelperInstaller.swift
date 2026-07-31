import Foundation
import AppKit
import LiddyKit

/// Installs the privileged helper from inside the app.
///
/// Closed-lid mode is the one feature that needs root, and the only route to it used
/// to be: notice the error, find the repo, open a Terminal, run a shell script. The
/// app already contains everything required — the helper binary is bundled at build
/// time — so the missing piece was only ever asking for authorisation.
///
/// **Why not `SMAppService`.** It is the better API and it is on the roadmap, but
/// registering a system daemon through it requires a Developer ID signature and a
/// `Contents/Library/LaunchDaemons` plist that matches it. This build is ad-hoc
/// signed, so `SMAppService` would fail on exactly the machines that need this to
/// work. One authorisation prompt for one `launchctl bootstrap` is the honest
/// version of what the shell script was already doing.
@MainActor
enum HelperInstaller {
    enum Failure: LocalizedError {
        case notBundled
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notBundled:
                return "This build has no bundled helper. Rebuild with Script/build-app.sh."
            case .cancelled:
                return "Installation cancelled."
            case .failed(let message):
                return "Helper install failed: \(message)"
            }
        }
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/usr/local/libexec/liddy-helper")
    }

    static var isRunning: Bool {
        FileManager.default.fileExists(atPath: LiddyPath.helperSocketPath)
    }

    /// True when this build can actually offer to install. A `swift run` of the app
    /// has no bundle around it, and offering a button that cannot work is the whole
    /// problem being fixed here.
    static var canInstall: Bool { scriptPath != nil }

    private static var scriptPath: String? {
        guard let url = Bundle.main.url(forResource: "install-helper", withExtension: "sh"),
              FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url.path
    }

    /// Blocks while the system authorisation prompt is up, which is the point: the
    /// user is looking at a modal dialog and there is nothing else for the panel to do.
    static func install() throws {
        guard let scriptPath else { throw Failure.notBundled }

        let uid = getuid()
        let script = """
        do shell script "/bin/bash " & quoted form of "\(escaped(scriptPath))" & " \(uid)" \
        with administrator privileges
        """

        var errorInfo: NSDictionary?
        guard let apple = NSAppleScript(source: script) else {
            throw Failure.failed("could not build the authorisation request")
        }
        apple.executeAndReturnError(&errorInfo)

        if let errorInfo {
            // -128 is the user dismissing the password prompt. That is a decision, not
            // a fault, and it should not be reported as a failure.
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { throw Failure.cancelled }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            throw Failure.failed(message)
        }

        guard isInstalled else {
            throw Failure.failed("the installer reported success but the helper is not there")
        }
    }

    /// AppleScript string literals take the same escapes as C, and an app can live at
    /// a path containing quotes or backslashes.
    private static func escaped(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

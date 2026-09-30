import Foundation
import ServiceManagement
import LiddyKit

/// Open at Login, via the supported `SMAppService` API.
///
/// A menu-bar-only app with no Dock icon disappears after a reboot unless something
/// launches it. Login Items are that something. This is *not* the helper daemon —
/// registering a system daemon through `SMAppService` needs a Developer ID, which
/// this build does not have. The main app as a login item does not.
///
/// Ad-hoc signatures get a fresh cdhash on every rebuild, so macOS may treat the
/// next `build-app.sh` as a different app and drop the item. That is the same
/// identity problem the quarantine note already names; a Developer ID is the fix,
/// not a second API.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// On while registered *or* waiting for the System Settings approval click —
    /// the toggle staying on is what tells you the next step is over there, not here.
    static var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    /// Login Items resolve the app by path. A copy in `dist/` or a `swift run`
    /// binary will register, then vanish the next time that path is replaced.
    static var canRegister: Bool {
        AppInstall.isInApplications(Bundle.main.bundlePath)
    }

    static func setEnabled(_ isOn: Bool) throws {
        if isOn {
            try SMAppService.mainApp.register()
        } else if status == .enabled || status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    /// macOS 13+ puts the approval switch in System Settings, not in our panel.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

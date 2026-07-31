import SwiftUI
import LiddyKit

/// Startup and shutdown go through an app delegate rather than `scenePhase`.
///
/// A menu-bar-only app (`LSUIElement`) never reports an `.active` scene phase, so a
/// `scenePhase` hook silently never fires — the socket server would never start and
/// the CLI would sit there talking to nothing. `applicationWillTerminate` is also the
/// only place guaranteed to run on quit, which is where the assertion and the
/// privileged clamshell toggle must be handed back.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

@main
struct LiddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.snapshot.isClamshellActive
                  ? "laptopcomputer.slash"
                  : (delegate.model.snapshot.isAwakeHeld ? "bolt.fill" : "bolt.slash"))
        }
        .menuBarExtraStyle(.window)
    }
}

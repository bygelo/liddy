import AppKit
import Combine
import SwiftUI
import LiddyKit

/// Startup and shutdown go through an app delegate rather than `scenePhase`.
///
/// A menu-bar-only app (`LSUIElement`) never reports an `.active` scene phase, so a
/// `scenePhase` hook silently never fires — the socket server would never start and
/// the CLI would sit there talking to nothing. `applicationWillTerminate` is also the
/// only place guaranteed to run on quit, which is where the assertion and the
/// privileged clamshell toggle must be handed back.
///
/// The status item is owned here rather than declared as a `MenuBarExtra`, for two
/// reasons that both showed up as bugs:
///
///   1. **The icon froze.** A `MenuBarExtra` label closure that reads
///      `delegate.model.snapshot` establishes no dependency on it — SwiftUI tracks
///      `ObservableObject` through a property wrapper, and `@NSApplicationDelegateAdaptor`
///      only republishes when the delegate itself is observable. The scene was evaluated
///      once and the glyph never changed again, so a failing health check could never
///      take the icon. Here the icon is driven by an explicit Combine sink.
///
///   2. **Expanding a section closed the panel.** `menuBarExtraStyle(.window)` is backed
///      by an `NSPanel` that dismisses when it resigns key, and every disclosure in the
///      menu changes the panel's height.
///
/// The dropdown itself is a hand-rolled panel (`MenuPanelController`) rather than the
/// `NSPopover` that replaced the `MenuBarExtra` first: a popover cannot hide its callout
/// arrow, and it anchors to a view, which breaks when a menu-bar manager hides the icon
/// by moving it off-screen. See the notes on `MenuPanel`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem?
    private var panelController: MenuPanelController?
    private var iconSink: AnyCancellable?
    private var resizeSink: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        installStatusItem()
        installPanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item
        applyIcon(Icon(model.snapshot))

        // Deduplicated: the runtime publishes every 5s, but the glyph changes rarely.
        // Reassigning the image on every tick would redraw the menu bar for nothing.
        iconSink = model.$snapshot
            .map(Icon.init)
            .removeDuplicates()
            .sink { icon in
                DispatchQueue.main.async { [weak self] in self?.applyIcon(icon) }
            }
    }

    private func applyIcon(_ icon: Icon) {
        statusItem?.button?.image = NSImage(
            systemSymbolName: icon.symbolName,
            accessibilityDescription: icon.label
        )
    }

    /// The glyph and the words for it, kept together so the menu bar is legible to
    /// VoiceOver — and so a test can read the state back without screenshotting a
    /// 16-point icon.
    struct Icon: Equatable {
        var symbolName: String
        var label: String

        /// A broken check outranks the hold state. Whether the Mac is awake is visible
        /// everywhere; that the helper died three hours into an overnight run is visible
        /// nowhere else, so it takes the glyph.
        init(_ snapshot: RuntimeSnapshot) {
            if snapshot.health?.overall == .down {
                self.init(symbolName: "exclamationmark.triangle.fill", label: "Liddy: a check is failing")
            } else if snapshot.isClamshellActive {
                self.init(symbolName: "laptopcomputer.slash", label: "Liddy: protected, lid can close")
            } else if snapshot.isAwakeHeld {
                self.init(symbolName: "bolt.fill", label: "Liddy: keeping awake")
            } else {
                self.init(symbolName: "bolt.slash", label: "Liddy: idle")
            }
        }

        private init(symbolName: String, label: String) {
            self.symbolName = symbolName
            self.label = label
        }
    }

    // MARK: - Panel

    private func installPanel() {
        let controller = MenuPanelController(rootView: MenuView(model: model))
        panelController = controller

        // The panel sizes itself to the SwiftUI content, so it has to be told when that
        // content changed. `objectWillChange` fires *before* the change lands, hence the
        // hop to the next runloop pass — by then SwiftUI has re-laid-out and
        // `fittingSize` is the new height. This is what makes a disclosure grow the
        // window instead of getting clipped by it.
        resizeSink = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, controller.isVisible else { return }
                controller.resize(anchoredTo: self.statusItem?.button)
            }
    }

    @objc private func togglePopover(_ sender: Any?) {
        panelController?.toggle(relativeTo: statusItem?.button)
    }
}

@main
struct LiddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// The app's UI is the status item, which the delegate owns. `Settings` is the
    /// cheapest legal scene for an `LSUIElement` app — it renders nothing and gives
    /// SwiftUI's `App` lifecycle something to hold.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

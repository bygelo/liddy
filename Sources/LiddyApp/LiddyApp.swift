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
        // Measure and leave, before anything takes a lock on the machine: no socket, no
        // helper connection, no watcher. See `MenuPanelController.isMeasuring`.
        if MenuPanelController.isMeasuring {
            installStatusItem()
            let controller = MenuPanelController(rootView: MenuView(model: model))
            controller.reportGeometry(button: statusItem?.button)
            // `LIDDY_MEASURE_PANEL=open` watches an actually-open panel over several
            // layout passes; anything else measures the content once and leaves.
            // `LIDDY_MEASURE_PANEL=snapshot LIDDY_SNAPSHOT_DIR=/tmp/x` writes every page,
            // light and dark, to PNG — so "the tab bar looks wrong" is checked against a
            // picture rather than a description. The model is not started: the pages
            // draw their empty state, which is enough for layout and never touches the
            // running app's socket.
            if ProcessInfo.processInfo.environment["LIDDY_MEASURE_PANEL"] == "snapshot" {
                PanelSnapshot.writeEveryPage(model: model)
            }
            if ProcessInfo.processInfo.environment["LIDDY_MEASURE_PANEL"] == "open" {
                // Start the model too. Without it there are no ticks, no health sweeps
                // and no publishes — so the backstop resize sink never fires, which is
                // precisely the traffic the panel was misbehaving under. A harness that
                // skips it measures a panel nobody is using.
                model.start()
                panelController = controller
                installPanelResize(controller)
                controller.openAndWatch(button: statusItem?.button)
            }
            controller.measureAndExit()
        }
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
        applyIcon(MenuBarIcon(model.snapshot))

        // Deduplicated: the runtime publishes every 5s, but the glyph changes rarely.
        // Reassigning the image on every tick would redraw the menu bar for nothing.
        // Battery percent is part of the identity, so a 1% drop still lands.
        iconSink = model.$snapshot
            .map(MenuBarIcon.init)
            .removeDuplicates()
            .sink { icon in
                DispatchQueue.main.async { [weak self] in self?.applyIcon(icon) }
            }
    }

    private func applyIcon(_ icon: MenuBarIcon) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: icon.symbolName,
            accessibilityDescription: icon.label
        )
        // Image then percent, the shape every menu-bar meter uses. A title with no
        // imagePosition set lands on top of the glyph on some macOS versions.
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = icon.batteryTitle ?? ""
        button.toolTip = icon.label
    }

    // MARK: - Panel

    private func installPanel() {
        let controller = MenuPanelController(rootView: MenuView(model: model))
        panelController = controller
        installPanelResize(controller)
    }

    private func installPanelResize(_ controller: MenuPanelController) {
        controller.onVisibilityChange = { [weak self] isVisible in
            self?.model.setPanelVisible(isVisible)
        }


        // The panel sizes itself to the SwiftUI content, so it has to be told when that
        // content changed. `objectWillChange` fires *before* the change lands, hence the
        // hop to the next runloop pass — by then SwiftUI has re-laid-out and
        // `fittingSize` is the new height. This is what makes a disclosure grow the
        // window instead of getting clipped by it.
        // A backstop, not the mechanism. The panel now follows its own content from
        // `MeasuringHostingView.onLayout`, in the same pass the content changes; this
        // catches the case where a model update changes the height without SwiftUI
        // laying the hosting view out again.
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

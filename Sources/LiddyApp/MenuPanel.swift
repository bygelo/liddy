import AppKit
import SwiftUI
import LiddyKit

/// The dropdown, as a borderless panel rather than an `NSPopover`.
///
/// Two things forced this, and neither is fixable on a popover:
///
///   1. **The arrow.** `NSPopover` always draws a callout triangle pointing at its
///      anchor. Almost no menu-bar app has one — the platform convention is a plain
///      rounded rectangle hanging under the status item — and there is no API to turn
///      it off.
///
///   2. **Hidden icons.** A popover anchors to its anchor *view*, so it goes wherever
///      that view is. Menu-bar managers like Ice hide an item by moving it off-screen
///      rather than removing it, so the anchor is still a real view at a nonsense
///      position: the panel flew to the top-left corner and the arrow drew itself
///      inside-out trying to point at something off-screen. A panel positions itself,
///      so it can *notice* the anchor is not somewhere a window should hang from and
///      fall back to the corner of the menu bar instead.
final class MenuPanel: NSPanel {
    /// Borderless windows refuse key status by default, which would leave every
    /// toggle and button in the panel dead.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel, its hosted SwiftUI content, and where it appears.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    private let panel: MenuPanel
    private let hosting: NSHostingView<MenuView>
    private var dismissMonitor: Any?
    /// When the panel last closed, so clicking the status item to dismiss it does not
    /// immediately reopen it — the click resigns key (closing the panel) and *then*
    /// fires the button action, which would otherwise toggle it straight back on.
    private var closedAt = Date.distantPast

    /// Matches the system's own menu-bar dropdowns.
    private static let cornerRadius: CGFloat = 11
    /// Gap between the menu bar and the top of the panel.
    private static let menuBarGap: CGFloat = 4
    /// Keeps the panel off the very edge of the screen.
    private static let screenInset: CGFloat = 8
    /// The panel's width, fixed for its whole lifetime.
    ///
    /// Measuring the width from the content instead is what made the panel walk sideways
    /// every time a disclosure opened: `fittingSize.width` moves by a point or two as rows
    /// appear, and an item near the right edge is placed by the right-hand clamp in
    /// `topLeft(for:button:)`, so *any* width change becomes a horizontal jump. Fixing the
    /// width removes the input to that sum.
    private static let width: CGFloat = 340

    /// Where the panel's top-left corner sits, decided once when it opens.
    ///
    /// The panel grows downward from this point and never re-derives it while visible.
    /// Re-anchoring on every model change meant a 5-second tick could also shift the
    /// window under the pointer, mid-click.
    private var pinnedTopLeft: NSPoint?

    var isVisible: Bool { panel.isVisible }

    init(rootView: MenuView) {
        hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        panel = MenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        // Follows the user across spaces and sits above a full-screen app, which is
        // where an overnight run is most likely to be watched from.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // The rounded, blurred background the popover used to provide for free.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Self.cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            // Pins `fittingSize.width`, so measuring the content only ever answers the
            // height question. See `width`.
            hosting.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        panel.contentView = backdrop
        super.init()

        // Dismiss when the *application* stops being active, not when the panel merely
        // resigns key.
        //
        // The global mouse monitor only sees clicks, so Cmd-Tabbing away left the panel
        // floating at `.popUpMenu` level on top of whatever you switched to. But hooking
        // `windowDidResignKey` to fix that would also fire when a `Picker` inside the
        // panel opens its menu — the settings section would dismiss itself the moment
        // you tried to change the thermal ceiling. App-level activation is the signal
        // that actually means "the user went somewhere else".
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil)
    }

    @objc private func applicationDidResignActive() {
        close()
    }

    // MARK: - Showing

    func toggle(relativeTo button: NSStatusBarButton?) {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(closedAt) > 0.2 {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton?) {
        // Placement is decided here and only here, while the panel is still hidden.
        pinnedTopLeft = nil
        layout(anchoredTo: button, animated: false)
        // An accessory app is not active by default, so without this the panel opens
        // behind the frontmost window and loses key on the first click inside it.
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            panel.animator().alphaValue = 1
        }
        installDismissMonitor(button: button)
    }

    func close() {
        // Guarded so a dismissal that arrives twice — a click that both trips the
        // monitor and deactivates the app — cannot re-stamp `closedAt` and swallow the
        // user's next click on the status item.
        guard panel.isVisible else { return }
        removeDismissMonitor()
        closedAt = Date()
        pinnedTopLeft = nil
        panel.orderOut(nil)
    }

    /// Re-measures the SwiftUI content and grows or shrinks the panel to match.
    ///
    /// Only the height moves. The top-left corner was fixed when the panel opened, so a
    /// disclosure pushes the bottom edge down and leaves everything above it exactly
    /// where the user is looking.
    func resize(anchoredTo button: NSStatusBarButton?) {
        layout(anchoredTo: button, animated: true)
    }

    private func layout(anchoredTo button: NSStatusBarButton?, animated: Bool) {
        // Flush pending layout before measuring. The resize is driven by
        // `objectWillChange`, which fires *before* the change lands, so without this the
        // measurement can be one update behind — the window then holds the previous
        // height while the content is already the new one.
        hosting.layoutSubtreeIfNeeded()

        let height = hosting.fittingSize.height
        guard height > 0 else { return }
        let size = NSSize(width: Self.width, height: height)

        let topLeft: NSPoint
        if let pinnedTopLeft {
            topLeft = pinnedTopLeft
        } else {
            guard let computed = self.topLeft(for: size, button: button) else { return }
            topLeft = computed
            pinnedTopLeft = computed
        }

        let frame = PanelGeometry.frame(topLeft: topLeft, width: size.width, height: size.height)
        guard frame != panel.frame else { return }

        // Set, never animate.
        //
        // This used to ease over 0.18s "to match the disclosure animation in the SwiftUI
        // content" — but that animation has since been removed, and every other one with
        // it. So the content snapped to its new layout instantly while the window edge
        // took 180ms to catch up, and for those 180ms the window was the wrong height for
        // what was inside it. That mismatch is what read as the panel shifting: content
        // centred in a box that no longer fitted it. Window and content now change in the
        // same pass, which is the only way they cannot disagree.
        panel.setFrame(frame, display: true)
    }

    // MARK: - Placement

    /// Where the panel's top-left corner goes, or nil when there is nowhere to put it —
    /// see `activeScreen`. Height is deliberately not a parameter: the panel hangs from
    /// this point downward, so how tall it happens to be cannot move it.
    private func topLeft(for size: NSSize, button: NSStatusBarButton?) -> NSPoint? {
        if let anchor = anchorRect(for: button), let screen = screen(containing: anchor) {
            // Centred under the icon, then pushed back inside the screen — an item near
            // the right edge would otherwise hang half of the panel into nothing.
            let x = PanelGeometry.clampedX(
                anchorMidX: anchor.midX,
                width: size.width,
                screenMinX: screen.frame.minX,
                screenMaxX: screen.frame.maxX,
                inset: Self.screenInset)
            return NSPoint(x: x, y: anchor.minY - Self.menuBarGap)
        }

        // No usable anchor: the icon is hidden by a menu-bar manager, has been pushed
        // under the notch, or the status item has no window yet. Hang the panel from
        // the top-right of the active screen, which is where a hidden item's owner
        // would have been anyway.
        guard let screen = activeScreen() else { return nil }
        return NSPoint(
            x: screen.visibleFrame.maxX - size.width - Self.screenInset,
            y: screen.visibleFrame.maxY - Self.menuBarGap)
    }

    /// The status item's on-screen rect, or nil when it is not somewhere a panel can
    /// sensibly hang from.
    ///
    /// The validity test is the whole point of this method. Ice and friends hide an
    /// item by moving its window off-screen or shrinking it to nothing, and the button
    /// keeps reporting a frame the entire time — so "does a button exist" is not the
    /// question. "Is it a real, visible slot in the menu bar" is.
    private func anchorRect(for button: NSStatusBarButton?) -> NSRect? {
        guard let button, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.bounds)
        guard rect.width > 1, rect.height > 1 else { return nil }
        guard let screen = screen(containing: rect) else { return nil }
        // Must actually be up in the menu bar: an off-screen item lands well below it.
        guard rect.maxY > screen.frame.maxY - 40 else { return nil }
        return rect
    }

    private func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    /// Where the user is looking: the screen under the pointer, else the main one.
    ///
    /// Optional because a Mac can genuinely have **no** screens — lid shut with no
    /// external display, which is this app's whole reason to exist. Subscripting
    /// `NSScreen.screens[0]` there is a crash, and the resize sink runs on every model
    /// change, so a panel left open when the lid closed would have found it.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - Dismissal

    /// A borderless panel gets no transient behaviour for free, so clicking away has to
    /// be watched for. Resigning key covers switching apps; the global monitor covers a
    /// click on the desktop or another window of this app.
    private func installDismissMonitor(button: NSStatusBarButton?) {
        removeDismissMonitor()
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            // Clicking the status item itself is the button's job to handle, and it
            // will toggle. Closing here too would double-fire.
            let mouse = NSEvent.mouseLocation
            if let anchor = self.anchorRect(for: button), anchor.insetBy(dx: -2, dy: -2).contains(mouse) {
                return
            }
            self.close()
        }
    }

    private func removeDismissMonitor() {
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        dismissMonitor = nil
    }
}

private extension CGFloat {
    /// Two-bound clamp that tolerates a lower bound above the upper one, which happens
    /// when the panel is wider than the screen it is being placed on.
    func clamped(to lower: CGFloat, and upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return Swift.min(Swift.max(self, lower), upper)
    }
}

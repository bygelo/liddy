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
/// An `NSHostingView` that says when it has laid out.
///
/// This is the jitter fix. The panel used to resize from `model.objectWillChange`, hopped
/// to the next runloop pass — `objectWillChange` fires *before* the value changes, so
/// measuring immediately returns the old height. That left one frame where SwiftUI had
/// already drawn the expanded content while the window was still the old size: the
/// content is centred in a box too small for it, everything shifts, and the next pass
/// puts it back. That single mismatched frame is the jump you see when opening Health.
///
/// Laying out is the only moment the new height is knowable, so the window follows from
/// here, in the same pass, and there is no frame where the two disagree.
final class MeasuringHostingView<Content: View>: NSHostingView<Content> {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

final class MenuPanel: NSPanel {
    /// Borderless windows refuse key status by default, which would leave every
    /// toggle and button in the panel dead.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Take the frame exactly as given.
    ///
    /// AppKit's default is to shove a window that does not fit the screen back inside
    /// it — which for a panel hanging off the menu bar means **moving its top upward**,
    /// behind the menu bar, so the first cards are cut off. That is the "the top is not
    /// hard set" bug: the panel is anchored under the status item and then silently
    /// relocated by the window server the moment its content grows past the screen
    /// bottom. The height is already clamped to the space below the anchor in
    /// `layout`, so there is nothing left for this to usefully do.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Owns the panel, its hosted SwiftUI content, and where it appears.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    private let panel: MenuPanel
    private let hosting: MeasuringHostingView<MenuView>
    /// The content's container. See the note in `init` for why a scroll view rather
    /// than a pair of Auto Layout constraints.
    private let scroll = NSScrollView()
    /// Guards against `setFrame` → `layout()` → `setFrame` recursion.
    private var isResizing = false
    private var dismissMonitor: Any?
    private var escapeMonitor: Any?
    /// Fired when the panel opens or closes, so the runtime can stop sampling readings
    /// only this panel displays.
    var onVisibilityChange: ((Bool) -> Void)?
    /// When the panel last closed, so clicking the status item to dismiss it does not
    /// immediately reopen it — the click resigns key (closing the panel) and *then*
    /// fires the button action, which would otherwise toggle it straight back on.
    private var closedAt = Date.distantPast

    /// Matches the system's own menu-bar dropdowns.
    private static let cornerRadius: CGFloat = 11
    /// Gap between the **bottom edge of the menu bar** and the top of the panel.
    ///
    /// Zero, and measured against the menu bar rather than the status item, because the
    /// status item is not the menu bar. On this display the menu bar is 40pt tall
    /// (notched: screen top 1169, `visibleFrame.maxY` 1129) while the status button is
    /// 31pt and `NSStatusBar.system.thickness` still reports the classic 22 — so
    /// `button.minY - gap` hung the panel at *button inset + gap*, a distance that
    /// silently changes between a notched and an unnotched Mac. `visibleFrame.maxY` is
    /// the one edge that means "the menu bar ends here" on both.
    private static let menuBarGap: CGFloat = 0
    /// Keeps the panel off the very edge of the screen.
    private static let screenInset: CGFloat = 8
    /// The tallest the panel may ever be, regardless of screen.
    ///
    /// A menu-bar dropdown is not a window. Measured with every disclosure open and
    /// real data in it, the content reaches **1330pt** — health alone is fifteen rows —
    /// and clamping only to the screen produced a 1121pt panel that covered the display
    /// top to bottom. That is the screen-filling panel in the bug report. Past this the
    /// content scrolls, which is what the scroll view is for.
    private static let maxHeight: CGFloat = 640

    /// The panel's width, fixed for its whole lifetime.
    ///
    /// Measuring the width from the content instead is what made the panel walk sideways
    /// every time a disclosure opened: `fittingSize.width` moves by a point or two as rows
    /// appear, and an item near the right edge is placed by the right-hand clamp in
    /// `topLeft(for:button:)`, so *any* width change becomes a horizontal jump. Fixing the
    /// width removes the input to that sum.
    private static let width: CGFloat = 300

    /// Where the panel's top-left corner sits, decided once when it opens.
    ///
    /// The panel grows downward from this point and never re-derives it while visible.
    /// Re-anchoring on every model change meant a 5-second tick could also shift the
    /// window under the pointer, mid-click.
    private var pinnedTopLeft: NSPoint?

    var isVisible: Bool { panel.isVisible }

    /// `LIDDY_MEASURE_PANEL=1 Liddy.app/Contents/MacOS/Liddy` prints the height the
    /// content asks for, then exits. The compact pass claimed the panel got shorter;
    /// this is how that claim is checked against a number instead of an impression.
    ///
    /// Called before the model starts, never after: an instance that boots far enough to
    /// bind the CLI socket would `unlink` the running app's socket on its way past.
    static var isMeasuring: Bool {
        ProcessInfo.processInfo.environment["LIDDY_MEASURE_PANEL"] != nil
    }

    /// Dumps the numbers the panel's placement is computed from, so "there is a gap"
    /// becomes a measurement rather than an impression.
    func reportGeometry(button: NSStatusBarButton?) {
        var line = "MENUBAR thickness=\(NSStatusBar.system.thickness)"
        if let screen = button?.window?.screen ?? NSScreen.main {
            line += " screenMaxY=\(screen.frame.maxY) visibleMaxY=\(screen.visibleFrame.maxY)"
            line += " menuBarHeight=\(screen.frame.maxY - screen.visibleFrame.maxY)"
        }
        if let button, let window = button.window {
            let rect = window.convertToScreen(button.bounds)
            line += " buttonMinY=\(rect.minY) buttonMaxY=\(rect.maxY) buttonH=\(rect.height)"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Opens the panel, lets it live through several layout passes, and reports the
    /// window's height each time.
    ///
    /// `measureAndExit` measures the content *before* the panel is shown, which is
    /// exactly the case that stayed correct while the open panel ratcheted itself to
    /// full-screen height. A regression here is only visible over time, so this watches
    /// over time.
    func openAndWatch(button: NSStatusBarButton?, tickCount: Int = 40) {
        show(relativeTo: button)
        for index in 0..<tickCount {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            let screen = activeScreen()
            FileHandle.standardError.write(Data(
                "OPEN \(index) window=\(Int(panel.frame.height)) content=\(Int(hosting.intrinsicContentSize.height)) hostH=\(Int(hosting.frame.height)) scrollY=\(Int(scroll.contentView.bounds.origin.y)) clipH=\(Int(scroll.contentView.bounds.height)) top=\(Int(panel.frame.maxY)) bottom=\(Int(panel.frame.minY))\n".utf8))
        }
        exit(0)
    }

    func measureAndExit() -> Never {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        FileHandle.standardError.write(Data("PANEL \(Int(size.width))x\(Int(size.height))\n".utf8))
        exit(0)
    }

    init(rootView: MenuView) {
        hosting = MeasuringHostingView(rootView: rootView)
        // Content-driven sizing. `fittingSize` on a view that has already been laid out
        // can answer with its current bounds; `intrinsicContentSize` under this option
        // is derived from the SwiftUI content alone, which is the only measurement that
        // cannot feed back into the frame that produced it.
        hosting.sizingOptions = [.intrinsicContentSize]
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
        //
        // `.fullScreenAuxiliary` is the clause that matters over a full-screen window:
        // without it the panel is confined to its own space, so pulling the menu bar
        // down inside Safari-in-full-screen opened the panel *somewhere else*.
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

        // A scroll view, not two constraints.
        //
        // The content is pinned top/leading/trailing and its height comes from the
        // SwiftUI content. Every previous arrangement failed the same way: pin both
        // ends and a window shorter than its content hands SwiftUI a box too small, so
        // the `VStack` centres itself and clips the rings and the mode selector off the
        // **top** while the bottom still looks fine; leave the bottom loose and Auto
        // Layout compresses the hosting view to satisfy the inequality, which does the
        // same thing. A document view inside a clip view cannot be compressed — it is
        // laid out at its own height and the clip view shows the top of it.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        // Overlay style: it appears over the content while scrolling and takes no width,
        // so the panel is exactly as wide with it as without. Only reachable when the
        // content actually overflows, which on a normal screen it never does.
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = hosting
        backdrop.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: backdrop.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),

            hosting.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            // Pins the measured width, so measuring the content only ever answers the
            // height question. See `width`.
            hosting.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        panel.contentView = backdrop
        super.init()

        hosting.onLayout = { [weak self] in self?.followContentHeight() }

        // Dismiss when *another application* becomes active.
        //
        // The global mouse monitor only sees clicks, so Cmd-Tabbing away left the panel
        // floating at `.popUpMenu` level on top of whatever you switched to. Hooking
        // `windowDidResignKey` to fix that would also fire when a `Picker` inside the
        // panel opens its menu — the settings section would dismiss itself the moment
        // you tried to change the thermal ceiling.
        //
        // This used to watch our own `didResignActive`, which only works if opening the
        // panel made us active in the first place. It no longer does (see `show`), so
        // the signal now comes from the workspace: someone else took the foreground.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(otherApplicationDidActivate),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
    }

    @objc private func otherApplicationDidActivate(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
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
        // Deliberately **not** `NSApp.activate(ignoringOtherApps:)`.
        //
        // Activating an accessory app while a full-screen app owns the space makes
        // macOS leave that space — the screen slides back to the desktop and the panel
        // arrives somewhere the user was not looking, which is the whole "does not work
        // on full-screen apps" complaint. A `.nonactivatingPanel` that returns true from
        // `canBecomeKey` takes keyboard focus for its own controls without making the
        // app active, so the toggles still work and the space stays put.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            panel.animator().alphaValue = 1
        }
        scrollToTop()
        onVisibilityChange?(true)
        installDismissMonitor(button: button)
    }

    func close() {
        // Guarded so a dismissal that arrives twice — a click that both trips the
        // monitor and deactivates the app — cannot re-stamp `closedAt` and swallow the
        // user's next click on the status item.
        guard panel.isVisible else { return }
        removeDismissMonitor()
        onVisibilityChange?(false)
        closedAt = Date()
        pinnedTopLeft = nil
        panel.orderOut(nil)
    }

    /// Match the window to the content that has just been laid out.
    ///
    /// Re-entrancy is real here: `setFrame` resizes the content view, which lays out
    /// again, which calls back in. The guard makes the second pass a no-op, and the
    /// frame comparison in `layout` makes a third impossible.
    private func followContentHeight() {
        guard panel.isVisible, !isResizing else { return }
        isResizing = true
        defer { isResizing = false }
        layout(anchoredTo: nil, animated: false)
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

        let measured = hosting.intrinsicContentSize.height > 0
            ? hosting.intrinsicContentSize.height
            : hosting.fittingSize.height
        guard measured > 0 else { return }

        // The ceiling is the room below the anchor, not the height of the screen.
        //
        // Clamping to `visibleFrame.height` was wrong by exactly the menu bar: a panel
        // hanging from y=1129 on a 1129-tall visible frame may only be 1129 tall if it
        // starts at the bottom of the screen. Anything taller runs off the bottom, and
        // a window that runs off the bottom is the one AppKit used to relocate.
        let ceiling = min(ceilingHeight(), Self.maxHeight)
        let size = NSSize(width: Self.width, height: min(measured, ceiling))

        let topLeft: NSPoint
        if let pinnedTopLeft {
            topLeft = pinnedTopLeft
        } else if button == nil {
            // A layout-driven resize before the panel was placed has nothing to anchor
            // to. Leave it alone rather than guessing a corner.
            return
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
        // Implicit animation disabled explicitly rather than relied on: a `setFrame`
        // inside an animation context that something else opened would ease the window
        // edge over 250ms while the content is already at the new size — which is the
        // same one-frame mismatch in slow motion.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: true)
        CATransaction.commit()

        // A clip view keeps its bounds origin when it grows, so a panel that was
        // scrolled while tall and then shrank keeps showing the middle of its content
        // with empty space underneath. Clamp whenever everything fits.
        if hosting.frame.height <= scroll.contentView.bounds.height {
            scrollToTop()
        }
    }

    /// How tall the panel may be: from its own top edge down to the bottom of the
    /// usable screen, less the inset it keeps off every edge.
    private func ceilingHeight() -> CGFloat {
        // `LIDDY_PANEL_CEILING=300` pretends the screen ends 300pt below the anchor, so
        // the too-tall path can be driven on a machine where the content fits.
        if let forced = ProcessInfo.processInfo.environment["LIDDY_PANEL_CEILING"],
           let value = Double(forced) {
            return CGFloat(value)
        }
        guard let screen = activeScreen() else { return 900 }
        let top = pinnedTopLeft?.y ?? screen.visibleFrame.maxY
        let floor = screen.visibleFrame.minY + Self.screenInset
        return max(200, top - floor)
    }

    private func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
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
            // Y from the screen, X from the icon. The panel hangs off the menu bar's
            // bottom edge, which is a fixed line; only the horizontal position has
            // anything to do with where the status item happens to be.
            return NSPoint(x: x, y: screen.visibleFrame.maxY - Self.menuBarGap)
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
        // Escape, the way every system dropdown closes. Local, because the panel holds
        // key while it is open.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.close()
            return nil
        }
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
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
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

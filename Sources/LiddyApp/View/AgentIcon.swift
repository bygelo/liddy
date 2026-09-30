import SwiftUI
import AppKit
import LiddyKit

/// Real app icons, borrowed from the copy already installed on this Mac.
///
/// The alternative — bundling PNGs of each vendor's logo — means redistributing other
/// companies' trademarked artwork inside a binary, and shipping icons that go stale
/// the moment a vendor rebrands. Asking the system for the icon of an app the user
/// already installed avoids both: nothing is redistributed, the artwork is always the
/// current official one, and an agent that is not installed simply has no icon to show
/// rather than a wrong one.
@MainActor
enum AppIconResolver {
    /// Keyed by the candidate list. The value is `NSImage?` rather than `NSImage` so a
    /// miss is cached too — otherwise every redraw re-hits Launch Services for an app
    /// that is not installed, at ~60 lookups a second while the menu is open.
    private static var cache: [String: NSImage?] = [:]

    static func icon(for candidate: [String]) -> NSImage? {
        guard !candidate.isEmpty else { return nil }
        let key = candidate.joined(separator: "|")
        if let cached = cache[key] { return cached }

        let workspace = NSWorkspace.shared
        let resolved = candidate
            .lazy
            .compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            .first
            .map { workspace.icon(forFile: $0.path) }

        cache[key] = resolved
        return resolved
    }

    /// Apps come and go while Liddy is running; the menu's Refresh drops the cache so
    /// installing Cursor does not require a restart to see its icon.
    static func forget() { cache.removeAll() }
}

/// An agent's icon: the real one when the app is installed, the fallback glyph when it
/// is not.
///
/// Idle agents render greyscale and dimmed. Once the row carries full-colour vendor
/// artwork, colour can no longer be what encodes working-vs-idle — the icons would
/// shout over the status. Desaturation gives that job back to the panel.
struct AgentIcon: View {
    var symbolName: String
    var bundleIdentifier: [String]
    var size: CGFloat = 15
    /// Live sessions render in full colour; quiet ones desaturate. Once a row carries
    /// vendor artwork, colour can no longer be what encodes state — the icons would
    /// shout over it — so desaturation gives that job back to the panel.
    var isActive: Bool = true

    var body: some View {
        Group {
            if let image = AppIconResolver.icon(for: bundleIdentifier) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: size - 3))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .saturation(isActive ? 1 : 0)
        .opacity(isActive ? 1 : 0.55)
    }
}

import Foundation

/// The glyph and the words for it, kept together so the menu bar is legible to
/// VoiceOver — and so a test can read the state back without screenshotting a
/// 16-point icon.
///
/// The battery percent sits next to the glyph on purpose. The panel already draws
/// a ring, but the panel is a thing you open; the status item is the thing that is
/// *there*. A keep-awake tool whose most important number is behind a click is
/// asking you to remember to look.
public struct MenuBarIcon: Equatable {
    public var symbolName: String
    public var label: String
    /// Drawn as the status item's title. nil on a Mac with no internal battery.
    public var batteryTitle: String?

    /// A broken check outranks the hold state. Whether the Mac is awake is visible
    /// everywhere; that the helper died three hours into an overnight run is visible
    /// nowhere else, so it takes the glyph.
    public init(_ snapshot: RuntimeSnapshot) {
        if snapshot.health?.overall == .down {
            self.init(
                symbolName: "exclamationmark.triangle.fill",
                label: "Liddy: a check is failing",
                battery: snapshot.battery)
        } else if snapshot.isClamshellActive {
            self.init(
                symbolName: "laptopcomputer.slash",
                label: "Liddy: protected, lid can close",
                battery: snapshot.battery)
        } else if snapshot.isAwakeHeld {
            self.init(
                symbolName: "bolt.fill",
                label: "Liddy: keeping awake",
                battery: snapshot.battery)
        } else {
            self.init(
                symbolName: "bolt.slash",
                label: "Liddy: idle",
                battery: snapshot.battery)
        }
    }

    public init(symbolName: String, label: String, battery: BatteryReading) {
        self.symbolName = symbolName
        self.label = Self.voiceOverLabel(base: label, battery: battery)
        self.batteryTitle = battery.percent.map { "\($0)%" }
    }

    private static func voiceOverLabel(base: String, battery: BatteryReading) -> String {
        guard let percent = battery.percent else { return base }
        return "\(base), battery \(percent) percent"
    }
}

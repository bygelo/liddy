import AppKit
import SwiftUI

/// Renders each panel page to a PNG. Measurement harness only — see
/// `LIDDY_MEASURE_PANEL=snapshot` in `AppDelegate`.
@MainActor
enum PanelSnapshot {
    static func writeEveryPage(model: AppModel) -> Never {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIDDY_SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scale = CGFloat(Double(ProcessInfo.processInfo.environment["LIDDY_SNAPSHOT_SCALE"] ?? "2") ?? 2)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for tab in PanelTab.allCases {
                model.tab = tab
                let hosting = NSHostingView(rootView: MenuView(model: model))
                hosting.appearance = NSAppearance(named: appearance)
                let size = hosting.fittingSize
                hosting.frame = NSRect(origin: .zero, size: size)
                // Flat stand-in for the panel's blurred material, which only draws
                // against a live window server.
                hosting.wantsLayer = true
                hosting.layer?.backgroundColor = (appearance == .darkAqua
                    ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor
                hosting.layoutSubtreeIfNeeded()

                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { continue }
                rep.size = size
                hosting.cacheDisplay(in: hosting.bounds, to: rep)

                let name = "\(tab.rawValue)-\(appearance == .darkAqua ? "dark" : "light").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                FileHandle.standardError.write(Data("SNAPSHOT \(name) \(Int(size.width))x\(Int(size.height))\n".utf8))
            }
        }
        exit(0)
    }
}

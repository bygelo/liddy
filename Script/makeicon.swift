// Renders the Liddy app icon: a macOS-style rounded square in a given tint
// with a white laptop glyph, emitted at every size an .icns needs.
//
//   swift makeicon.swift <hex> <output.iconset>

import AppKit

let argument = CommandLine.arguments
guard argument.count == 3 else {
    FileHandle.standardError.write("usage: makeicon.swift <hex> <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}

let hex = argument[1].hasPrefix("#") ? String(argument[1].dropFirst()) : argument[1]
let iconsetPath = argument[2]

func color(_ hex: String, brightness: CGFloat = 1.0) -> NSColor {
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    let r = CGFloat((value >> 16) & 0xFF) / 255 * brightness
    let g = CGFloat((value >> 8) & 0xFF) / 255 * brightness
    let b = CGFloat(value & 0xFF) / 255 * brightness
    return NSColor(srgbRed: min(r, 1), green: min(g, 1), blue: min(b, 1), alpha: 1)
}

// A laptop is a wide glyph, so its height cannot be driven off point size the
// way a square one can — the same pointSize that fits vertically leaves the
// body far too narrow. Render once, then scale to a target *width*.
func glyph(named name: String, width: CGFloat) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: width, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { return nil }

    let scale = width / symbol.size.width
    let target = NSSize(width: width, height: symbol.size.height * scale)

    // Tint in the glyph's own image. Doing it in the icon context would fill
    // every opaque pixel under the rect — the teal face included — because
    // sourceAtop composites against whatever is already there.
    let white = NSImage(size: target)
    white.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: target))
    NSColor.white.set()
    NSRect(origin: .zero, size: target).fill(using: .sourceAtop)
    white.unlockFocus()
    return white
}

// macOS icons do not fill their canvas — the rounded square occupies 824 of
// 1024 points, with the corner radius just under a quarter of that. Scaling
// both off the canvas keeps every emitted size on the same grid.
func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setShouldAntialias(true)

    let inset = size * (100.0 / 1024.0)
    let square = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = square.width * (185.0 / 824.0)
    let path = CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // A shallow top-to-bottom lift keeps the face from reading as flat vinyl at
    // 512pt without becoming a visible gradient at 16pt.
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(hex, brightness: 1.14).cgColor,
                                       color(hex).cgColor] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: square.maxY),
                               end: CGPoint(x: 0, y: square.minY),
                               options: [])
    context.restoreGState()

    guard let laptop = glyph(named: "laptopcomputer", width: size * (500.0 / 1024.0)) else { return image }

    // Optically centred, not arithmetically — the glyph's mass sits in the
    // screen, so a true centre reads high.
    let drawn = laptop.size
    let origin = NSPoint(x: (size - drawn.width) / 2,
                         y: (size - drawn.height) / 2 + size * 0.012)
    laptop.draw(in: NSRect(origin: origin, size: drawn))

    return image
}

func write(_ image: NSImage, pixel: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixel, height: pixel)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixel, height: pixel))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

try? FileManager.default.createDirectory(atPath: iconsetPath,
                                         withIntermediateDirectories: true)

// iconutil matches these names exactly; a missing pair is a silent bad icon.
let variant: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

for entry in variant {
    let pixel = entry.point * entry.scale
    let suffix = entry.scale == 1 ? "" : "@2x"
    let name = "icon_\(entry.point)x\(entry.point)\(suffix).png"
    write(render(size: CGFloat(pixel)), pixel: pixel, to: "\(iconsetPath)/\(name)")
}

print("wrote \(iconsetPath)")

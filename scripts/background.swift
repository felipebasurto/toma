// Draws the disk-image background: white, a blue arrow from Toma to Aplicaciones, and one line of Spanish.
// Writes Resources/dmg-background.png and Resources/dmg-background@2x.png; build.sh joins them into one TIFF.
// Usage: swift scripts/background.swift
import AppKit

// The window is 540 × 320 points; icon centres are set in build.sh (Toma at x 140, Aplicaciones at x 400, y 150 from top).
let size = NSSize(width: 540, height: 320)

func draw(_ scale: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()

    // Title, top centre. AppKit's origin is bottom-left, so "from the top" means size.height - y.
    let ink = NSColor(srgbRed: 0x37 / 255, green: 0x35 / 255, blue: 0x2F / 255, alpha: 1)
    let muted = NSColor(srgbRed: 0x9B / 255, green: 0x9A / 255, blue: 0x97 / 255, alpha: 1)
    let blue = NSColor(srgbRed: 0x23 / 255, green: 0x83 / 255, blue: 0xE2 / 255, alpha: 1)
    let centred = NSMutableParagraphStyle()
    centred.alignment = .center
    NSAttributedString(string: "Arrastra Toma a Aplicaciones", attributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: ink, .paragraphStyle: centred,
    ]).draw(in: NSRect(x: 0, y: size.height - 62, width: size.width, height: 30))
    NSAttributedString(string: "Después ábrela desde Aplicaciones, Launchpad o Spotlight.", attributes: [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: muted, .paragraphStyle: centred,
    ]).draw(in: NSRect(x: 0, y: size.height - 88, width: size.width, height: 18))

    // The arrow, between the two icons, at the icons' height (y 150 from top → 170 from bottom).
    let y: CGFloat = size.height - 150
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 226, y: y))
    shaft.line(to: NSPoint(x: 306, y: y))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 294, y: y + 15))
    head.line(to: NSPoint(x: 316, y: y))
    head.line(to: NSPoint(x: 294, y: y - 15))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    blue.withAlphaComponent(0.9).setStroke()
    shaft.stroke()
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources")
for scale in [1, 2] {
    let png = draw(scale).representation(using: .png, properties: [:])!
    try png.write(to: resources.appendingPathComponent(scale == 2 ? "dmg-background@2x.png" : "dmg-background.png"))
}
print("Listo: \(resources.path)/dmg-background{,@2x}.png")

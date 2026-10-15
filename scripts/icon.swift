// Draws Toma's app icon (a dashed region with a blue record dot) and writes Resources/Toma.icns.
// Usage: swift scripts/icon.swift
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824 pt tile centred in 1024, continuous-ish corners.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                        NSColor(srgbRed: 0.905, green: 0.945, blue: 0.992, alpha: 1)])!.draw(in: shape, angle: -90)
    NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08).setStroke()
    shape.lineWidth = 2
    shape.stroke()

    // The region.
    let region = NSBezierPath(roundedRect: NSRect(x: 252, y: 300, width: 470, height: 360), xRadius: 34, yRadius: 34)
    region.lineWidth = 34
    region.setLineDash([62, 40], count: 2, phase: 0)
    region.lineCapStyle = .round
    NSColor(srgbRed: 0.215, green: 0.208, blue: 0.184, alpha: 1).setStroke()
    region.stroke()

    // The record dot, on the corner.
    let dot = NSBezierPath(ovalIn: NSRect(x: 612, y: 552, width: 196, height: 196))
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 588, y: 528, width: 244, height: 244)).fill()
    NSColor(srgbRed: 0.137, green: 0.514, blue: 0.886, alpha: 1).setFill()
    dot.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = FileManager.default.temporaryDirectory.appending(path: "Toma.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try draw(size * scale).representation(using: .png, properties: [:])!.write(to: set.appending(path: name))
    }
}
try draw(1024).representation(using: .png, properties: [:])!.write(to: root.appending(path: "Resources/Toma.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appending(path: "Resources/Toma.icns").path]
try p.run(); p.waitUntilExit()
print("Resources/Toma.icns")

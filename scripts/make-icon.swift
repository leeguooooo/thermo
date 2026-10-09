// Renders Resources/AppIcon.icns: a rounded-square tile with a heat gradient,
// a thermometer and a fan ring. Run: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Tile (macOS icon grid: 824pt body inside 1024 canvas)
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); tile.fill()
    ctx.restoreGState()
    tile.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.20, alpha: 1),
                        NSColor(calibratedRed: 0.17, green: 0.20, blue: 0.32, alpha: 1)])!.draw(in: tile, angle: 90)

    // Fan ring: blades around the centre
    let c = NSPoint(x: 512, y: 512)
    NSColor.white.withAlphaComponent(0.10).setFill()
    for i in 0..<7 {
        let blade = NSBezierPath()
        blade.move(to: .zero)
        blade.curve(to: NSPoint(x: 330, y: 60), controlPoint1: NSPoint(x: 90, y: 160), controlPoint2: NSPoint(x: 250, y: 170))
        blade.curve(to: .zero, controlPoint1: NSPoint(x: 260, y: -10), controlPoint2: NSPoint(x: 120, y: -40))
        var t = AffineTransform(translationByX: c.x, byY: c.y)
        t.rotate(byDegrees: CGFloat(i) * 360 / 7)
        blade.transform(using: t)
        blade.fill()
    }

    // Thermometer
    let heat = NSGradient(colors: [NSColor(calibratedRed: 1.00, green: 0.30, blue: 0.20, alpha: 1),
                                   NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.15, alpha: 1),
                                   NSColor(calibratedRed: 1.00, green: 0.85, blue: 0.30, alpha: 1)])!
    let tube = NSBezierPath(roundedRect: NSRect(x: 452, y: 330, width: 120, height: 470), xRadius: 60, yRadius: 60)
    let bulb = NSBezierPath(ovalIn: NSRect(x: 402, y: 210, width: 220, height: 220))
    NSColor.white.withAlphaComponent(0.92).setFill()
    tube.fill(); bulb.fill()
    let innerTube = NSBezierPath(roundedRect: NSRect(x: 482, y: 360, width: 60, height: 330), xRadius: 30, yRadius: 30)
    let innerBulb = NSBezierPath(ovalIn: NSRect(x: 432, y: 240, width: 160, height: 160))
    let mercury = NSBezierPath(); mercury.append(innerTube); mercury.append(innerBulb)
    heat.draw(in: mercury, angle: 90)
    // Tick marks
    NSColor.white.withAlphaComponent(0.55).setFill()
    for i in 0..<4 { NSBezierPath(roundedRect: NSRect(x: 600, y: 470 + CGFloat(i) * 80, width: 60, height: 14), xRadius: 7, yRadius: 7).fill() }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try render(pt * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote", root.appendingPathComponent("AppIcon.icns").path)

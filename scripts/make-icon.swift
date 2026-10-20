import AppKit
import Foundation

// Regenerate the original vector-drawn app icon: swift scripts/make-icon.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MenuMail-icon-" + UUID().uuidString)
let iconset = temporary.appendingPathComponent("MenuMail.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func png(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194)
    NSGradient(starting: NSColor(srgbRed: 0.30, green: 0.57, blue: 1, alpha: 1), ending: NSColor(srgbRed: 0.12, green: 0.22, blue: 0.82, alpha: 1))!.draw(in: background, angle: -90)
    NSColor.white.setStroke()
    let envelope = NSBezierPath(roundedRect: NSRect(x: 236, y: 330, width: 552, height: 364), xRadius: 58, yRadius: 58)
    envelope.lineWidth = 34
    envelope.stroke()
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: 251, y: 673))
    flap.line(to: NSPoint(x: 483, y: 482))
    flap.curve(to: NSPoint(x: 541, y: 482), controlPoint1: NSPoint(x: 502, y: 467), controlPoint2: NSPoint(x: 522, y: 467))
    flap.line(to: NSPoint(x: 773, y: 673))
    flap.lineWidth = 34
    flap.lineCapStyle = .round
    flap.lineJoinStyle = .round
    flap.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try png(size: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/MenuMail.icns").path]
try process.run()
process.waitUntilExit()
precondition(process.terminationStatus == 0)
try png(size: 256).write(to: root.appendingPathComponent("docs/images/icon.png"))
print("Updated Resources/MenuMail.icns and docs/images/icon.png")

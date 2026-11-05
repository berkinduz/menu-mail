import AppKit
import Foundation

// Regenerate the Fold app icon, native menu-bar template and local preview.
// Run from the repository root: swift scripts/make-icon.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Envl.iconset")
let resources = root.appendingPathComponent("Resources")
let images = root.appendingPathComponent("docs/images")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func bitmap(width: Int, height: Int, draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    graphics.imageInterpolation = .high
    NSGraphicsContext.current = graphics
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    graphics.cgContext.clear(bounds)
    draw(bounds)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func png(_ bitmap: NSBitmapImageRep) -> Data {
    bitmap.representation(using: .png, properties: [:])!
}

// The same 120×100 geometry drives the app icon and the 18-point template.
// The outline stays open on its right and top; the dot is a separate shape.
func drawFold(in rect: NSRect, outline: NSColor, fold: NSColor, dot: NSColor, lineWidth: CGFloat = 9) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: rect.minY)
    transform.scaleX(by: rect.width / 120, yBy: rect.height / 100)
    transform.concat()

    let lowerOutline = NSBezierPath()
    lowerOutline.move(to: NSPoint(x: 93, y: 14))
    lowerOutline.line(to: NSPoint(x: 29, y: 14))
    lowerOutline.curve(to: NSPoint(x: 15, y: 28), controlPoint1: NSPoint(x: 20, y: 14), controlPoint2: NSPoint(x: 15, y: 19))
    lowerOutline.line(to: NSPoint(x: 15, y: 83))
    lowerOutline.lineWidth = lineWidth
    lowerOutline.lineCapStyle = .round
    lowerOutline.lineJoinStyle = .round
    outline.setStroke()
    lowerOutline.stroke()

    let innerFold = NSBezierPath()
    innerFold.move(to: NSPoint(x: 15, y: 83))
    innerFold.line(to: NSPoint(x: 58, y: 55))
    innerFold.curve(to: NSPoint(x: 63, y: 54.5), controlPoint1: NSPoint(x: 59.5, y: 54), controlPoint2: NSPoint(x: 61, y: 54))
    innerFold.line(to: NSPoint(x: 87, y: 63))
    innerFold.lineWidth = lineWidth
    innerFold.lineCapStyle = .round
    innerFold.lineJoinStyle = .round
    fold.setStroke()
    innerFold.stroke()

    dot.setFill()
    NSBezierPath(ovalIn: NSRect(x: 94, y: 77, width: 12, height: 12)).fill()
    NSGraphicsContext.restoreGraphicsState()
}

func appIcon(size: Int) -> NSBitmapImageRep {
    bitmap(width: size, height: size) { _ in
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(size) / 1024)
        transform.concat()

        let tile = NSBezierPath(roundedRect: NSRect(x: 84, y: 84, width: 856, height: 856), xRadius: 198, yRadius: 198)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        color(0.12, 0.115, 0.105).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colorsAndLocations:
            (color(0.255, 0.238, 0.210), 0),
            (color(0.170, 0.163, 0.151), 0.45),
            (color(0.105, 0.102, 0.096), 1)
        )!.draw(in: tile, angle: -58)
        let edge = NSBezierPath(roundedRect: NSRect(x: 85.5, y: 85.5, width: 853, height: 853), xRadius: 197, yRadius: 197)
        edge.lineWidth = 2
        color(0.83, 0.79, 0.69, alpha: 0.13).setStroke()
        edge.stroke()

        NSGraphicsContext.saveGraphicsState()
        let relief = NSShadow()
        relief.shadowColor = NSColor.black.withAlphaComponent(0.24)
        relief.shadowBlurRadius = 5
        relief.shadowOffset = NSSize(width: 0, height: -4)
        relief.set()
        drawFold(
            in: NSRect(x: 203, y: 248, width: 636, height: 530),
            outline: color(0.94, 0.92, 0.86),
            fold: color(0.82, 0.65, 0.34),
            dot: color(0.85, 0.69, 0.38),
            lineWidth: size <= 32 ? 12 : 9
        )
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
    }
}

let templateURL = resources.appendingPathComponent("EnvlTemplate.pdf")
var templateBounds = CGRect(x: 0, y: 0, width: 18, height: 18)
let pdf = CGContext(templateURL as CFURL, mediaBox: &templateBounds, nil)!
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
// Optical padding preserves the rounded caps and detached dot at menu-bar size.
drawFold(in: NSRect(x: -0.76, y: 0.75, width: 20.1, height: 16.75), outline: .black, fold: .black, dot: .black)
NSGraphicsContext.restoreGraphicsState()
pdf.endPDFPage()
pdf.closePDF()

for size in [16, 32, 128, 256, 512] {
    try png(appIcon(size: size)).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(appIcon(size: size * 2)).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Envl.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
try png(appIcon(size: 256)).write(to: images.appendingPathComponent("icon.png"))

let nativeTemplate = NSImage(contentsOf: templateURL)!
func templateBitmap(size: Int, ink: NSColor) -> NSBitmapImageRep {
    bitmap(width: size, height: size) { bounds in
        nativeTemplate.draw(in: bounds)
        ink.setFill()
        bounds.fill(using: .sourceIn)
    }
}

func label(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular, ink: NSColor) {
    (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink])
}

let preview = bitmap(width: 1080, height: 700) { bounds in
    color(0.055, 0.064, 0.075).setFill()
    bounds.fill()
    label("Envl · Fold", at: NSPoint(x: 64, y: 619), size: 34, weight: .semibold, ink: color(0.95, 0.94, 0.90))
    label("Open outline, shallow fold, detached dot", at: NSPoint(x: 64, y: 587), size: 17, ink: color(0.62, 0.64, 0.65))
    NSImage(data: png(appIcon(size: 1024)))!.draw(in: NSRect(x: 40, y: 172, width: 380, height: 380))
    label("App icon", at: NSPoint(x: 151, y: 156), size: 18, ink: color(0.76, 0.76, 0.73))

    for (y, dark) in [(360.0, false), (140.0, true)] {
        let panel = NSRect(x: 466, y: y, width: 548, height: 166)
        (dark ? color(0.15, 0.16, 0.165) : color(0.94, 0.925, 0.90)).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 20, yRadius: 20).fill()
        let ink: NSColor = dark ? color(0.97, 0.97, 0.95) : color(0.10, 0.105, 0.11)
        let secondary = dark ? color(0.66, 0.68, 0.68) : color(0.40, 0.40, 0.39)
        label(dark ? "Dark menu bar" : "Light menu bar", at: NSPoint(x: 488, y: y + 126), size: 17, weight: .medium, ink: ink)
        NSImage(data: png(templateBitmap(size: 18, ink: ink)))!.draw(in: NSRect(x: 524, y: y + 64, width: 18, height: 18))
        NSImage(data: png(templateBitmap(size: 54, ink: ink)))!.draw(in: NSRect(x: 718, y: y + 46, width: 54, height: 54))
        label("18 px · actual size", at: NSPoint(x: 488, y: y + 20), size: 14, ink: secondary)
        label("54 px · enlarged", at: NSPoint(x: 688, y: y + 20), size: 14, ink: secondary)
    }
    label("macOS app icon + monochrome menu-bar template", at: NSPoint(x: 64, y: 67), size: 16, ink: color(0.52, 0.55, 0.57))
}
try png(preview).write(to: images.appendingPathComponent("icon-concept-preview.png"))

// Check generated dimensions and transparency without launching the app.
let large = appIcon(size: 1024)
precondition(large.pixelsWide == 1024 && large.pixelsHigh == 1024 && large.hasAlpha)
precondition(large.colorAt(x: 0, y: 0)!.alphaComponent == 0)
precondition(large.colorAt(x: 512, y: 512)!.alphaComponent > 0.99)
let document = CGPDFDocument(templateURL as CFURL)!
precondition(document.numberOfPages == 1)
precondition(document.page(at: 1)!.getBoxRect(.mediaBox) == templateBounds)
for size in [18, 54] {
    let template = templateBitmap(size: size, ink: .black)
    precondition(template.pixelsWide == size && template.pixelsHigh == size && template.hasAlpha)
    precondition(template.colorAt(x: 0, y: 0)!.alphaComponent == 0)
    var visiblePixels = 0
    for y in 0..<size {
        for x in 0..<size {
            let pixel = template.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            if pixel.alphaComponent > 0 {
                visiblePixels += 1
                precondition(pixel.redComponent == 0 && pixel.greenComponent == 0 && pixel.blueComponent == 0)
            }
        }
    }
    precondition(visiblePixels > 0)
}
print("Generated full Envl.iconset, Envl.icns, EnvlTemplate.pdf and icon previews.")
print("Verified 1024-pixel app icon alpha and 18/54-pixel monochrome template rendering.")

#!/usr/bin/env swift
// Renders the CleanLocal app icon at every size macOS needs.
// Usage: swift Scripts/generate-app-icon.swift CleanLocal/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

func renderIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: 1024, height: 1024) // draw in 1024-pt design space

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icon grid: 824×824 body centered in 1024, continuous-corner radius ≈ 185.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Drop shadow beneath the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0.36, 0.40, 0.98).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Brand gradient.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0.33, 0.42, 0.99), color(0.60, 0.36, 0.97), color(0.86, 0.38, 0.80)])?
        .draw(in: body, angle: -55)
    // Soft glows that fade fully to transparent (no visible edges).
    if let cg = NSGraphicsContext.current?.cgContext {
        func glow(center: CGPoint, radius: CGFloat, color: NSColor) {
            let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
            cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        glow(center: CGPoint(x: 820, y: 860), radius: 420, color: NSColor.white.withAlphaComponent(0.28))
        glow(center: CGPoint(x: 170, y: 150), radius: 460, color: color(0.18, 0.82, 0.92).withAlphaComponent(0.55))
    }
    NSGraphicsContext.restoreGraphicsState()

    // Glyph: stacked photos with sparkles (SF Symbol, white).
    let configuration = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color(0.55, 0.36, 0.96), .white]))
    if let symbol = NSImage(systemSymbolName: "sparkles.rectangle.stack.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let size = symbol.size
        let scale = min(520 / size.width, 520 / size.height)
        let target = NSRect(x: 512 - size.width * scale / 2, y: 500 - size.height * scale / 2,
                            width: size.width * scale, height: size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor(srgbRed: 0.2, green: 0.1, blue: 0.5, alpha: 0.35)
        glyphShadow.shadowBlurRadius = 18
        glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
        glyphShadow.set()
        symbol.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
    }

    // Subtle inner edge.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    shape.lineWidth = 3
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for (points, scale) in sizes {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    guard let data = renderIcon(pixels: pixels) else { fatalError("Rendering failed at \(pixels)px") }
    try data.write(to: outputDirectory.appendingPathComponent(name))
    images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(outputDirectory.path)")

#!/usr/bin/env swift
// Generates the AppIcon PNG set: a rounded gradient square with the branch glyph.
// Usage: swift Scripts/make-icon.swift [output-appiconset-dir]
import AppKit

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: "RepoBar/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawMaster(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    let margin = size * 0.094
    let rect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let radius = rect.width * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow like system icons.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    context.addPath(path)
    context.setFillColor(NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.45, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    // Gradient fill.
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [
        NSColor(calibratedRed: 0.29, green: 0.36, blue: 0.95, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.40, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // Subtle highlight.
    let highlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(highlight, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    context.restoreGState()

    // Glyph.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { drawRect in
            symbol.draw(in: drawRect)
            NSColor.white.set()
            drawRect.fill(using: .sourceAtop)
            return true
        }
        let glyphRect = CGRect(
            x: rect.midX - tinted.size.width / 2,
            y: rect.midY - tinted.size.height / 2 - size * 0.01,
            width: tinted.size.width,
            height: tinted.size.height
        )
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -size * 0.006), blur: size * 0.015, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        tinted.draw(in: glyphRect)
        context.restoreGState()
    }
    image.unlockFocus()
    return image
}

func png(from image: NSImage, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let master = drawMaster(size: 1024)
let slots: [(String, Int, Int)] = [
    ("16x16", 1, 16), ("16x16", 2, 32), ("32x32", 1, 32), ("32x32", 2, 64), ("128x128", 1, 128),
    ("128x128", 2, 256), ("256x256", 1, 256), ("256x256", 2, 512), ("512x512", 1, 512), ("512x512", 2, 1024),
]
var images: [[String: String]] = []
for (size, scale, pixels) in slots {
    let name = "icon_\(size)@\(scale)x.png"
    guard let data = png(from: master, pixels: pixels) else { continue }
    try data.write(to: output.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": size])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(output.path)")

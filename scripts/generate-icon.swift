#!/usr/bin/env swift
import AppKit
import Foundation

/// Render an icon at exact pixel dimensions (NOT points — `NSImage(size:)` is
/// point-sized, which on Retina expands to 2× pixels and trips the asset compiler).
func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return rep }
    NSGraphicsContext.current = ctx

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.2237
    let clip = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    clip.addClip()

    // Background — deep slate
    NSColor(calibratedRed: 0.045, green: 0.055, blue: 0.075, alpha: 1).set()
    rect.fill()

    // Top sheen
    if let sheen = NSGradient(starting: NSColor.white.withAlphaComponent(0.06), ending: .clear) {
        sheen.draw(in: rect, angle: 270)
    }

    // Faint grid — only at sizes large enough to read
    if pixels >= 64 {
        NSColor.white.withAlphaComponent(0.04).set()
        let spacing = size / 12
        let lineW = max(0.5, size / 1024)
        for i in 0...12 {
            let p = CGFloat(i) * spacing
            let v = NSBezierPath()
            v.move(to: NSPoint(x: p, y: 0))
            v.line(to: NSPoint(x: p, y: size))
            v.lineWidth = lineW
            v.stroke()
            let h = NSBezierPath()
            h.move(to: NSPoint(x: 0, y: p))
            h.line(to: NSPoint(x: size, y: p))
            h.lineWidth = lineW
            h.stroke()
        }
    }

    // Italic serif "n" — Iowan Old Style for guaranteed glyph coverage
    let fontSize = size * 0.66
    let font = NSFont(name: "IowanOldStyle-BoldItalic", size: fontSize)
        ?? NSFont(name: "IowanOldStyle-Italic", size: fontSize)
        ?? NSFont(name: "Iowan Old Style", size: fontSize)
        ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    let amber = NSColor(calibratedRed: 0.882, green: 0.642, blue: 0.262, alpha: 1)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: amber,
    ]
    let glyph = "n" as NSString
    let glyphSize = glyph.size(withAttributes: attrs)
    let textRect = NSRect(
        x: (size - glyphSize.width) / 2,
        y: (size - glyphSize.height) / 2 - size * 0.05,
        width: glyphSize.width,
        height: glyphSize.height
    )
    glyph.draw(in: textRect, withAttributes: attrs)

    // Small crosshair tick (top-right) — only on bigger sizes
    if pixels >= 64 {
        NSColor.white.withAlphaComponent(0.28).set()
        let crossSize = size * 0.06
        let cx = size * 0.83
        let cy = size * 0.83
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: cx - crossSize / 2, y: cy))
        cross.line(to: NSPoint(x: cx + crossSize / 2, y: cy))
        cross.move(to: NSPoint(x: cx, y: cy - crossSize / 2))
        cross.line(to: NSPoint(x: cx, y: cy + crossSize / 2))
        cross.lineWidth = max(1, size / 256)
        cross.stroke()
    }

    // Hairline inner border
    NSColor.white.withAlphaComponent(0.04).set()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: cornerRadius - 1, yRadius: cornerRadius - 1)
    border.lineWidth = max(1, size / 512)
    border.stroke()

    return rep
}

func savePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("✘ png encode failed: \(path)")
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("✓ \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
    } catch {
        print("✘ write failed: \(path) — \(error)")
    }
}

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "neofsn/Assets.xcassets/AppIcon.appiconset"

let sizes: [(Int, Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]
for (size, scale) in sizes {
    let pixels = size * scale
    let rep = renderIcon(pixels: pixels)
    let filename = "icon_\(size)x\(size)@\(scale)x.png"
    savePNG(rep, to: "\(outDir)/\(filename)")
}

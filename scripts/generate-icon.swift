#!/usr/bin/env swift
import AppKit
import Foundation

/// Render the neofsn app icon: a macOS-blue folder with the wordmark's italic
/// "n" centered on its body. Simple, immediately recognizable, no 3D scene.
///
/// Rendered at exact pixel dimensions into a 16-bit-per-channel bitmap so
/// alpha edges and gradients don't quantize.
func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 16,
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
    guard let nsctx = NSGraphicsContext(bitmapImageRep: rep) else { return rep }
    NSGraphicsContext.current = nsctx
    let ctx = nsctx.cgContext
    let cs = CGColorSpaceCreateDeviceRGB()

    // macOS rounded-square mask.
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.2237
    NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

    // ─── Backdrop — deep slate ────────────────────────────────────────────
    NSColor(calibratedRed: 0.045, green: 0.055, blue: 0.075, alpha: 1).set()
    rect.fill()

    // Soft top-to-bottom sheen (carried over from the original icon).
    if let sheen = NSGradient(starting: NSColor.white.withAlphaComponent(0.06), ending: .clear) {
        sheen.draw(in: rect, angle: 270)
    }

    // Faint grid (also from the original) — adds a "spatial" hint, only at
    // sizes large enough to register as more than noise.
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

    // ─── Folder ──────────────────────────────────────────────────────────
    //
    // Two parts: a small tab on the upper-left, and a larger rounded body
    // beneath that overlaps the tab's lower edge. Standard macOS folder
    // silhouette.
    let folderInset: CGFloat = size * 0.18
    let bodyTop: CGFloat = size * 0.72
    let bodyBottom: CGFloat = size * 0.18
    let bodyLeft: CGFloat = folderInset
    let bodyRight: CGFloat = size - folderInset
    let bodyRadius: CGFloat = size * 0.06

    let tabLeft: CGFloat = bodyLeft + size * 0.02
    let tabRight: CGFloat = bodyLeft + (bodyRight - bodyLeft) * 0.42
    let tabTop: CGFloat = size * 0.80
    let tabBottom: CGFloat = bodyTop - size * 0.04   // slight overlap into the body
    let tabRadius: CGFloat = size * 0.04

    // Tab — drawn first so the body covers its bottom edge.
    let tabRect = NSRect(x: tabLeft, y: tabBottom, width: tabRight - tabLeft, height: tabTop - tabBottom)
    let tabPath = NSBezierPath(roundedRect: tabRect, xRadius: tabRadius, yRadius: tabRadius)
    NSGraphicsContext.saveGraphicsState()
    tabPath.addClip()
    if let tabShading = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.74, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.14, green: 0.34, blue: 0.58, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            tabShading,
            start: NSPoint(x: 0, y: tabTop),
            end: NSPoint(x: 0, y: tabBottom),
            options: []
        )
    }
    NSGraphicsContext.restoreGraphicsState()

    // Body — Finder sky-blue with a soft top-to-bottom shading.
    let bodyRect = NSRect(x: bodyLeft, y: bodyBottom, width: bodyRight - bodyLeft, height: bodyTop - bodyBottom)
    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: bodyRadius, yRadius: bodyRadius)
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    if let bodyShading = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(calibratedRed: 0.26, green: 0.52, blue: 0.78, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.62, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            bodyShading,
            start: NSPoint(x: 0, y: bodyTop),
            end: NSPoint(x: 0, y: bodyBottom),
            options: []
        )
    }
    NSGraphicsContext.restoreGraphicsState()

    // Hairline highlight along the top edge of the body — subtle 3D lift.
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSColor.white.withAlphaComponent(0.18).set()
    let highlightRect = NSRect(x: bodyLeft, y: bodyTop - max(1, size / 512), width: bodyRight - bodyLeft, height: max(1, size / 512))
    NSBezierPath(rect: highlightRect).fill()
    NSGraphicsContext.restoreGraphicsState()

    // ─── Italic "n" wordmark on the body ─────────────────────────────────
    //
    // Iowan Old Style Bold Italic — same font the original icon used and the
    // app's display label uses. Amber so it pops against the blue body.
    let fontSize = size * 0.46
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
    let bodyCenterX = (bodyLeft + bodyRight) / 2
    let bodyCenterY = (bodyTop + bodyBottom) / 2
    let textRect = NSRect(
        x: bodyCenterX - glyphSize.width / 2,
        y: bodyCenterY - glyphSize.height / 2 - size * 0.03,
        width: glyphSize.width,
        height: glyphSize.height
    )
    glyph.draw(in: textRect, withAttributes: attrs)

    // ─── Hairline inner border ───────────────────────────────────────────
    NSColor.white.withAlphaComponent(0.04).set()
    let border = NSBezierPath(
        roundedRect: rect.insetBy(dx: 1, dy: 1),
        xRadius: cornerRadius - 1, yRadius: cornerRadius - 1
    )
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

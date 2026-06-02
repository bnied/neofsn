import Foundation
import SceneKit
import AppKit

enum SceneBuilder {

    // Cell sizing for the unified grid (each grid cell holds either a file or a subdir-island)
    static let cellSize: CGFloat = 2.2
    static let cellSpacing: CGFloat = 0.75
    static let fileBaseWidth: CGFloat = 1.4
    static let subdirPlatformHeight: CGFloat = 0.20

    // Block-height budgets (kept low so tall neighbors don't occlude labels).
    static let fileMaxHeight: CGFloat = 0.30        // root-level file slabs
    static let miniFileMaxHeight: CGFloat = 0.16    // files sitting on a subdir platform
    static let miniSubdirHeight: CGFloat = 0.10     // nested sub-subdir tiles

    // Width budget for a flat floor label inside a single cell.
    // Labels are physically constrained to this width (truncated with ellipsis)
    // so they can never overlap a neighboring cell's label.
    static var labelMaxWorldWidth: CGFloat { cellSize - 0.2 }

    struct LayoutMetrics {
        let halfExtent: CGFloat
    }

    static let floorThickness: CGFloat = 0.5

    /// Build a self-contained "level" node for one folder: a finite floor plate with
    /// the folder's items laid out on top. The node is centered at its own origin
    /// (the floor's top surface is at local y = 0); the caller positions it in the
    /// stack. Returns the node and the grid's half-extent for camera framing.
    static func makeLevelNode(root: FileSystemNode) -> (node: SCNNode, halfExtent: CGFloat) {
        let level = SCNNode()
        level.name = "level"

        struct Item { let node: FileSystemNode; let isSubdir: Bool }
        let items: [Item] =
            root.subdirectories.map { Item(node: $0, isSubdir: true) }
            + root.files.map { Item(node: $0, isSubdir: false) }

        let cols = max(1, Int(ceil(sqrt(Double(max(items.count, 1))))))
        let rows = max(1, Int(ceil(Double(max(items.count, 1)) / Double(cols))))
        let step = cellSize + cellSpacing
        let halfExtent = max(CGFloat(cols), CGFloat(rows)) * step / 2

        level.addChildNode(makeFloorPlate(halfExtent: halfExtent))

        let originX = -CGFloat(cols - 1) * step / 2
        let originZ = -CGFloat(rows - 1) * step / 2
        for (i, item) in items.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = originX + CGFloat(col) * step
            let z = originZ + CGFloat(row) * step
            let view: SCNNode = item.isSubdir
                ? makeSubdirNode(subdir: item.node)
                : makeFileNode(file: item.node, baseWidth: fileBaseWidth, maxHeight: fileMaxHeight)
            view.position = SCNVector3(x, view.position.y, z)
            level.addChildNode(view)
        }

        return (level, halfExtent)
    }

    // MARK: - Floor

    /// Finite floor plate, sized to the grid, with its top surface at local y = 0.
    private static func makeFloorPlate(halfExtent: CGFloat) -> SCNNode {
        let side = (halfExtent + cellSize) * 2
        let box = SCNBox(width: side, height: floorThickness, length: side, chamferRadius: 0.06)
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = NSColor(calibratedWhite: 0.10, alpha: 1)
        mat.roughness.contents = 0.92
        mat.metalness.contents = 0.0
        box.firstMaterial = mat
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(0, -floorThickness / 2, 0)  // top surface at y = 0
        node.name = "floor"
        node.castsShadow = true
        return node
    }

    // MARK: - File slab

    /// One file = a flat slab (wider than tall). The slab IS the named interactive node
    /// so hover/click highlight works directly on its material. An icon plane sits on top.
    private static func makeFileNode(file: FileSystemNode, baseWidth: CGFloat, maxHeight: CGFloat) -> SCNNode {
        let height = slabHeight(forSize: file.size, max: maxHeight)
        let color = colorForAge(modified: file.modificationDate)

        let geom = SCNBox(width: baseWidth, height: height, length: baseWidth, chamferRadius: 0.03)
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = color
        mat.metalness.contents = 0.10
        mat.roughness.contents = 0.55
        geom.firstMaterial = mat

        let node = SCNNode(geometry: geom)
        node.position = SCNVector3(0, height / 2, 0)
        node.name = "file"
        node.setValue(file.url.path, forKey: "fsURL")
        node.castsShadow = true

        // Full-size (root-level) files carry a name label on the slab's top surface,
        // mirroring how folders are labelled. The icon moves to the back half and the
        // label occupies the front strip so they don't overlap. Mini-files on subdir
        // platforms are too small for a label — they keep a centered icon only.
        let labeled = baseWidth >= 1.0
        let topY = height / 2 + 0.012

        let iconWidth = labeled ? baseWidth * 0.5 : baseWidth * 0.66
        let iconZ: CGFloat = labeled ? -(fileCapHeight / 2 + 0.02) : 0
        if let icon = makeFileIconNode(for: file, width: iconWidth) {
            icon.position = SCNVector3(0, topY, iconZ)
            node.addChildNode(icon)
        }

        if labeled {
            let label = makeFlatLabel(text: file.name, accent: false, maxWorldWidth: baseWidth * 0.92)
            label.position = SCNVector3(0, topY, baseWidth / 2 - fileCapHeight / 2 - 0.04)
            node.addChildNode(label)
        }

        return node
    }

    // MARK: - Subdir island

    /// Subdirectory = a flat raised platform; mini file slabs AND mini subdir-platforms
    /// sit on top of it. The platform IS the named interactive node.
    private static func makeSubdirNode(subdir: FileSystemNode) -> SCNNode {
        let platformWidth = cellSize
        let platformHeight = subdirPlatformHeight

        let geom = SCNBox(width: platformWidth, height: platformHeight, length: platformWidth, chamferRadius: 0.04)
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = NSColor(calibratedRed: 0.78, green: 0.58, blue: 0.22, alpha: 1)
        mat.metalness.contents = 0.10
        mat.roughness.contents = 0.55
        geom.firstMaterial = mat

        let node = SCNNode(geometry: geom)
        node.position = SCNVector3(0, platformHeight / 2, 0)
        node.name = "pedestal:subdir"
        node.setValue(subdir.url.path, forKey: "fsURL")
        node.castsShadow = true

        // The folder's name is rendered flat onto the front of the platform's TOP
        // surface (not the floor in front), so neighboring blocks can never occlude
        // it. We reserve a strip of depth `labelStrip` at the front (+Z, toward the
        // default camera) for the label and push the mini-items into the back area.
        let labelStrip = accentCapHeight + 0.06

        // Mini items on top — subdirs first (back rows), then files (front rows).
        struct MiniItem { let fs: FileSystemNode; let isDir: Bool }
        let items: [MiniItem] =
            subdir.subdirectories.map { MiniItem(fs: $0, isDir: true) }
            + subdir.files.map { MiniItem(fs: $0, isDir: false) }

        if !items.isEmpty {
            let cols = max(1, Int(ceil(sqrt(Double(items.count)))))
            let rows = Int(ceil(Double(items.count) / Double(cols)))
            let usableX = platformWidth * 0.86
            let usableZ = platformWidth * 0.86 - labelStrip   // leave the front strip clear
            let stepX = usableX / CGFloat(cols)
            let stepZ = usableZ / CGFloat(max(rows, 1))
            let miniBase = min(stepX, stepZ) * 0.78
            let originX = -CGFloat(cols - 1) * stepX / 2
            // Center the item block in the back region (shifted toward -Z by half the strip).
            let originZ = -labelStrip / 2 - CGFloat(rows - 1) * stepZ / 2

            for (i, item) in items.enumerated() {
                let col = i % cols
                let row = i / cols
                let mini: SCNNode = item.isDir
                    ? makeMiniSubdirNode(subdir: item.fs, size: miniBase)
                    : makeFileNode(file: item.fs, baseWidth: miniBase, maxHeight: miniFileMaxHeight)
                mini.position = SCNVector3(
                    originX + CGFloat(col) * stepX,
                    platformHeight / 2 + mini.position.y,
                    originZ + CGFloat(row) * stepZ
                )
                node.addChildNode(mini)
            }
        }

        // Label laid flat on the platform's top surface, in the front strip.
        let label = makeFlatLabel(text: subdir.name, accent: true, maxWorldWidth: platformWidth * 0.9)
        label.position = SCNVector3(
            0,
            platformHeight / 2 + 0.012,                 // just above the top face
            platformWidth / 2 - accentCapHeight / 2 - 0.06
        )
        node.addChildNode(label)

        return node
    }

    /// A nested sub-subdir rendered as a tiny flat raised tile on its parent's platform.
    /// Has no content of its own (we don't scan that deep), but is still a named
    /// interactive node so clicks descend into it.
    private static func makeMiniSubdirNode(subdir: FileSystemNode, size: CGFloat) -> SCNNode {
        let h: CGFloat = miniSubdirHeight
        let box = SCNBox(width: size, height: h, length: size, chamferRadius: 0.02)
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = NSColor(calibratedRed: 0.86, green: 0.66, blue: 0.28, alpha: 1)
        mat.metalness.contents = 0.10
        mat.roughness.contents = 0.55
        box.firstMaterial = mat

        let node = SCNNode(geometry: box)
        node.position = SCNVector3(0, h / 2, 0)
        node.name = "pedestal:subdir"
        node.setValue(subdir.url.path, forKey: "fsURL")
        node.castsShadow = true

        // A small folder icon centered on top so it reads as "a folder" rather than another file.
        if let icon = makeFolderGlyphNode(width: size * 0.5) {
            icon.position = SCNVector3(0, h / 2 + 0.005, 0)
            node.addChildNode(icon)
        }
        return node
    }

    /// A flat `folder.fill` glyph plane laid on top of a nested sub-subdir tile.
    private static func makeFolderGlyphNode(width: CGFloat) -> SCNNode? {
        guard let image = renderSFSymbol("folder.fill", tint: NSColor(calibratedWhite: 1.0, alpha: 0.92)) else {
            return nil
        }
        let plane = SCNPlane(width: width, height: width)
        let mat = SCNMaterial()
        mat.diffuse.contents = image
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.transparencyMode = .aOne
        plane.firstMaterial = mat
        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        node.name = "icon"
        return node
    }

    // MARK: - File-type icon plane

    /// Map file extension to an SF Symbol. Generic catch-all is `doc`.
    private static func iconName(for file: FileSystemNode) -> String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "m", "h", "c", "cpp", "cc", "rs", "go", "py", "js", "ts", "rb", "java", "kt", "lua":
            return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp":
            return "photo"
        case "mp3", "wav", "aiff", "flac", "m4a", "ogg", "opus":
            return "waveform"
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return "film"
        case "pdf":
            return "doc.richtext"
        case "doc", "docx", "txt", "md", "rtf", "tex":
            return "doc.text"
        case "zip", "tar", "gz", "bz2", "7z", "rar":
            return "archivebox"
        case "dmg", "iso", "img":
            return "opticaldiscdrive"
        case "json", "xml", "yaml", "yml", "toml", "plist":
            return "list.bullet.indent"
        case "html", "htm", "css", "scss", "sass":
            return "globe"
        case "app":
            return "macwindow"
        case "sh", "bash", "zsh", "fish", "command":
            return "terminal"
        case "":
            return file.name.hasPrefix(".") ? "gearshape" : "doc"
        default:
            return "doc"
        }
    }

    /// A flat, tinted SF Symbol plane (per file type) laid on top of a file slab.
    private static func makeFileIconNode(for file: FileSystemNode, width: CGFloat) -> SCNNode? {
        let symbol = iconName(for: file)
        guard let image = renderSFSymbol(symbol, tint: NSColor(calibratedWhite: 0.96, alpha: 1)) else {
            return nil
        }
        let plane = SCNPlane(width: width, height: width)
        let mat = SCNMaterial()
        mat.diffuse.contents = image
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.transparencyMode = .aOne
        mat.writesToDepthBuffer = true
        plane.firstMaterial = mat

        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0) // lay flat, facing up
        node.name = "icon"
        return node
    }

    // MARK: - Labels

    // Cap height (world units) of the text laid on the floor. This becomes the
    // depth (Z extent) of the label once it's rotated flat. The on-screen width
    // is `capHeight × textAspect`, clamped to one cell via truncation.
    private static let accentCapHeight: CGFloat = 0.40
    private static let fileCapHeight: CGFloat = 0.24

    /// A flat label lying on the floor in front of an item.
    ///
    /// Instead of `SCNText` geometry (which drops glyphs in synthesized fonts and
    /// has fiddly extrusion orientation), we render the string to a transparent
    /// bitmap with a dark halo and texture it onto a single plane. This is crisp,
    /// glyph-complete, and orientation is trivial to reason about.
    ///
    /// Orientation: the plane defaults to facing +Z. Rotating -90° about X lays it
    /// flat facing +Y (up). The texture's top edge maps to world -Z (pointing away
    /// from the default camera), so the text reads correctly to a viewer at +Z.
    /// The label is truncated so its world width never exceeds `maxWorldWidth`
    /// (one grid cell) — neighboring labels therefore can never overlap.
    private static func makeFlatLabel(text: String, accent: Bool, maxWorldWidth: CGFloat) -> SCNNode {
        let capHeight = accent ? accentCapHeight : fileCapHeight
        return makeFlatLabelCore(
            text: text, bold: accent, capHeight: capHeight,
            maxWorldWidth: maxWorldWidth, name: "label"
        )
    }

    /// Compact label used when a subfolder is focused, so its individual items
    /// become readable in place. Smaller cap height than the standard labels.
    static func makeContentLabel(text: String, maxWorldWidth: CGFloat) -> SCNNode {
        makeFlatLabelCore(
            text: text, bold: false, capHeight: 0.15,
            maxWorldWidth: maxWorldWidth, name: "focusLabel"
        )
    }

    /// Shared label builder: renders `text` to a texture and lays it flat (facing up,
    /// reading toward the camera), truncated so its world width fits `maxWorldWidth`.
    private static func makeFlatLabelCore(
        text: String, bold: Bool, capHeight: CGFloat, maxWorldWidth: CGFloat, name: String
    ) -> SCNNode {
        let maxAspect = maxWorldWidth / capHeight
        let (_, image, aspect) = renderLabelTexture(text: text, accent: bold, maxAspect: maxAspect)

        let worldWidth = capHeight * aspect
        let plane = SCNPlane(width: worldWidth, height: capHeight)
        let mat = SCNMaterial()
        mat.diffuse.contents = image
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.transparencyMode = .aOne
        // Render a touch above surfaces and don't write depth, so labels never
        // z-fight with the platform/floor planes.
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = true
        plane.firstMaterial = mat

        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        node.name = name
        node.castsShadow = false
        node.renderingOrder = name == "focusLabel" ? 11 : 10
        return node
    }

    /// Render `text` (truncated to fit `maxAspect`) onto a transparent NSImage with
    /// a soft dark halo for legibility against both gold platforms and the dark floor.
    /// Returns the displayed string, the image, and its width/height aspect ratio.
    private static func renderLabelTexture(
        text: String, accent: Bool, maxAspect: CGFloat
    ) -> (display: String, image: NSImage, aspect: CGFloat) {
        // Fixed render point-size; world scaling happens via the plane geometry.
        let pointSize: CGFloat = 72
        let font = labelFont(size: pointSize, accent: accent)

        // Uniform label styling for files and folders alike: bright text with a
        // strong dark halo, so it stays legible on gold platforms, saturated cubes,
        // and the dark floor without color-coding files vs folders differently.
        let fill = NSColor(calibratedWhite: 0.99, alpha: 1)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.92)
        shadow.shadowBlurRadius = pointSize * 0.18
        shadow.shadowOffset = .zero

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fill,
            .shadow: shadow,
        ]

        let display = truncateToAspect(text: text, attrs: attrs, maxAspect: maxAspect)
        let str = display as NSString
        let textSize = str.size(withAttributes: attrs)

        // Pad generously so the blurred halo isn't clipped.
        let padX = pointSize * 0.45
        let padY = pointSize * 0.32
        let w = max(1, ceil(textSize.width + padX * 2))
        let h = max(1, ceil(textSize.height + padY * 2))

        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        str.draw(at: NSPoint(x: padX, y: padY), withAttributes: attrs)
        image.unlockFocus()

        return (display, image, w / h)
    }

    /// Trim `text` with a trailing ellipsis until its rendered aspect ratio
    /// (width ÷ height) no longer exceeds `maxAspect`.
    private static func truncateToAspect(
        text: String, attrs: [NSAttributedString.Key: Any], maxAspect: CGFloat
    ) -> String {
        let measure: (String) -> CGFloat = { candidate in
            let s = (candidate as NSString).size(withAttributes: attrs)
            return s.height > 0 ? s.width / s.height : 0
        }
        if measure(text) <= maxAspect { return text }

        var lo = 1
        var hi = text.count
        var best = "\u{2026}"
        while lo <= hi {
            let mid = (lo + hi) / 2
            let candidate = String(text.prefix(mid)) + "\u{2026}"
            if measure(candidate) <= maxAspect {
                best = candidate
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    // MARK: - Fonts

    /// Iowan Old Style ships with macOS and has full glyph coverage at all sizes.
    /// The system `.serif` design + `.italic` symbolic-trait combo silently drops glyphs
    /// when used through SCNText (Core Text's bezier extraction path), so we don't use it here.
    private static func labelFont(size: CGFloat, accent: Bool) -> NSFont {
        let preferredName = accent ? "IowanOldStyle-Bold" : "IowanOldStyle-Roman"
        if let font = NSFont(name: preferredName, size: size) {
            return font
        }
        // Fallbacks: a couple of other broadly-shipped serifs before plain system font.
        for fallback in ["Iowan Old Style", "Charter", "Georgia"] {
            if let font = NSFont(name: fallback, size: size) {
                return font
            }
        }
        return NSFont.systemFont(ofSize: size, weight: accent ? .semibold : .regular)
    }

    // MARK: - Size + age

    /// Map a file's byte size to a slab height on a log scale, clamped to `maxH`.
    private static func slabHeight(forSize size: Int64, max maxH: CGFloat) -> CGFloat {
        let clamped = Swift.max(1, Double(size))
        let h = log10(clamped) * 0.05
        return CGFloat(Swift.min(Double(maxH), Swift.max(0.07, h)))
    }

    /// FSN-style age heatmap.
    private static func colorForAge(modified: Date?) -> NSColor {
        guard let modified else {
            return NSColor(calibratedWhite: 0.5, alpha: 1)
        }
        let days = Date().timeIntervalSince(modified) / 86_400
        switch days {
        case ..<7:    return NSColor(calibratedRed: 0.94, green: 0.32, blue: 0.30, alpha: 1) // bright red
        case ..<14:   return NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.22, alpha: 1) // orange
        case ..<30:   return NSColor(calibratedRed: 0.95, green: 0.85, blue: 0.28, alpha: 1) // yellow
        case ..<90:   return NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.35, alpha: 1) // green
        case ..<180:  return NSColor(calibratedRed: 0.28, green: 0.78, blue: 0.85, alpha: 1) // teal
        case ..<365:  return NSColor(calibratedRed: 0.36, green: 0.50, blue: 0.95, alpha: 1) // blue
        default:      return NSColor(calibratedRed: 0.60, green: 0.42, blue: 0.78, alpha: 1) // purple
        }
    }

    // MARK: - SF Symbol → tinted NSImage cache

    private static let symbolCache = NSCache<NSString, NSImage>()

    /// Render an SF Symbol to a flat tinted bitmap (cached) for use as a plane texture.
    private static func renderSFSymbol(_ name: String, tint: NSColor, pointSize: CGFloat = 96) -> NSImage? {
        let cacheKey = "\(name)|\(Int(pointSize))|\(tint.hex())" as NSString
        if let cached = symbolCache.object(forKey: cacheKey) {
            return cached
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else {
            return nil
        }
        // Render to a tinted bitmap with transparent background.
        let size = base.size
        let result = NSImage(size: size)
        result.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.clear(CGRect(origin: .zero, size: size))
        }
        tint.set()
        let rect = NSRect(origin: .zero, size: size)
        base.draw(in: rect, from: rect, operation: .sourceOver, fraction: 1)
        rect.fill(using: .sourceIn)
        result.unlockFocus()
        symbolCache.setObject(result, forKey: cacheKey)
        return result
    }
}

private extension NSColor {
    /// Lowercase `rrggbb` hex string, used as part of the SF Symbol cache key.
    func hex() -> String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "x" }
        return String(
            format: "%02x%02x%02x",
            Int(rgb.redComponent * 255),
            Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255)
        )
    }
}

import Foundation
import SceneKit
import AppKit

/// Typed identity attached to an interactive scene node (file slab, subdir
/// platform, or back tile). Replaces loose string-keyed KVC values (`fsURL`,
/// `fsName`, `fsModDate`) so a renamed key can't silently break lookups, and the
/// URL is stored directly rather than round-tripped through a path string.
final class NodePayload: NSObject {
    let url: URL
    let name: String
    let modificationDate: Date?
    init(url: URL, name: String, modificationDate: Date? = nil) {
        self.url = url
        self.name = name
        self.modificationDate = modificationDate
    }
}

extension SCNNode {
    static let fsPayloadKey = "fsPayload"
    /// Filesystem identity for interactive nodes; nil for decorative geometry.
    var fsPayload: NodePayload? {
        get { value(forKey: SCNNode.fsPayloadKey) as? NodePayload }
        set { setValue(newValue, forKey: SCNNode.fsPayloadKey) }
    }
}

/// Coloring strategy for file slabs in the 3D scene.
enum ColorMode: String, CaseIterable {
    /// FSN-style heatmap by modification recency.
    case age
    /// Categorical palette by file kind (code / image / audio / …).
    case type
}

enum SceneBuilder {

    /// Color strategy used by the next `makeLevelNode(root:)`. The Coordinator
    /// sets this just before rebuilding so the chosen mode flows into every slab.
    static var colorMode: ColorMode = .age

    // Cell sizing for the unified grid (each grid cell holds either a file or a subdir-island).
    // `cellSpacing` is the GAP between adjacent items, not "step − size", so a
    // level with a 5.0-wide subdir platform and a narrow file slab still spaces
    // them by the same readable gap. The selection ring is sized from each item's
    // own footprint (see `SceneHostView.moveSpotlight`), so the gap doesn't double
    // as a halo budget — it's purely breathing room between items.
    static let cellSize: CGFloat = 2.2
    static let cellSpacing: CGFloat = 1.0
    static let fileBaseWidth: CGFloat = 1.7
    static let subdirPlatformHeight: CGFloat = 0.20

    // Block-height budgets (kept low so tall neighbors don't occlude labels).
    static let fileMaxHeight: CGFloat = 0.18        // root-level file slabs

    // Width budget for a root-level file's name label. A file owns its slab plus
    // the gap around it, so the label may spill slightly past the slab edge into
    // that gap. The level grid always steps items by at least
    // `fileBaseWidth + cellSpacing`, so two neighboring labels at 95% of that
    // budget can never touch.
    static var fileLabelMaxWidth: CGFloat { (fileBaseWidth + cellSpacing) * 0.95 }

    struct LayoutMetrics {
        let halfExtent: CGFloat
    }

    static let floorThickness: CGFloat = 0.5

    /// Build a self-contained "level" node for one folder: a finite floor plate with
    /// the folder's items laid out on top. The node is centered at its own origin
    /// (the floor's top surface is at local y = 0); the caller positions it in the
    /// stack. Returns the node and the grid's half-extent for camera framing.
    static func makeLevelNode(
        root: FileSystemNode,
        parentURL: URL? = nil
    ) -> (node: SCNNode, halfExtent: CGFloat) {
        let level = SCNNode()
        level.name = "level"

        // Items: optional back-up tile first, then subdirs, then files.
        enum ItemKind {
            case back(URL)
            case subdir(FileSystemNode)
            case file(FileSystemNode)
        }
        var items: [ItemKind] = []
        if let parentURL {
            items.append(.back(parentURL))
        }
        items += root.subdirectories.map { .subdir($0) }
        items += root.files.map { .file($0) }

        let cols = max(1, Int(ceil(sqrt(Double(max(items.count, 1))))))
        let rows = max(1, Int(ceil(Double(max(items.count, 1)) / Double(cols))))
        // Files, folder tiles, and the back tile all share one footprint now
        // (folders no longer grow with their contents — you descend to see them),
        // so the grid step is uniform.
        let step = fileBaseWidth + cellSpacing
        let halfExtent = max(CGFloat(cols), CGFloat(rows)) * step / 2

        level.addChildNode(makeFloorPlate(halfExtent: halfExtent))

        let originX = -CGFloat(cols - 1) * step / 2
        let originZ = -CGFloat(rows - 1) * step / 2
        for (i, item) in items.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = originX + CGFloat(col) * step
            let z = originZ + CGFloat(row) * step
            let view: SCNNode
            switch item {
            case .back(let url):
                view = makeBackNode(parentURL: url)
            case .subdir(let n):
                view = makeSubdirNode(subdir: n)
            case .file(let n):
                view = makeFileNode(file: n, baseWidth: fileBaseWidth, maxHeight: fileMaxHeight)
            }
            view.position = SCNVector3(x, view.position.y, z)
            level.addChildNode(view)
        }

        // Empty-folder message, centered on the floor when there are no real
        // children. The back tile (if present) is unaffected — it sits at the
        // first grid cell and the message floats above the otherwise-empty floor.
        if root.children.isEmpty {
            let label = makeFlatLabel(
                text: root.isReadable ? "no files found" : "permission denied",
                accent: true,
                maxWorldWidth: cellSize * 3
            )
            label.position = SCNVector3(0, 0.012, 0)
            level.addChildNode(label)
        }

        return (level, halfExtent)
    }

    // MARK: - Back-up navigation tile

    /// A flat slab that, when clicked, navigates one level up the tree. Stored
    /// `fsURL` is the parent folder's path; the click handler in SceneHostView
    /// dispatches on the `navup` node name.
    private static func makeBackNode(parentURL: URL) -> SCNNode {
        let height = fileMaxHeight * 0.6
        let baseWidth = fileBaseWidth

        let geom = SCNBox(width: baseWidth, height: height, length: baseWidth, chamferRadius: 0.03)
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        // Warm amber so it stands apart from blue folders and FileKind file colors.
        mat.diffuse.contents = NSColor(calibratedRed: 0.78, green: 0.58, blue: 0.22, alpha: 1)
        mat.metalness.contents = 0.10
        mat.roughness.contents = 0.55
        geom.firstMaterial = mat

        let node = SCNNode(geometry: geom)
        node.position = SCNVector3(0, height / 2, 0)
        node.name = "navup"
        node.fsPayload = NodePayload(url: parentURL, name: parentURL.lastPathComponent)
        node.castsShadow = true

        // Up-arrow icon at the back half, label at the front (matches the
        // labeled-file layout so the slab reads as part of the level grid).
        let topY = height / 2 + 0.012
        if let icon = makeBackIconNode(width: baseWidth * 0.58) {
            icon.position = SCNVector3(0, topY, -(fileCapHeight / 2 + 0.02))
            node.addChildNode(icon)
        }
        let label = makeFlatLabel(text: "back", accent: false, maxWorldWidth: baseWidth * 0.92)
        label.position = SCNVector3(0, topY, baseWidth / 2 - fileCapHeight / 2 - 0.04)
        node.addChildNode(label)

        return node
    }

    private static func makeBackIconNode(width: CGFloat) -> SCNNode? {
        guard let image = renderSFSymbol("arrow.up.backward", tint: NSColor(calibratedWhite: 0.99, alpha: 1)) else {
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
        node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        node.name = "icon"
        node.castsShadow = false   // flat glyph planes never need to cast shadows
        return node
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
        let color = colorForFile(file)

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
        // Carry the file's identity (url + name + mod date) so the scene can
        // recolor slabs in place when the color mode is toggled (no rescan).
        node.fsPayload = NodePayload(url: file.url, name: file.name, modificationDate: file.modificationDate)
        // Only full-size (root-level) slabs cast shadows. Mini files on subdir
        // platforms don't — a dense folder has thousands of them, and rendering
        // them all into the shadow map every frame is what froze the camera fly-in.
        node.castsShadow = baseWidth >= 1.0

        // Full-size (root-level) files carry a name label on the slab's top surface,
        // mirroring how folders are labelled. The icon moves to the back half and the
        // label occupies the front strip so they don't overlap. Mini-files on subdir
        // platforms are too small for a label — they keep a centered icon only.
        let labeled = baseWidth >= 1.0
        let topY = height / 2 + 0.012

        let iconWidth = labeled ? baseWidth * 0.58 : baseWidth * 0.66
        let iconZ: CGFloat = labeled ? -(fileCapHeight / 2 + 0.02) : 0
        if let icon = makeFileIconNode(for: file, width: iconWidth) {
            icon.position = SCNVector3(0, topY, iconZ)
            node.addChildNode(icon)
        }

        if labeled {
            let label = makeFlatLabel(text: file.name, accent: false, maxWorldWidth: fileLabelMaxWidth)
            label.position = SCNVector3(0, topY, baseWidth / 2 - fileCapHeight / 2 - 0.04)
            node.addChildNode(label)
        }

        return node
    }

    // MARK: - Subdir tile

    /// Subdirectory = a flat raised tile with a folder glyph and its name. Its
    /// contents are NOT rendered inline — you descend into the folder to see them.
    /// Not drawing every nested file/folder is what keeps a deep tree cheap to
    /// build and render. The tile IS the named interactive node (click → descend).
    private static func makeSubdirNode(subdir: FileSystemNode) -> SCNNode {
        let width = fileBaseWidth
        let height = subdirPlatformHeight

        let geom = SCNBox(width: width, height: height, length: width, chamferRadius: 0.04)
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        // Folder sky-blue, matching `Theme.folder` so the in-scene plates read
        // consistently with the sidebar's folder icons / current-row rail.
        mat.diffuse.contents = NSColor(calibratedRed: 0.28, green: 0.62, blue: 0.88, alpha: 1)
        mat.metalness.contents = 0.10
        mat.roughness.contents = 0.55
        geom.firstMaterial = mat

        let node = SCNNode(geometry: geom)
        node.position = SCNVector3(0, height / 2, 0)
        node.name = "pedestal:subdir"
        node.fsPayload = NodePayload(url: subdir.url, name: subdir.name)
        node.castsShadow = true

        // Folder glyph in the back half, name label in the front strip — mirrors
        // the labeled-file layout so a folder reads as part of the same grid.
        let topY = height / 2 + 0.012
        if let icon = makeFolderGlyphNode(width: width * 0.5) {
            icon.position = SCNVector3(0, topY, -(accentCapHeight / 2 + 0.02))
            node.addChildNode(icon)
        }

        let label = makeFlatLabel(text: subdir.name, accent: true, maxWorldWidth: width * 0.92)
        label.position = SCNVector3(0, topY, width / 2 - accentCapHeight / 2 - 0.06)
        node.addChildNode(label)

        return node
    }

    /// A flat `folder.fill` glyph plane laid on top of a subdir tile.
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
        node.castsShadow = false   // flat glyph planes never need to cast shadows
        return node
    }

    // MARK: - File-type icon plane

    /// A flat, tinted SF Symbol plane (per file type) laid on top of a file slab.
    private static func makeFileIconNode(for file: FileSystemNode, width: CGFloat) -> SCNNode? {
        let symbol = FileKind.classify(name: file.name, isDirectory: file.isDirectory).iconName
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
        node.castsShadow = false   // flat glyph planes never need to cast shadows
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

        let image = renderBitmapImage(width: w, height: h) {
            str.draw(at: NSPoint(x: padX, y: padY), withAttributes: attrs)
        } ?? NSImage(size: NSSize(width: w, height: h))

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

    /// Dispatch to the active color strategy for this slab.
    private static func colorForFile(_ file: FileSystemNode) -> NSColor {
        switch colorMode {
        case .age:
            return colorForAge(modified: file.modificationDate)
        case .type:
            return FileKind.classify(name: file.name, isDirectory: file.isDirectory).sceneColor
        }
    }

    /// Walk every "file" slab under `root` and reapply its diffuse color using the
    /// currently-set `colorMode`. Folder platforms (gold) are not affected.
    static func recolorFileSlabs(under root: SCNNode) {
        root.enumerateChildNodes { node, _ in
            guard node.name == "file",
                  let mat = node.geometry?.firstMaterial,
                  let payload = node.fsPayload else { return }
            let color: NSColor
            switch colorMode {
            case .age:
                color = colorForAge(modified: payload.modificationDate)
            case .type:
                color = FileKind.classify(name: payload.name, isDirectory: false).sceneColor
            }
            mat.diffuse.contents = color
        }
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
        let rect = NSRect(origin: .zero, size: size)
        guard let result = renderBitmapImage(width: size.width, height: size.height, {
            NSGraphicsContext.current?.cgContext.clear(rect)
            tint.set()
            base.draw(in: rect, from: rect, operation: .sourceOver, fraction: 1)
            rect.fill(using: .sourceIn)
        }) else {
            return nil
        }
        symbolCache.setObject(result, forKey: cacheKey)
        return result
    }

    /// Render `draw` into an offscreen RGBA bitmap of the given point size, with a
    /// 2× backing scale for crisp textures, installing the bitmap's context as the
    /// thread-local current `NSGraphicsContext`.
    ///
    /// Unlike `NSImage.lockFocus()` (which is unsafe off the main thread), this uses
    /// an `NSBitmapImageRep`-backed `NSGraphicsContext` — both `NSGraphicsContext.current`
    /// and `save/restoreGraphicsState` are thread-local — so whole levels can be
    /// built on a background queue without touching main-thread-only AppKit drawing.
    private static func renderBitmapImage(
        width: CGFloat, height: CGFloat, scale: CGFloat = 2, _ draw: () -> Void
    ) -> NSImage? {
        let pxW = Int(max(1, (width * scale).rounded()))
        let pxH = Int(max(1, (height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)   // logical (point) size → 2× pixels
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        draw()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
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

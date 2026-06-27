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

    // Cell sizing for the unified grid (each grid cell holds either a file or a subdir-island).
    // `cellSpacing` is the GAP between adjacent items, not "step − size", so a
    // level with a 5.0-wide subdir platform and a narrow file slab still spaces
    // them by the same readable gap. The selection ring is sized from each item's
    // own footprint (see `SceneHostView.moveSpotlight`), so the gap doesn't double
    // as a halo budget — it's purely breathing room between items.
    static let cellSize: CGFloat = 1.0
    static let cellSpacing: CGFloat = 0.4
    static let fileBaseWidth: CGFloat = 1.0
    static let subdirPlatformHeight: CGFloat = 0.32

    // Block heights. Names are engraved on each item's camera-facing front
    // edge (see `makeEdgeLabel`), so blocks are tall enough to give that rim room to
    // read.
    static let fileMaxHeight: CGFloat = 0.55        // root-level file slabs

    /// Map a file's byte size to a slab height on a log scale, clamped to `maxH`.
    /// The floor (0.24) keeps even tiny files tall enough for a legible engraved rim;
    /// the slope spreads the common KB–GB range across the height budget.
    static func slabHeight(forSize size: Int64, max maxH: CGFloat) -> CGFloat {
        let clamped = Swift.max(1, Double(size))
        let h = log10(clamped) * 0.08
        return CGFloat(Swift.min(Double(maxH), Swift.max(0.24, h)))
    }

    struct LayoutMetrics {
        let halfExtent: CGFloat
    }

    static let floorThickness: CGFloat = 0.15

    /// Build a self-contained "level" node for one folder: a finite floor plate with
    /// the folder's items laid out on top. The node is centered at its own origin
    /// (the floor's top surface is at local y = 0); the caller positions it in the
    /// stack. Returns the node and the grid's half-extent for camera framing.
    ///
    /// `colorMode` is an explicit parameter (not shared state) because this runs
    /// on a background task — the caller captures the mode at dispatch time, so a
    /// toggle mid-build can't produce a mixed-palette level.
    static func makeLevelNode(
        root: FileSystemNode,
        parentURL: URL? = nil,
        colorMode: ColorMode
    ) -> (node: SCNNode, halfExtent: CGFloat, hasBack: Bool) {
        let level = SCNNode()
        level.name = "level"

        // Grid items: subdirs then files. The up/back tile is NOT in the grid — it's
        // placed separately at the front-center of the plate (see below) so it's a
        // clear, dedicated control instead of a cell lost among the contents.
        enum ItemKind {
            case subdir(FileSystemNode)
            case file(FileSystemNode)
        }
        var items: [ItemKind] = []
        items += root.subdirectories.map { .subdir($0) }
        items += root.files.map { .file($0) }

        let cols = max(1, Int(ceil(sqrt(Double(max(items.count, 1))))))
        let rows = max(1, Int(ceil(Double(max(items.count, 1)) / Double(cols))))
        // All items have fixed width `fileBaseWidth`.
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
            case .subdir(let n):
                view = makeSubdirNode(subdir: n)
            case .file(let n):
                view = makeFileNode(file: n, baseWidth: fileBaseWidth, maxHeight: fileMaxHeight, colorMode: colorMode)
            }
            view.position = SCNVector3(x, view.position.y, z)
            level.addChildNode(view)
        }

        // Back control nestled into the plate's NW corner when there's a parent to
        // navigate to. Its own NW corner is rounded to the plate's corner radius, so
        // it follows the chamfer and seats flush into the corner instead of
        // overhanging it. The framing includes this corner.
        if let parentURL {
            let plateHalf = halfExtent + cellSize
            let cornerRadius = min(plateHalf * 2 * 0.06, 2.0)   // matches makeFloorPlate
            let back = makeBackNode(parentURL: parentURL, plateHalf: plateHalf, cornerRadius: cornerRadius)
            level.addChildNode(back)
        }

        // Empty-folder message, centered on the floor when there are no real children.
        if root.children.isEmpty {
            let label = makeFlatLabel(
                text: root.isReadable ? "no files found" : "permission denied",
                accent: true,
                maxWorldWidth: cellSize * 3
            )
            label.position = SCNVector3(0, 0.012, 0)
            level.addChildNode(label)
        }

        return (level, halfExtent, parentURL != nil)
    }

    // MARK: - Back-up control

    /// The "up" control: a glowing amber back pad with a centered back-arrow glyph,
    /// seated in the plate's NW corner. Its own NW corner is rounded to the plate's
    /// corner radius so it nestles into the chamfer flush against the west/north
    /// edges instead of overhanging. Clicking navigates one level up (the handler
    /// dispatches on the `navup` node name). `plateHalf` is the plate's half-side and
    /// `cornerRadius` its plan-view corner radius (both from `makeLevelNode`).
    private static func makeBackNode(parentURL: URL, plateHalf: CGFloat, cornerRadius: CGFloat) -> SCNNode {
        // Big enough that its rounded NW corner can adopt the plate's corner radius.
        let size = max(fileBaseWidth, cornerRadius + fileBaseWidth * 0.6)
        let height: CGFloat = floorThickness   // flush with the floor

        // Square footprint whose top-left (→ world NW) corner matches the plate's
        // corner radius; the other corners get just a soft round.
        let path = cornerRoundedRectPath(
            width: size, height: size,
            blRadius: 0.05, brRadius: 0.05, trRadius: 0.05, tlRadius: cornerRadius
        )
        let geom = SCNShape(path: path, extrusionDepth: height)
        geom.chamferRadius = 0.04
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        // Warm amber, distinct from blue folders and the file colors.
        mat.diffuse.contents = NSColor(calibratedRed: 0.78, green: 0.58, blue: 0.22, alpha: 1)
        mat.metalness.contents = 0.10
        mat.roughness.contents = 0.55
        // Emissive so the pad self-illuminates as a glowing control.
        mat.emission.contents = NSColor(calibratedRed: 0.70, green: 0.46, blue: 0.12, alpha: 1)
        geom.firstMaterial = mat

        let node = SCNNode(geometry: geom)
        // SCNShape lies in the XY plane extruding +Z. Its extrusion is centered.
        // Rotate -90° about X so it lies flat (footprint in XZ, height in Y).
        node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        // Seat it in the NW corner. Because extrusion is centered, positioning its center
        // at -height / 2 + 0.001 places its top surface exactly flush at Y = 0.001
        // (just a tiny bit above the floor plate to prevent Z-fighting).
        let center = -plateHalf + size / 2
        node.position = SCNVector3(center, -height / 2 + 0.001, center)
        node.name = "navup"
        node.fsPayload = NodePayload(url: parentURL, name: parentURL.lastPathComponent)
        node.castsShadow = true

        // Centered back-arrow on the top face. The pad is already rotated to lie flat,
        // so the glyph needs no rotation of its own; +Z in the pad's local frame is
        // world-up. The pad's top face is at local Z = height / 2.
        if let icon = makeBackIconNode(width: size * 0.42) {
            icon.eulerAngles = SCNVector3Zero
            icon.position = SCNVector3(0, 0, height / 2 + 0.006)
            node.addChildNode(icon)
        }

        return node
    }

    /// A closed rounded-rectangle path with an independent radius per corner, named
    /// by position in the path's local XY plane (bottom-left, bottom-right, etc.).
    /// Used to give the back pad one plate-matched corner and soft rounds elsewhere.
    private static func cornerRoundedRectPath(
        width: CGFloat, height: CGFloat,
        blRadius: CGFloat, brRadius: CGFloat, trRadius: CGFloat, tlRadius: CGFloat
    ) -> NSBezierPath {
        let minX = -width / 2, maxX = width / 2
        let minY = -height / 2, maxY = height / 2
        let p = NSBezierPath()
        p.move(to: NSPoint(x: minX, y: minY + blRadius))
        p.appendArc(withCenter: NSPoint(x: minX + blRadius, y: minY + blRadius),
                    radius: blRadius, startAngle: 180, endAngle: 270)
        p.line(to: NSPoint(x: maxX - brRadius, y: minY))
        p.appendArc(withCenter: NSPoint(x: maxX - brRadius, y: minY + brRadius),
                    radius: brRadius, startAngle: 270, endAngle: 360)
        p.line(to: NSPoint(x: maxX, y: maxY - trRadius))
        p.appendArc(withCenter: NSPoint(x: maxX - trRadius, y: maxY - trRadius),
                    radius: trRadius, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: minX + tlRadius, y: maxY))
        p.appendArc(withCenter: NSPoint(x: minX + tlRadius, y: maxY - tlRadius),
                    radius: tlRadius, startAngle: 90, endAngle: 180)
        p.close()
        return p
    }

    private static func makeBackIconNode(width: CGFloat) -> SCNNode? {
        // Dark back-arrow glyph for high contrast on the glowing amber tile.
        guard let image = renderSFSymbol("arrow.backward", tint: NSColor(calibratedWhite: 0.10, alpha: 1)) else {
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
        node.castsShadow = false
        return node
    }

    // MARK: - Floor

    /// Finite floor plate, sized to the grid, with its top surface at local y = 0.
    /// Built as an extruded rounded rectangle so the plate reads as a round-rect
    /// (a chamfered `SCNBox` can only round corners up to half its thickness).
    private static func makeFloorPlate(halfExtent: CGFloat) -> SCNNode {
        let side = (halfExtent + cellSize) * 2
        let cornerRadius = min(side * 0.06, 2.0)

        let rect = NSRect(x: -side / 2, y: -side / 2, width: side, height: side)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.flatness = 0.1   // smooth corner tessellation
        let shape = SCNShape(path: path, extrusionDepth: floorThickness)
        shape.chamferRadius = 0.04   // softens the top/bottom rim

        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = NSColor(calibratedWhite: 0.10, alpha: 1)
        mat.roughness.contents = 0.92
        mat.metalness.contents = 0.0
        shape.firstMaterial = mat

        let node = SCNNode(geometry: shape)
        // SCNShape lies in the XY plane extruding +Z; rotate -90° about X so it lies
        // flat (footprint in XZ, thickness in Y). Extrusion is centered around the local
        // origin, so the top face is at local Z = floorThickness / 2.
        // Drop it by floorThickness / 2 so the top surface sits exactly at world y = 0.
        node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        node.position = SCNVector3(0, -floorThickness / 2, 0)
        node.name = "floor"
        node.castsShadow = true
        return node
    }

    /// File-type geometry. Every kind is a flat-topped, low, grid-aligned solid
    /// (box, disc, or holed disc) so the design reads as one coherent system: the
    /// flat icon + name label always sit cleanly on top, and height stays a faithful
    /// log-encoding of file size across every shape. Type is conveyed by the
    /// *silhouette* (portrait page, wide frame, round disc, …) plus the icon and the
    /// type-palette color — not by swapping in mismatched 3D primitives.
    ///
    /// All shapes are vertically centered at `height / 2`, so the caller can treat
    /// `height / 2` as both the node's Y position and its local top.
    private static func fileGeometry(for kind: FileKind, baseWidth: CGFloat, height: CGFloat) -> SCNGeometry {
        // A box's chamfer rounds every edge, so it's capped at half the smallest
        // dimension — on a thin slab that's the height. Clamp to stay just under.
        let maxChamfer = max(0.001, height / 2 - 0.001)
        let card: (CGFloat, CGFloat, CGFloat) -> SCNBox = { w, l, c in
            SCNBox(width: w, height: height, length: l, chamferRadius: min(c, maxChamfer))
        }

        switch kind {
        case .code, .executable:
            // Crisp square card — sharp corners read as "source / program".
            return card(baseWidth, baseWidth, 0.015)

        case .document:
            // Portrait card (deeper than wide) — a sheet of paper standing in the grid.
            return card(baseWidth * 0.72, baseWidth, 0.02)

        case .video:
            // Wide landscape card — a film frame / clapperboard.
            return card(baseWidth, baseWidth * 0.6, 0.02)

        case .image:
            // Square card with softly-rounded corners — a framed photo.
            return card(baseWidth * 0.95, baseWidth * 0.95, min(0.05, maxChamfer))

        case .archive:
            // Chunky, heavily-rounded square — a crate or sealed box.
            return card(baseWidth * 0.92, baseWidth * 0.92, min(0.06, maxChamfer))

        case .config:
            // Compact square chip — settings stamped onto a small plate.
            return card(baseWidth * 0.8, baseWidth * 0.8, 0.02)

        case .web:
            // Rounded square — a soft, globe-adjacent tile.
            return card(baseWidth * 0.9, baseWidth * 0.9, min(0.05, maxChamfer))

        case .hidden:
            // Small, recessed square — a system file that keeps to itself.
            return card(baseWidth * 0.68, baseWidth * 0.68, 0.02)

        case .audio:
            // Solid disc — a record / spun-up media file.
            return SCNCylinder(radius: baseWidth * 0.46, height: height)

        case .disk:
            // Disc with a center hole — an optical / disk image.
            return SCNTube(innerRadius: baseWidth * 0.14, outerRadius: baseWidth * 0.46, height: height)

        case .folder:
            // Folders are built by `makeSubdirNode`; included for exhaustiveness.
            return card(baseWidth, baseWidth, 0.04)

        case .other:
            // Plain rounded card — the neutral default.
            return card(baseWidth, baseWidth, 0.025)
        }
    }

    // MARK: - File slab

    /// One file = a flat-topped, low solid whose silhouette hints at its type (see
    /// `fileGeometry`). The solid IS the named interactive node so hover/click
    /// highlight works directly on its material; a flat icon plane and name label
    /// sit on top.
    private static func makeFileNode(file: FileSystemNode, baseWidth: CGFloat, maxHeight: CGFloat, colorMode: ColorMode) -> SCNNode {
        let height = slabHeight(forSize: file.size, max: maxHeight)
        let color = colorForFile(file, mode: colorMode)
        let kind = FileKind.classify(name: file.name, isDirectory: false)

        let geom = fileGeometry(for: kind, baseWidth: baseWidth, height: height)
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

        // Full-size (root-level) files carry their name engraved on the camera-facing
        // front edge, so the icon gets the whole top surface to itself (centered).
        // Mini-files on subdir platforms are too small for a legible label — they keep
        // a centered icon only.
        let labeled = baseWidth >= 1.0
        let topY = height / 2 + 0.012

        let iconWidth = labeled ? baseWidth * 0.6 : baseWidth * 0.66
        if let icon = makeFileIconNode(for: file, width: iconWidth) {
            icon.position = SCNVector3(0, topY, 0)
            node.addChildNode(icon)
        }

        if labeled {
            // Front (+Z) face of the actual geometry — picks up shape-specific widths
            // (portrait pages, wide video frames, round discs) automatically.
            let (gmin, gmax) = geom.boundingBox
            let label = makeEdgeLabel(
                text: file.name,
                faceWidth: CGFloat(gmax.x - gmin.x),
                faceHeight: height,
                accent: false
            )
            label.position = SCNVector3(0, 0, CGFloat(gmax.z) + 0.003)
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

        let maxChamfer = max(0.001, height / 2 - 0.001)
        let geom = SCNBox(width: width, height: height, length: width, chamferRadius: min(0.04, maxChamfer))
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

        // Centered folder glyph on top, name engraved on the camera-facing front
        // edge — mirrors the labeled-file layout so a folder reads as part of the
        // same grid.
        let topY = height / 2 + 0.012
        if let icon = makeFolderGlyphNode(width: width * 0.5) {
            icon.position = SCNVector3(0, topY, 0)
            node.addChildNode(icon)
        }

        let label = makeEdgeLabel(text: subdir.name, faceWidth: width, faceHeight: height, accent: true)
        label.position = SCNVector3(0, 0, width / 2 + 0.003)
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
    private static func makeFlatLabel(text: String, accent: Bool, maxWorldWidth: CGFloat, dark: Bool = false) -> SCNNode {
        let capHeight = accent ? accentCapHeight : fileCapHeight
        return makeFlatLabelCore(
            text: text, bold: accent, capHeight: capHeight,
            maxWorldWidth: maxWorldWidth, name: "label", dark: dark
        )
    }

    // Edge-label text height per line, in WORLD units. Constant across every block
    // so labels read at a uniform size regardless of a file's size-encoded height —
    // a big file and a small one get the same lettering, just on taller/shorter
    // blocks. Small enough that two lines fit the shortest block's rim.
    private static let edgeLineHeight: CGFloat = 0.1
    private static let edgeMaxLines = 2

    /// A name label standing on an item's camera-facing front edge (its +Z face),
    /// reading like lettering etched into the rim. Unlike `makeFlatLabel` (which lies
    /// flat on the floor in front of the item), this plane faces the default camera
    /// directly, so the name travels with the slab's front edge instead of spilling
    /// onto the floor.
    ///
    /// The name is set small and wrapped across up to `edgeMaxLines` lines, so a long
    /// filename shows in full (or nearly so) instead of being clipped to a handful of
    /// big characters. It's ellipsized only if it still overflows.
    private static func makeEdgeLabel(text: String, faceWidth: CGFloat, faceHeight: CGFloat, accent: Bool) -> SCNNode {
        // Constant world height per line, but never so tall that two lines overflow a
        // short block's rim (a safety clamp; normal blocks are tall enough that it
        // never engages, keeping the size uniform).
        let worldLineHeight = min(edgeLineHeight, faceHeight * 0.42)
        let maxLineWorldWidth = faceWidth * 0.94

        let pointSize: CGFloat = 64
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.92)
        shadow.shadowBlurRadius = pointSize * 0.16
        shadow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [
            .font: labelFont(size: pointSize, accent: accent),
            .foregroundColor: NSColor(calibratedWhite: 0.99, alpha: 1),
            .shadow: shadow,
            .paragraphStyle: para,
        ]

        // Convert the world width budget into a pixel budget at the render point size,
        // then wrap the name across up to `edgeMaxLines` lines.
        let lineHeightPx = ("Ag" as NSString).size(withAttributes: attrs).height
        let maxLineWidthPx = (maxLineWorldWidth / worldLineHeight) * lineHeightPx
        let lines = wrapToLines(text, attrs: attrs, maxLineWidthPx: maxLineWidthPx, maxLines: edgeMaxLines)

        let attrString = NSAttributedString(string: lines.joined(separator: "\n"), attributes: attrs)
        let textSize = attrString.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size

        let padX = pointSize * 0.35
        let padY = pointSize * 0.22
        let wPx = max(1, ceil(textSize.width + padX * 2))
        let hPx = max(1, ceil(textSize.height + padY * 2))
        let image = renderBitmapImage(width: wPx, height: hPx) {
            attrString.draw(
                with: NSRect(x: padX, y: padY, width: textSize.width, height: textSize.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        } ?? NSImage(size: NSSize(width: wPx, height: hPx))

        // Scale so each rendered text line maps to `worldLineHeight`; the halo padding
        // rides along so it isn't clipped.
        let scale = (CGFloat(lines.count) * worldLineHeight) / max(textSize.height, 1)
        let plane = SCNPlane(width: wPx * scale, height: hPx * scale)
        let mat = SCNMaterial()
        mat.diffuse.contents = image
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.transparencyMode = .aOne
        // Sit flush on the face: skip depth writes and read depth so nearer slabs
        // still occlude it, but it never z-fights with the face it rides on.
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = true
        plane.firstMaterial = mat

        let node = SCNNode(geometry: plane)
        // SCNPlane already faces +Z (toward the default camera) — no rotation needed.
        node.name = "label"
        node.castsShadow = false
        node.renderingOrder = 10
        return node
    }

    /// Break `text` into at most `maxLines` lines that each fit `maxLineWidthPx`,
    /// preferring to split at separators (space, dash, underscore, dot, parens) and
    /// falling back to a mid-token break for runs with none. The final line is
    /// ellipsized if the whole string still doesn't fit.
    private static func wrapToLines(
        _ text: String, attrs: [NSAttributedString.Key: Any], maxLineWidthPx: CGFloat, maxLines: Int
    ) -> [String] {
        func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: attrs).width }
        if w(text) <= maxLineWidthPx { return [text] }

        let separators: Set<Character> = [" ", "-", "_", ".", "(", ")"]
        var lines: [String] = []
        var rest = Substring(text)

        while !rest.isEmpty && lines.count < maxLines {
            // Largest character prefix that fits the line width.
            var lo = 1, hi = rest.count, fit = 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if w(String(rest.prefix(mid))) <= maxLineWidthPx { fit = mid; lo = mid + 1 }
                else { hi = mid - 1 }
            }

            if fit >= rest.count {
                lines.append(String(rest)); rest = ""
                break
            }
            if lines.count == maxLines - 1 {
                // Last allowed line and more text remains — ellipsize it.
                var n = fit
                while n > 1 && w(String(rest.prefix(n)) + "\u{2026}") > maxLineWidthPx { n -= 1 }
                lines.append(String(rest.prefix(n)) + "\u{2026}")
                rest = ""
                break
            }

            // Prefer a separator break within the fitting prefix, but not so early
            // that most of the line is wasted.
            let chars = Array(rest)
            var brk = fit
            var i = fit - 1
            while i >= max(1, fit / 2) {
                if separators.contains(chars[i]) { brk = i + 1; break }
                i -= 1
            }
            lines.append(String(rest.prefix(brk)))
            rest = rest.dropFirst(brk)
        }
        return lines
    }

    /// Shared label builder: renders `text` to a texture and lays it flat (facing up,
    /// reading toward the camera), truncated so its world width fits `maxWorldWidth`.
    /// `dark` renders near-black text with a light halo — for legibility on the bright
    /// amber back tile.
    private static func makeFlatLabelCore(
        text: String, bold: Bool, capHeight: CGFloat, maxWorldWidth: CGFloat, name: String, dark: Bool = false
    ) -> SCNNode {
        let maxAspect = maxWorldWidth / capHeight
        let (_, image, aspect) = renderLabelTexture(text: text, accent: bold, maxAspect: maxAspect, dark: dark)

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
        node.renderingOrder = 10   // above floor/plates so labels never z-fight
        return node
    }

    /// Render `text` (truncated to fit `maxAspect`) onto a transparent NSImage with
    /// a soft dark halo for legibility against both gold platforms and the dark floor.
    /// Returns the displayed string, the image, and its width/height aspect ratio.
    private static func renderLabelTexture(
        text: String, accent: Bool, maxAspect: CGFloat, dark: Bool = false
    ) -> (display: String, image: NSImage, aspect: CGFloat) {
        // Fixed render point-size; world scaling happens via the plane geometry.
        let pointSize: CGFloat = 72
        let font = labelFont(size: pointSize, accent: accent)

        // Default: bright text with a strong dark halo, legible on the dark floor and
        // saturated slabs. `dark` flips to near-black text with a light halo, for
        // legibility on the bright amber back tile.
        let fill = dark ? NSColor(calibratedWhite: 0.08, alpha: 1) : NSColor(calibratedWhite: 0.99, alpha: 1)
        let shadow = NSShadow()
        shadow.shadowColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.75 : 0.92)
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
    static func truncateToAspect(
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

    /// Dispatch to the requested color strategy for this slab.
    private static func colorForFile(_ file: FileSystemNode, mode: ColorMode) -> NSColor {
        switch mode {
        case .age:
            return colorForAge(modified: file.modificationDate)
        case .type:
            return FileKind.classify(name: file.name, isDirectory: file.isDirectory).sceneColor
        }
    }

    /// Walk every "file" slab under `root` and reapply its diffuse color using
    /// `colorMode`. Folder platforms (gold) are not affected.
    static func recolorFileSlabs(under root: SCNNode, colorMode: ColorMode) {
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

    /// FSN-style age heatmap. "Now" is sampled at build time, so colors can drift
    /// a band if the app stays open across a boundary — acceptable: the coarsest
    /// band is a week, and any navigation or reload rebuilds with fresh colors.
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

    /// `nonisolated(unsafe)`: NSCache is documented thread-safe, and levels are
    /// built from concurrent background tasks that all share this cache.
    nonisolated(unsafe) private static let symbolCache = NSCache<NSString, NSImage>()

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
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}

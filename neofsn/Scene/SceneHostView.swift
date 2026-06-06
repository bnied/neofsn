import SwiftUI
import SceneKit
import AppKit
import Quartz

/// SwiftUI wrapper that hosts the SceneKit `SCNView` and bridges view-model state
/// (current root, focus/reset requests, selection) into the 3D scene via its Coordinator.
struct SceneHostView: NSViewRepresentable {

    @ObservedObject var viewModel: BrowserViewModel

    /// Create the Coordinator that owns the scene, camera, and level stack.
    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    /// Build and configure the backing `SCNView` (camera bound, lighting manual,
    /// continuous rendering, event monitors installed).
    func makeNSView(context: Context) -> SCNView {
        let view = InteractiveSCNView(frame: .zero)
        view.scene = context.coordinator.scene
        // CRITICAL: bind our camera explicitly. Otherwise SCNView picks a default
        // viewpoint heuristically and the projection drifts on relayout.
        view.pointOfView = context.coordinator.flyCamera.cameraNode
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.038, blue: 0.052, alpha: 1)
        view.rendersContinuously = true
        view.autoresizingMask = [.width, .height]
        view.coordinator = context.coordinator
        context.coordinator.scnView = view
        context.coordinator.installEventMonitors()
        context.coordinator.flyCamera.start()
        return view
    }

    /// Reconcile the scene with the latest view-model state on every SwiftUI update:
    /// rebuild/relayer on root change, then service focus, reset, and selection.
    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.syncFromViewModel()
        context.coordinator.handleFocusRequest()
        context.coordinator.handleResetRequest()
        context.coordinator.handleSelectionChange()
        context.coordinator.handleQuickLookRequest()
    }

    /// Tear down event monitors and the camera loop when the view is removed.
    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.uninstallEventMonitors()
        coordinator.flyCamera.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        let scene: SCNScene
        let viewModel: BrowserViewModel
        weak var scnView: SCNView?
        let flyCamera: FlyCameraController

        private var lastRootID: UUID?
        private var lastFocusToken: Int = 0
        private var lastResetToken: Int = 0
        private var lastColorRebuildToken: Int = 0
        private var lastHalfExtent: CGFloat = 8
        private var focusedSubdir: SCNNode?
        private var focusLabelNodes: [SCNNode] = []
        private var levels: [Level] = []
        private var lastSelectedPath: String?
        private var lastQuickLookToken = 0
        /// path → interactive node, rebuilt whenever the level stack changes.
        private var nodeIndex: [String: SCNNode] = [:]
        private var spotlightNode: SCNNode?
        private var coronaNode: SCNNode?
        private var coneNode: SCNNode?
        private var selectionRingNode: SCNNode?
        private var selectionRingInner: SCNNode?
        private let coronaBaseSize: CGFloat = 4.0
        // Cone roughly 1.5× cell-pitch tall — clearly a beam from above, but not
        // so tall it visually projects across rows behind from a tilted camera.
        private let liftHeight: CGFloat = 3.6
        private let coneBaseHeight: CGFloat = 3.6
        private let coneBaseTopRadius: CGFloat = 0.05
        private let coneBaseBottomRadius: CGFloat = 1.0
        private var hoveredNode: SCNNode?
        private var hoverSavedEmission: Any?
        private var keyMonitor: Any?
        private var resignObserver: NSObjectProtocol?

        /// Build the scene, camera (HDR/bloom off to avoid blow-out), and fly controller.
        init(viewModel: BrowserViewModel) {
            let scene = SCNScene()
            self.scene = scene
            self.viewModel = viewModel

            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.fieldOfView = 55
            cameraNode.camera?.zNear = 0.05
            cameraNode.camera?.zFar = 400
            cameraNode.camera?.wantsHDR = false      // disable HDR — it was blowing out close-up
            cameraNode.camera?.bloomIntensity = 0    // disable bloom for the same reason
            cameraNode.camera?.bloomThreshold = 1
            cameraNode.camera?.wantsExposureAdaptation = false
            cameraNode.position = SCNVector3(0, 11, 19)
            cameraNode.name = "camera"
            scene.rootNode.addChildNode(cameraNode)

            self.flyCamera = FlyCameraController(cameraNode: cameraNode)
            super.init()
            configureLights()
            configureSelectionSpotlight()
            configureSelectionCorona()
            configureSelectionCone()
            configureSelectionRing()
        }

        /// Install the three-point-ish lighting rig (warm key + cool fill + ambient).
        private func configureLights() {
            // Key directional — softer than before so close-ups don't clip
            let keyNode = SCNNode()
            let key = SCNLight()
            key.type = .directional
            key.color = NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.88, alpha: 1)
            key.intensity = 720
            key.castsShadow = true
            key.shadowMode = .deferred
            key.shadowSampleCount = 16
            key.shadowRadius = 4
            key.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.55)
            keyNode.light = key
            keyNode.eulerAngles = SCNVector3(-Double.pi / 3, Double.pi / 6, 0)
            scene.rootNode.addChildNode(keyNode)

            // Cool fill
            let fillNode = SCNNode()
            let fill = SCNLight()
            fill.type = .directional
            fill.color = NSColor(calibratedRed: 0.55, green: 0.70, blue: 1.0, alpha: 1)
            fill.intensity = 220
            fillNode.light = fill
            fillNode.eulerAngles = SCNVector3(-Double.pi / 4, -Double.pi / 1.6, 0)
            scene.rootNode.addChildNode(fillNode)

            // Ambient — keeps shadows from going black
            let ambientNode = SCNNode()
            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.color = NSColor(calibratedWhite: 0.20, alpha: 1)
            ambient.intensity = 180
            ambientNode.light = ambient
            scene.rootNode.addChildNode(ambientNode)

            scene.background.contents = NSColor(calibratedRed: 0.035, green: 0.038, blue: 0.052, alpha: 1)
        }

        // MARK: - Level stack (descending into folders adds a layer below)

        struct Level {
            let url: URL
            let node: SCNNode
            let center: SCNVector3   // world position of the level node (floor-top y)
            let halfExtent: CGFloat
        }
        private let levelDrop: CGFloat = 3.5   // modest vertical step, parent stays in frame

        func syncFromViewModel() {
            guard let root = viewModel.currentRoot else { return }
            SceneBuilder.colorMode = viewModel.colorMode

            let colorChanged = viewModel.colorRebuildToken != lastColorRebuildToken
            let rootChanged = lastRootID != root.id
            guard rootChanged || colorChanged else { return }
            lastRootID = root.id
            lastColorRebuildToken = viewModel.colorRebuildToken
            clearHover()
            clearFocusLabels()
            hideSpotlight()
            focusedSubdir = nil

            // A color-mode swap with no navigation: walk every file slab in the
            // scene and reapply diffuse colors. Cheap, geometry stays put, the
            // camera frame is preserved.
            if colorChanged && !rootChanged {
                SceneBuilder.recolorFileSlabs(under: scene.rootNode)
                return
            }

            let path = root.url.path
            if let idx = levels.firstIndex(where: { $0.url.path == path }) {
                // Navigated to a folder already in the stack (e.g. Back, or a breadcrumb)
                // → pop everything deeper and re-frame it.
                popLevels(below: idx)
                flyToLevel(levels[idx])
            } else if let idx = levels.lastIndex(where: { isDescendant(path, of: $0.url.path) }) {
                // Descending from some existing level (not necessarily the deepest one —
                // the clicked folder may live on a higher, still-visible plate). Pop any
                // levels deeper than that ancestor, then add the new layer below it.
                popLevels(below: idx)
                pushLevel(root: root)
            } else {
                // Unrelated root (freshly opened) → reset the stack.
                levels.forEach { $0.node.removeFromParentNode() }
                levels.removeAll()
                pushLevel(root: root)
            }

            rebuildNodeIndex()
        }

        private func pushLevel(root: FileSystemNode) {
            let parentURL = navigableParentURL(for: root.url)
            let (node, halfExtent) = SceneBuilder.makeLevelNode(root: root, parentURL: parentURL)
            let center: SCNVector3
            if let top = levels.last {
                // Place the child BESIDE and just below the parent: offset in +X by both
                // half-extents (plus a cell) so the plates don't overlap, and drop only a
                // little. The camera then makes a modest pan to the child and the parent
                // stays visible at the edge as context — not a full-screen redraw, and no
                // occlusion since the parent sits entirely to the left of the child.
                let xOffset = top.halfExtent + halfExtent + SceneBuilder.cellSize
                center = SCNVector3(top.center.x + xOffset, top.center.y - levelDrop, 0)
            } else {
                center = SCNVector3(0, 0, 0)
            }
            node.position = center
            scene.rootNode.addChildNode(node)
            let level = Level(url: root.url, node: node, center: center, halfExtent: halfExtent)
            levels.append(level)
            lastHalfExtent = halfExtent
            flyToLevel(level)
        }

        private func flyToLevel(_ level: Level) {
            flyToFrame(center: level.center, halfExtent: level.halfExtent)
        }

        /// Single framing routine for everything (overviews, levels, subfolder focus).
        /// Always uses the same 32° pitch via `overviewDistanceHeight`, so the camera
        /// angle never changes between navigations — only its position. Pass `tight`
        /// for FSN-style close-in framing of a single selected item: the item should
        /// fill the frame, not float in the middle of a level-sized overview.
        private func flyToFrame(
            center: SCNVector3,
            halfExtent: CGFloat,
            duration: TimeInterval = 0.6,
            tight: Bool = false
        ) {
            let (distance, height) = overviewDistanceHeight(halfExtent: halfExtent, tight: tight)
            flyCamera.flyToOverview(
                of: center,
                distance: distance,
                height: Double(center.y) + height,
                duration: duration
            )
        }

        private func isDescendant(_ path: String, of ancestor: String) -> Bool {
            let a = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
            return path != ancestor && path.hasPrefix(a)
        }

        private func popLevels(below idx: Int) {
            guard idx + 1 < levels.count else { return }
            for lvl in levels[(idx + 1)...] { lvl.node.removeFromParentNode() }
            levels.removeSubrange((idx + 1)...)
        }

        // MARK: - Reset / focus a subfolder (in-place, parent context preserved)

        func handleResetRequest() {
            guard viewModel.resetViewToken != lastResetToken else { return }
            lastResetToken = viewModel.resetViewToken
            resetView()
        }

        /// Toggle Quick Look when the view-model bumps its token. Routed through the
        /// SCNView so AppKit's responder-chain control protocol drives the panel.
        func handleQuickLookRequest() {
            guard viewModel.quickLookToken != lastQuickLookToken else { return }
            lastQuickLookToken = viewModel.quickLookToken
            (scnView as? InteractiveSCNView)?.toggleQuickLook()
        }

        /// Re-frame the deepest (current) level and clear any focused-subfolder labels.
        func resetView() {
            clearFocusLabels()
            focusedSubdir = nil
            if let level = levels.last { flyToLevel(level) }
        }

        /// Fly into a subfolder platform without rebuilding (parent stays visible),
        /// and label its individual items so its contents become readable in place.
        func focusSubdir(_ platform: SCNNode) {
            focusedSubdir = platform

            let platformBox = platform.geometry as? SCNBox
            let platformWidth = platformBox?.width ?? SceneBuilder.cellSize

            // Labels are baked into the platform itself (in SceneBuilder.makeSubdirNode)
            // so this used to also add them on focus — that's redundant now. Just
            // fly the camera.
            flyToFrame(
                center: platform.worldPosition,
                halfExtent: platformWidth / 2,
                duration: 0.55,
                tight: true
            )
        }

        private func clearFocusLabels() {
            focusLabelNodes.forEach { $0.removeFromParentNode() }
            focusLabelNodes.removeAll()
        }

        // MARK: - Selection spotlight + corona (FSN-style warm pool of light on the selected item)

        /// Real SCNLight spot — illuminates the selected item and the surface
        /// beneath it. The corona disc and volumetric cone are parked at opacity
        /// 0 (and never animated up) so all the visible selection feedback comes
        /// from this light. Intensity is tuned to read clearly without blowing
        /// out the slab top — PBR material with roughness 0.55 gives a soft
        /// diffuse glow rather than a hard specular hotspot at 600 lumens.
        private func configureSelectionSpotlight() {
            let node = SCNNode()
            let light = SCNLight()
            light.type = .spot
            light.color = NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.45, alpha: 1)
            light.intensity = 0
            light.attenuationStartDistance = 1.5
            light.attenuationEndDistance = 14
            // Soft shadow so the plate occludes its own beam on the floor — the
            // visible "ring of light" past the plate edge is the light spilling
            // around the plate, not a texture.
            light.castsShadow = true
            light.shadowRadius = 8
            light.shadowSampleCount = 16
            light.shadowMode = .deferred
            light.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.5)
            node.light = light
            node.name = "selectionSpotlight"
            // Aim straight down (-Y). Only position + cone angles change at runtime.
            node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
            scene.rootNode.addChildNode(node)
            spotlightNode = node
        }

        /// A flat warm-gradient disc that sits on the surface beneath the selected
        /// item — the visible "circle of light" around the item. Scales with the
        /// item's footprint.
        private func configureSelectionCorona() {
            let plane = SCNPlane(width: coronaBaseSize, height: coronaBaseSize)
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            // Texture lives in diffuse so `transparencyMode = .aOne` reads the
            // gradient's actual alpha. (Putting it in emission with diffuse=clear
            // made the entire material transparent — that was the long-standing
            // reason the halo was never showing up.)
            mat.diffuse.contents = Self.makeCoronaTexture()
            mat.transparencyMode = .aOne
            mat.isDoubleSided = true
            mat.writesToDepthBuffer = false
            mat.readsFromDepthBuffer = true
            // Trilinear with mipmaps + edge clamping. Without mipFilter = .linear
            // the texture is sampled with point-LOD at oblique viewing angles,
            // producing diagonal moiré bands across the halo. Clamping the wrap
            // mode also prevents the gradient from tiling at the plane edges.
            mat.diffuse.minificationFilter = .linear
            mat.diffuse.magnificationFilter = .linear
            mat.diffuse.mipFilter = .linear
            mat.diffuse.wrapS = .clamp
            mat.diffuse.wrapT = .clamp
            plane.firstMaterial = mat

            let node = SCNNode(geometry: plane)
            // Lay flat (facing +Y) so it sits on the surface like the existing labels.
            node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
            node.opacity = 0
            node.renderingOrder = 5
            node.castsShadow = false
            node.name = "selectionCorona"
            scene.rootNode.addChildNode(node)
            coronaNode = node
        }

        /// A translucent warm-tinted cone of "volumetric" light from the spotlight
        /// source down to the selected item. Apex narrow (point source), base wide
        /// (matches the spot's pool). Cone is recycled across selections.
        private func configureSelectionCone() {
            let cone = SCNCone(
                topRadius: coneBaseTopRadius,
                bottomRadius: coneBaseBottomRadius,
                height: coneBaseHeight
            )
            // 96 radial wedges (up from the default 48) so the cone's silhouette
            // and any visible triangle edges read as a smooth circle rather than
            // a faceted polygon, even at wide bottom radii.
            cone.radialSegmentCount = 96
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.55, alpha: 0.16)
            mat.emission.contents = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.50, alpha: 0.16)
            mat.transparencyMode = .aOne
            mat.isDoubleSided = true
            mat.writesToDepthBuffer = false
            mat.readsFromDepthBuffer = true
            mat.cullMode = .back
            cone.firstMaterial = mat

            let node = SCNNode(geometry: cone)
            node.opacity = 0
            node.renderingOrder = 4
            node.castsShadow = false
            node.name = "selectionCone"
            scene.rootNode.addChildNode(node)
            coneNode = node
        }

        /// A flat warm-gold torus that lies on the surface around the selected
        /// item. Replaces the spot-light / corona approach: the ring is geometry,
        /// not light, so it scales cleanly with the item and never blows out the
        /// slab's material or bleeds onto neighbors. Geometry is rebuilt on each
        /// selection (cheap — one SCNTorus alloc) so the ring fits the item.
        private func configureSelectionRing() {
            // Soft halo as a textured flat plane (not extruded geometry). The
            // texture has the ring drawn with multiple alpha-decreasing strokes,
            // so the visible edges are diffuse — no hard geometric edges.
            // Additive blend on a constant material makes it read as light.
            let plane = SCNPlane(width: 1.0, height: 1.0)
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = Self.selectionRingTexture
            mat.transparencyMode = .aOne
            mat.blendMode = .add
            mat.isDoubleSided = true
            mat.writesToDepthBuffer = false
            mat.readsFromDepthBuffer = true
            mat.diffuse.minificationFilter = .linear
            mat.diffuse.magnificationFilter = .linear
            mat.diffuse.mipFilter = .linear
            mat.diffuse.wrapS = .clamp
            mat.diffuse.wrapT = .clamp
            plane.firstMaterial = mat

            let wrapper = SCNNode()
            wrapper.opacity = 0
            wrapper.renderingOrder = 6
            wrapper.castsShadow = false
            wrapper.name = "selectionRing"

            let inner = SCNNode(geometry: plane)
            // SCNPlane is in the XY plane by default (vertical, facing +Z).
            // Rotate -π/2 around X to lay it flat in the XZ plane facing +Y.
            inner.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
            inner.castsShadow = false
            inner.name = "selectionRingInner"
            wrapper.addChildNode(inner)

            scene.rootNode.addChildNode(wrapper)
            selectionRingNode = wrapper
            selectionRingInner = inner

            // Scale pulse only — no tilt animation. The X-tilt was rotating the
            // flat halo so its front edge dipped under the plate's surface.
            let pulse = SCNAction.sequence([
                SCNAction.scale(to: 1.05, duration: 0.9),
                SCNAction.scale(to: 1.00, duration: 0.9),
            ])
            pulse.timingMode = .easeInEaseOut
            inner.runAction(SCNAction.repeatForever(pulse))
        }

        /// Pre-rendered soft halo texture: a single sharp rounded-rect stroke
        /// passed through Core Image's `CIGaussianBlur` so the falloff is a
        /// continuous Gaussian rather than the visibly-banded multi-stroke
        /// stack we had before.
        private static let selectionRingTexture: NSImage = {
            let pixels = 512
            let size = CGFloat(pixels)
            let bitmap: (rep: NSBitmapImageRep, nsctx: NSGraphicsContext) = {
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 16, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0
                )!
                let ctx = NSGraphicsContext(bitmapImageRep: rep)!
                rep.size = NSSize(width: size, height: size)
                return (rep, ctx)
            }()

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = bitmap.nsctx
            let ctx = bitmap.nsctx.cgContext

            // Ring center at 70% of the texture half-extent. The blur expands
            // outward from this stroke; the remaining 30% is the falloff room.
            let ringHalf = size * 0.5 * 0.70
            let center = CGPoint(x: size / 2, y: size / 2)
            let cornerRadius: CGFloat = size * 0.03
            let ringRect = CGRect(
                x: center.x - ringHalf,
                y: center.y - ringHalf,
                width: ringHalf * 2, height: ringHalf * 2
            )
            let path = CGPath(
                roundedRect: ringRect,
                cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                transform: nil
            )

            let baseColor = NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.32, alpha: 1.0)
            ctx.setStrokeColor(baseColor.cgColor)
            ctx.setLineWidth(8)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
            NSGraphicsContext.restoreGraphicsState()

            // Blur — single Gaussian pass gives a perfectly smooth falloff.
            guard let sharpCG = bitmap.rep.cgImage else {
                let image = NSImage(size: NSSize(width: size, height: size))
                image.addRepresentation(bitmap.rep)
                return image
            }
            let sharpCI = CIImage(cgImage: sharpCG)
            let blur = CIFilter(name: "CIGaussianBlur")!
            blur.setValue(sharpCI, forKey: kCIInputImageKey)
            // 22 px σ — wide enough to read as a soft halo, tight enough that
            // the outer falloff doesn't bleed into adjacent mini-item labels
            // (which sit ~0.03 world units in front of each mini slab).
            blur.setValue(22.0, forKey: kCIInputRadiusKey)

            let extent = CGRect(x: 0, y: 0, width: size, height: size)
            let ciCtx = CIContext()
            guard
                let outputCI = blur.outputImage?.cropped(to: extent),
                let outputCG = ciCtx.createCGImage(outputCI, from: extent)
            else {
                let image = NSImage(size: NSSize(width: size, height: size))
                image.addRepresentation(bitmap.rep)
                return image
            }

            let blurredRep = NSBitmapImageRep(cgImage: outputCG)
            let image = NSImage(size: NSSize(width: size, height: size))
            image.addRepresentation(blurredRep)
            return image
        }()

        func handleSelectionChange() {
            let path = viewModel.selectedURL?.path
            if path == lastSelectedPath { return }
            lastSelectedPath = path
            // Keep an open Quick Look panel in sync with the selection (closes it
            // when nothing is actionable, rather than leaving a stale preview).
            (scnView as? InteractiveSCNView)?.refreshQuickLookIfVisible()
            guard let path, let node = findNode(forPath: path),
                  node.name == "file" || node.name == "pedestal:subdir" else {
                hideSpotlight()
                return
            }
            moveSpotlight(to: node)
        }

        /// Position the selection ring around `target`. The spot light, corona,
        /// and volumetric cone all stay parked at zero — the ring is the entire
        /// selection feedback now.
        private func moveSpotlight(to target: SCNNode) {
            guard let wrapper = selectionRingNode, let inner = selectionRingInner else { return }
            let world = target.worldPosition
            let halfH = boxHeight(target) / 2
            let itemBaseY = world.y - halfH
            let f = footprint(target)
            // Ring center sits AT the slab edge (no outward offset). The blurred
            // halo's outer falloff naturally extends slightly past the edge for
            // the visible glow; pushing the ring further out would make the
            // glow reach into the mini-item labels in front.
            let outerHalf = f * 0.5
            let planeWidth = outerHalf * 2.0 / 0.70
            // Flat plane — no thickness — just lift above the surface enough to
            // avoid z-fight, no animation that could push it under.
            let baseY = itemBaseY + 0.02

            let plane = SCNPlane(width: planeWidth, height: planeWidth)
            plane.firstMaterial = inner.geometry?.firstMaterial

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.28
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            inner.geometry = plane
            wrapper.position = SCNVector3(world.x, baseY, world.z)
            wrapper.opacity = 0.95
            SCNTransaction.commit()
        }

        /// Build a flat square-frame shape sized by `outerHalf` (half-side of
        /// the outer rounded rect) with the given wall thickness and corner
        /// radius. Path uses even-odd winding so the inner rect punches a hole.
        private static func makeSelectionRingShape(
            outerHalf: CGFloat, wallThickness: CGFloat, cornerRadius: CGFloat
        ) -> SCNShape {
            let innerHalf = max(0.001, outerHalf - wallThickness)
            let outerCorner = min(cornerRadius, outerHalf * 0.5)
            let innerCorner = max(0, outerCorner - wallThickness * 0.5)

            let path = NSBezierPath()
            path.appendRoundedRect(
                NSRect(x: -outerHalf, y: -outerHalf, width: outerHalf * 2, height: outerHalf * 2),
                xRadius: outerCorner, yRadius: outerCorner
            )
            path.appendRoundedRect(
                NSRect(x: -innerHalf, y: -innerHalf, width: innerHalf * 2, height: innerHalf * 2),
                xRadius: innerCorner, yRadius: innerCorner
            )
            path.windingRule = .evenOdd

            let shape = SCNShape(path: path, extrusionDepth: wallThickness)
            // Modest curve smoothness — the path is mostly straight edges
            // anyway, the corners are the only places that need any segments.
            shape.chamferRadius = 0
            return shape
        }

        /// Half the step (one cell) of the grid containing `target`. Used to
        /// clamp the spot light's outer-cone radius so the pool can't reach a
        /// neighbor. Mini items get their parent's mini-grid step; root items
        /// get the level's `gridStep` (stashed on the level node by
        /// `SceneBuilder.makeLevelNode`).
        private func gridCellHalfExtent(for target: SCNNode) -> CGFloat {
            if let parent = target.parent, parent.name == "pedestal:subdir",
               let parentBox = parent.geometry as? SCNBox {
                let siblings = parent.childNodes.filter {
                    $0.name == "file" || $0.name == "pedestal:subdir"
                }
                let cols = max(1, Int(ceil(sqrt(Double(max(siblings.count, 1))))))
                let step = parentBox.width * SceneBuilder.subdirUsableFactor / CGFloat(cols)
                return step / 2 * 1.2
            }
            var n: SCNNode? = target
            while let cur = n {
                if cur.name == "level",
                   let stepNum = cur.value(forKey: "gridStep") as? NSNumber {
                    return CGFloat(stepNum.doubleValue) / 2 * 1.2
                }
                n = cur.parent
            }
            return .greatestFiniteMagnitude
        }

        /// Position the volumetric cone with its narrow apex at the spotlight
        /// source and its wide base on the item's *top* surface (not the floor).
        /// Critical: if the cone reached the floor it would overlap the corona
        /// plane and its radial wedge triangles would show as visible spokes
        /// across the halo. Ending the cone at the item top leaves the floor
        /// halo unobstructed.
        private func moveCone(to target: SCNNode, bottomRadius: CGFloat, itemBaseY: CGFloat, lightY: CGFloat) {
            guard let cone = coneNode else { return }
            let world = target.worldPosition
            let itemTopY = world.y + boxHeight(target) / 2
            let coneHeight = lightY - itemTopY
            let centerY = (lightY + itemTopY) / 2
            // X/Z scale = circular radius scale (keeps the cone round). Y scale
            // stretches the cone vertically so its base sits exactly on the
            // item's TOP face and its apex at the light source.
            let radialScale = bottomRadius / coneBaseBottomRadius
            let yScale = coneHeight / coneBaseHeight

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.28
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            cone.position = SCNVector3(world.x, centerY, world.z)
            cone.scale = SCNVector3(radialScale, yScale, radialScale)
            cone.opacity = 1.0
            SCNTransaction.commit()
        }

        /// Position the corona disc at the base of `target` and scale it so its
        /// visible bright ring lands clearly outside the item's footprint — a
        /// proper halo around the item, not a thin sliver at its edge.
        private func moveCorona(to target: SCNNode) {
            guard let corona = coronaNode else { return }
            let world = target.worldPosition
            // Sit just above the target's bottom face (= floor or platform top).
            let baseY = world.y - boxHeight(target) / 2 + 0.012
            // Halo extent = footprint × 2.4. With this gradient (bright ring at
            // 50% of the texture radius), the visible bright pool lands at world
            // radius `footprint × 0.6` — exactly footprint/2 from the item edge,
            // a clear halo around the slab. The cone bottom radius is set to
            // `footprint / 2` in `moveSpotlight` so it lands on the item edge
            // (no overhang past the plate) — i.e., the cone's bottom and the
            // corona's bright ring are stacked: cone occupies the item, bright
            // pool sits just outside it, they read as one effect.
            let extent = footprint(target) * 2.4
            let scale = extent / coronaBaseSize

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.28
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            corona.position = SCNVector3(world.x, baseY, world.z)
            corona.scale = SCNVector3(scale, scale, scale)
            corona.opacity = 1.0
            SCNTransaction.commit()
        }

        /// Ramp the selection ring to zero (parked).
        private func hideSpotlight() {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.20
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeIn)
            selectionRingNode?.opacity = 0
            // Belt-and-suspenders: the spot/corona/cone never go above zero
            // anymore, but keep clearing them in case something nudges them.
            spotlightNode?.light?.intensity = 0
            coronaNode?.opacity = 0
            coneNode?.opacity = 0
            SCNTransaction.commit()
        }

        /// Largest horizontal extent of an interactive node's box geometry.
        /// Falls back to one grid cell for non-box geometries.
        private func footprint(_ node: SCNNode) -> CGFloat {
            if let box = node.geometry as? SCNBox {
                return max(box.width, box.length)
            }
            return CGFloat(SceneBuilder.cellSize)
        }

        /// Vertical extent of an interactive node's box geometry (zero if not a box).
        private func boxHeight(_ node: SCNNode) -> CGFloat {
            (node.geometry as? SCNBox)?.height ?? 0
        }

        /// Radial-gradient bitmap used as the corona's diffuse map. Warm amber
        /// ring fading to fully-transparent at the edge.
        ///
        /// Rendered into a 16-bits-per-channel `NSBitmapImageRep` rather than via
        /// `NSImage.lockFocus()` (which is 8-bit). With only 256 alpha levels the
        /// gradient quantizes into visible diagonal bands when the corona is
        /// viewed at an oblique angle — 16-bit precision keeps the falloff smooth.
        private static func makeCoronaTexture() -> NSImage {
            let pixels = 1024
            let size = CGFloat(pixels)
            guard let rep = NSBitmapImageRep(
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
            ), let nsctx = NSGraphicsContext(bitmapImageRep: rep) else {
                return NSImage(size: NSSize(width: size, height: size))
            }
            rep.size = NSSize(width: size, height: size)

            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = nsctx
            let ctx = nsctx.cgContext

            let center = CGPoint(x: size / 2, y: size / 2)
            // Single smooth ring: one continuous bump from 0 → peak → 0. The
            // previous four-stop curve [0, 0.55, 0.85, 1] / [0, 0.90, 0.55, 0]
            // had a deliberate brightness drop between 55% and 85% radius, which
            // the eye saw as a dark concentric ring between two bright bands —
            // the very "two-rings" artifact in the latest screenshot. With three
            // stops there's nothing to interpret as a secondary band.
            let colors = [
                NSColor(calibratedRed: 1.00, green: 0.88, blue: 0.58, alpha: 0.00).cgColor,
                NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.50, alpha: 0.80).cgColor,
                NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.32, alpha: 0.00).cgColor,
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.5, 1]
            ) {
                ctx.drawRadialGradient(
                    gradient,
                    startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: size / 2,
                    options: []
                )
            }

            let image = NSImage(size: NSSize(width: size, height: size))
            image.addRepresentation(rep)
            return image
        }

        // MARK: - Focus request (sidebar → 3D)

        func handleFocusRequest() {
            guard let req = viewModel.sceneFocusRequest, req.token != lastFocusToken else { return }
            lastFocusToken = req.token

            if let node = findNode(forPath: req.url.path) {
                if node.name == "pedestal:subdir" {
                    enterSubdir(node, url: req.url)
                } else {
                    flyToFrame(
                        center: node.worldPosition,
                        halfExtent: SceneBuilder.fileBaseWidth / 2,
                        duration: 0.5,
                        tight: true
                    )
                }
                return
            }
            // Not in the current scene (deeper than what's rendered) — re-root to a
            // DIRECTORY so it becomes a new layer. Never re-root onto a file.
            viewModel.descend(into: directoryToReRoot(for: req.url))
        }

        /// Enter a subfolder: focus it in place if its contents are rendered, otherwise
        /// re-root (which adds it as a new layer below the parent).
        private func enterSubdir(_ node: SCNNode, url: URL?) {
            let hasContents = node.childNodes.contains { $0.name == "file" || $0.name == "pedestal:subdir" }
            if hasContents {
                focusSubdir(node)
            } else if let url {
                viewModel.descend(into: url)
            }
        }

        /// Resolve a URL to the directory we should re-root to: the URL itself if it's
        /// a directory, otherwise its parent.
        private func directoryToReRoot(for url: URL) -> URL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                return url.deletingLastPathComponent()
            }
            return url
        }

        private func findNode(forPath path: String) -> SCNNode? {
            nodeIndex[path]
        }

        /// Rebuild the path → interactive-node index. One scene walk per navigation,
        /// instead of a full enumeration on every selection / focus lookup.
        private func rebuildNodeIndex() {
            nodeIndex.removeAll(keepingCapacity: true)
            scene.rootNode.enumerateChildNodes { node, _ in
                guard let name = node.name,
                      name == "file" || name == "pedestal:subdir" || name == "navup",
                      let path = node.fsPayload?.url.path else { return }
                nodeIndex[path] = node
            }
        }

        // MARK: - Camera framing

        /// Compute (distance, height) for an overview that frames the whole grid.
        ///
        /// Analytic bounding-sphere fit: enclose the grid in a sphere of radius `R`
        /// and back the camera off until that sphere fits within the camera's
        /// narrower field-of-view axis. No matrix/clip-space conventions to get
        /// wrong, and it's guaranteed to contain the entire grid.
        private func overviewDistanceHeight(
            halfExtent: CGFloat,
            tight: Bool = false
        ) -> (distance: Double, height: Double) {
            let pitch = 32.0 * .pi / 180.0
            let cosP = cos(pitch), sinP = sin(pitch)

            // Grid is (roughly) square in the XZ plane; the corner sits at
            // halfExtent·√2 from center. Add the tallest block + a little slack.
            // In `tight` (single-item focus) mode we skip the grid-size floor and
            // shrink the slack — both exist to keep an entire grid in frame and
            // they vastly over-fit a single 1.4-wide file slab, which is why a
            // selection used to land ~8 units back instead of dollying in close.
            let ext = tight ? Double(halfExtent) : Double(max(halfExtent, 1.5))
            let slack = tight ? 0.2 : 1.0
            let radius = sqrt(2.0) * ext + slack

            // Determine the binding (smaller) half-FOV from the camera + aspect.
            var halfFov = (55.0 * .pi / 180.0) / 2.0
            if let view = scnView, let cam = view.pointOfView?.camera,
               view.bounds.width > 1, view.bounds.height > 1 {
                let fov = Double(cam.fieldOfView) * .pi / 180.0
                let aspect = Double(view.bounds.width / view.bounds.height)
                let hHalf: Double
                let vHalf: Double
                if cam.projectionDirection == .vertical {
                    vHalf = fov / 2
                    hHalf = atan(tan(vHalf) * aspect)
                } else {
                    hHalf = fov / 2
                    vHalf = atan(tan(hHalf) / max(aspect, 0.0001))
                }
                halfFov = min(hHalf, vHalf)
            }

            // Straight-line camera distance so the sphere subtends the FOV exactly,
            // plus margin so content isn't edge-to-edge. Tight mode fits the sphere
            // exactly (margin 1.0) so the item is as large as it can be without
            // clipping at the frame edges.
            let margin = tight ? 1.0 : 1.18
            let L = (radius / sin(max(halfFov, 0.01))) * margin

            return (L * cosP, L * sinP)
        }

        // MARK: - Input plumbing

        /// Install a local key/flags monitor so the fly camera receives WASD/arrow input
        /// regardless of which view is first responder.
        func installEventMonitors() {
            if keyMonitor != nil { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                guard let self else { return event }
                return self.handleMonitoredEvent(event)
            }
            // Clear held keys when our window loses key focus, so a key still held
            // during Cmd-Tab / window-switch doesn't leave the camera drifting.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, note.object as? NSWindow === self.scnView?.window else { return }
                    self.flyCamera.releaseAllKeys()
                }
            }
        }

        /// Remove the key/flags monitor and resign observer.
        func uninstallEventMonitors() {
            if let m = keyMonitor {
                NSEvent.removeMonitor(m)
                keyMonitor = nil
            }
            if let o = resignObserver {
                NotificationCenter.default.removeObserver(o)
                resignObserver = nil
            }
        }

        /// Route a monitored key event to the fly camera; swallow it (return nil) if
        /// the camera consumed it, otherwise pass it through.
        private func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
            // Local monitors are app-wide; only handle events for THIS coordinator's
            // window so multiple open windows don't drive each other's cameras.
            guard let myWindow = scnView?.window, event.window === myWindow else { return event }
            switch event.type {
            case .keyDown:
                if flyCamera.handleKeyDown(event) { return nil }
            case .keyUp:
                if flyCamera.handleKeyUp(event) { return nil }
            case .flagsChanged:
                flyCamera.handleFlagsChanged(event)
            default: break
            }
            return event
        }

        // MARK: - Click / hover

        /// Handle a click in the scene: hit-test for an item and select / enter / open
        /// it (single = select+focus/enter, double = open file / re-root folder). A
        /// click on empty space deselects and resets the view.
        func handleClickAt(point: CGPoint, clickCount: Int) {
            guard let view = scnView else { return }
            // Search ALL hits, not just the closest — the topmost hit may be a
            // non-interactive helper (selection corona/cone), and we want to fall
            // through to the actual item underneath rather than treating the
            // click as empty-space (which would deselect).
            let hits = view.hitTest(point, options: [
                .ignoreHiddenNodes: true,
                .searchMode: SCNHitTestSearchMode.all.rawValue,
            ])
            guard let target = hits.lazy.compactMap({ self.interactiveAncestor(of: $0.node) }).first else {
                // No interactive item under the cursor → genuinely empty space.
                viewModel.select(nil)
                resetView()
                return
            }
            let url = target.fsPayload?.url

            if target.name == "navup", let url {
                // Back-up tile: any click → navigate to parent.
                viewModel.navigate(to: url)
                return
            }
            if clickCount >= 2 {
                // Double click → navigate / open
                if target.name == "file", let url {
                    NSWorkspace.shared.open(url)
                    viewModel.select(url)
                } else if target.name == "pedestal:subdir", let url {
                    viewModel.descend(into: url)
                }
            } else if target.name == "pedestal:subdir" {
                // Single click on a folder flies INTO it without rebuilding the scene,
                // so the parent grid stays around you (FSN's continuous space), and
                // labels its items so the contents are readable in place. Folders whose
                // contents aren't rendered (nested tiles) re-root instead.
                viewModel.select(url)
                enterSubdir(target, url: url)
            } else {
                // Single click on a file selects it and frames it with the camera
                // (same angle as everything else), dollied in close FSN-style so
                // the slab fills the frame.
                viewModel.select(url)
                flyToFrame(
                    center: target.worldPosition,
                    halfExtent: SceneBuilder.fileBaseWidth / 2,
                    duration: 0.45,
                    tight: true
                )
            }
        }

        /// The URL we should navigate to from a back-up tile inside `levelURL`,
        /// or nil if `levelURL` is already at (or above) the opened root.
        private func navigableParentURL(for levelURL: URL) -> URL? {
            guard let opened = viewModel.openedRootURL else { return nil }
            let parent = levelURL.deletingLastPathComponent()
            // Back is only meaningful when we'd stay at or below the opened root.
            if parent.path == opened.path || parent.path.hasPrefix(opened.path + "/") {
                return parent
            }
            return nil
        }

        /// Hit-test under the cursor and update the hover highlight + HUD target.
        func handleHoverAt(point: CGPoint) {
            guard let view = scnView else { return }
            // Same as click: walk all hits so selection helpers (corona/cone)
            // don't shadow the actual item beneath the cursor.
            let hits = view.hitTest(point, options: [
                .ignoreHiddenNodes: true,
                .searchMode: SCNHitTestSearchMode.all.rawValue,
            ])
            let target = hits.lazy.compactMap { self.interactiveAncestor(of: $0.node) }.first
            setHover(target)
            viewModel.hover(target?.fsPayload?.url)
        }

        /// Forward a scroll delta to the fly camera (dolly).
        func handleScroll(deltaY: CGFloat) {
            flyCamera.handleScroll(deltaY: deltaY)
        }

        /// Forward a drag delta to the fly camera (look).
        func handleMouseDrag(deltaX: CGFloat, deltaY: CGFloat) {
            flyCamera.handleMouseDrag(deltaX: deltaX, deltaY: deltaY)
        }

        // MARK: - Hover highlight

        /// Walk up from a hit node to the nearest interactive ancestor (file,
        /// folder, or back-up tile).
        private func interactiveAncestor(of node: SCNNode) -> SCNNode? {
            var current: SCNNode? = node
            while let n = current {
                if let name = n.name,
                   name == "file" || name == "pedestal:subdir" || name == "navup" {
                    return n
                }
                current = n.parent
            }
            return nil
        }

        /// Apply an emissive highlight to the hovered node, restoring the previous one.
        private func setHover(_ node: SCNNode?) {
            if hoveredNode === node { return }
            clearHover()
            guard let node, let mat = node.geometry?.firstMaterial else { return }
            hoverSavedEmission = mat.emission.contents
            let highlight: NSColor
            switch node.name {
            case "pedestal:subdir":
                // Cool-neutral hover tint that complements the blue folders.
                highlight = NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.22, alpha: 1)
            default:
                highlight = NSColor(calibratedWhite: 0.22, alpha: 1)
            }
            mat.emission.contents = highlight
            hoveredNode = node
        }

        /// Restore the previously-hovered node's emission and clear hover state.
        private func clearHover() {
            if let prev = hoveredNode, let mat = prev.geometry?.firstMaterial {
                mat.emission.contents = hoverSavedEmission ?? NSColor.black
            }
            hoveredNode = nil
            hoverSavedEmission = nil
        }
    }
}

// MARK: - SCNView subclass with mouse routing

/// `SCNView` subclass that routes mouse/scroll events to the Coordinator, separates
/// clicks from drags, and reserves a top strip for dragging the (title-bar-less) window.
final class InteractiveSCNView: SCNView {
    weak var coordinator: SceneHostView.Coordinator?

    private var mouseDownPoint: NSPoint?
    private var draggedPastThreshold = false
    private var consumingWindowDrag = false
    private let dragThreshold: CGFloat = 4
    private let topDeadzoneHeight: CGFloat = 32

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    /// True if `point` (in view-local coordinates) is in the top strip reserved
    /// for window dragging (and the traffic-light area when title bar is hidden).
    private func isInTopDeadzone(_ point: NSPoint) -> Bool {
        if isFlipped {
            return point.y < topDeadzoneHeight
        } else {
            return point.y > bounds.height - topDeadzoneHeight
        }
    }

    /// Keep the Metal backing scale in sync when first attached to a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            layer?.contentsScale = window.backingScaleFactor
        }
    }

    /// Keep the Metal backing scale in sync when the window moves between displays
    /// with different scale factors (fixes the viewport drift bug).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
    }

    /// Begin a click/drag, or start a window-drag if the press is in the top strip.
    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if isInTopDeadzone(viewPoint) {
            // Top strip is reserved for window dragging — don't capture as scene input.
            consumingWindowDrag = true
            window?.performDrag(with: event)
            return
        }
        consumingWindowDrag = false
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
        mouseDownPoint = event.locationInWindow
        draggedPastThreshold = false
    }

    /// Past a small threshold, treat the gesture as a look-drag and forward deltas.
    override func mouseDragged(with event: NSEvent) {
        if consumingWindowDrag { return }
        super.mouseDragged(with: event)
        if !draggedPastThreshold, let start = mouseDownPoint {
            let p = event.locationInWindow
            if hypot(p.x - start.x, p.y - start.y) > dragThreshold {
                draggedPastThreshold = true
            }
        }
        if draggedPastThreshold {
            coordinator?.handleMouseDrag(deltaX: event.deltaX, deltaY: event.deltaY)
        }
    }

    /// If the gesture never became a drag, treat it as a click (with click count).
    override func mouseUp(with event: NSEvent) {
        if consumingWindowDrag {
            consumingWindowDrag = false
            return
        }
        super.mouseUp(with: event)
        if !draggedPastThreshold {
            let point = convert(event.locationInWindow, from: nil)
            coordinator?.handleClickAt(point: point, clickCount: event.clickCount)
        }
        mouseDownPoint = nil
        draggedPastThreshold = false
    }

    /// Right-drag also looks around (no click semantics).
    override func rightMouseDragged(with event: NSEvent) {
        super.rightMouseDragged(with: event)
        coordinator?.handleMouseDrag(deltaX: event.deltaX, deltaY: event.deltaY)
    }

    /// Forward cursor movement for hover highlighting.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        coordinator?.handleHoverAt(point: point)
    }

    /// Forward scroll for camera dolly.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        coordinator?.handleScroll(deltaY: event.scrollingDeltaY)
    }

    /// Maintain a full-bounds tracking area so `mouseMoved` (hover) fires.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    // MARK: - Quick Look (responder-chain controlled)

    /// AppKit walks the responder chain when the Quick Look panel opens; advertise
    /// that this view controls it, and hand off the data source via the documented
    /// begin/end callbacks instead of poking the shared panel imperatively.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    /// Toggle the shared Quick Look panel. Becoming first responder first ensures
    /// AppKit routes begin/endPreviewPanelControl back to this view.
    func toggleQuickLook() {
        guard coordinator?.viewModel.actionableURL != nil, let panel = QLPreviewPanel.shared() else { return }
        window?.makeFirstResponder(self)
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Reload an open panel after the selection changes, closing it when nothing is
    /// actionable so it never lingers on a stale preview.
    func refreshQuickLookIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        if coordinator?.viewModel.actionableURL == nil {
            panel.orderOut(nil)
        } else {
            panel.reloadData()
        }
    }
}

// MARK: - Quick Look data source

extension InteractiveSCNView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        coordinator?.viewModel.actionableURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        coordinator?.viewModel.actionableURL as QLPreviewItem?
    }
}

import SwiftUI
@preconcurrency import SceneKit
import AppKit
import Quartz

/// SwiftUI wrapper that hosts the SceneKit `SCNView` and bridges view-model state
/// (current root, focus/reset requests, selection) into the 3D scene via its Coordinator.
struct SceneHostView: NSViewRepresentable {

    var viewModel: BrowserViewModel

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
        // Not `rendersContinuously`: SCNView re-renders on its own whenever the
        // scene changes (camera moves, actions, transactions, material edits).
        // Forcing continuous rendering would burn GPU/battery while idle.
        view.autoresizingMask = [.width, .height]
        view.coordinator = context.coordinator
        view.delegate = context.coordinator   // render-loop callback for overlay handoff
        context.coordinator.scnView = view
        context.coordinator.installEventMonitors()
        context.coordinator.flyCamera.start(in: view)
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
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let scene: SCNScene
        let viewModel: BrowserViewModel
        weak var scnView: SCNView?
        let flyCamera: FlyCameraController

        /// Set right after a freshly-built level is added to the scene; the render
        /// delegate flips the loading overlay off only once SceneKit has actually
        /// drawn the first frame containing it — so there's no black gap between
        /// the overlay disappearing and the scene appearing. `nonisolated(unsafe)`
        /// because the delegate callback isn't main-actor isolated; it's a single
        /// bool flag, so the unsynchronized access is benign.
        nonisolated(unsafe) private var clearOverlayOnNextRender = false

        /// SCNView render-loop callback (fires every frame). Drops the loading
        /// overlay the first frame after a new level is attached and drawn.
        nonisolated func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            guard clearOverlayOnNextRender else { return }
            clearOverlayOnNextRender = false
            Task { @MainActor [weak self] in self?.finishPreparing() }
        }

        private var lastRootID: UUID?
        private var lastFocusToken: Int = 0
        private var lastResetToken: Int = 0
        private var lastColorRebuildToken: Int = 0
        private var levels: [Level] = []
        private var lastSelectedPath: String?
        private var lastQuickLookToken = 0
        /// path → interactive node, rebuilt whenever the level stack changes.
        private var nodeIndex: [String: SCNNode] = [:]
        private var selectionRingNode: SCNNode?
        private var selectionRingInner: SCNNode?
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
            let hasBack: Bool        // whether a front-center back tile is present
        }
        /// Camera never frames a level tighter than this half-extent, so folders with
        /// just a few items don't zoom in uncomfortably close.
        private let minLevelFramingExtent: CGFloat = 3.6
        private let levelDrop: CGFloat = 3.5   // child sits a step below its parent
        private let levelFadeDuration: TimeInterval = 0.6

        func syncFromViewModel() {
            guard let root = viewModel.currentRoot else { return }

            let colorChanged = viewModel.colorRebuildToken != lastColorRebuildToken
            let rootChanged = lastRootID != root.id
            guard rootChanged || colorChanged else { finishPreparing(); return }
            lastRootID = root.id
            lastColorRebuildToken = viewModel.colorRebuildToken
            clearHover()
            hideSpotlight()

            // A color-mode swap with no navigation: walk every file slab in the
            // scene and reapply diffuse colors. Cheap, geometry stays put, the
            // camera frame is preserved.
            if colorChanged && !rootChanged {
                SceneBuilder.recolorFileSlabs(under: scene.rootNode, colorMode: viewModel.colorMode)
                finishPreparing()
                return
            }

            let path = root.url.path
            if let idx = levels.firstIndex(where: { $0.url.path == path }) {
                // Navigated to a folder already in the stack (Back or a breadcrumb)
                // → zoom out: fade the deeper levels away, restore this one to full
                // opacity, and fly the camera back to it.
                popLevelsAnimated(below: idx)
                flyToLevel(levels.last ?? levels[idx])
                finishPreparing()
            } else if let idx = levels.lastIndex(where: { isDescendant(path, of: $0.url.path) }) {
                // Descending from some existing level (not necessarily the deepest one —
                // the clicked folder may live on a higher, still-visible plate). Pop any
                // levels deeper than that ancestor, then add the new layer below it.
                popLevels(below: idx)
                pushLevel(root: root)   // async build off the main thread
            } else {
                // Unrelated root (freshly opened) → reset the stack.
                levels.forEach { $0.node.removeFromParentNode() }
                levels.removeAll()
                pushLevel(root: root)   // async build off the main thread
            }
        }

        /// Clear the view-model's "preparing scene" flag (drops the loading overlay)
        /// only if it's actually set, so routine `updateNSView` calls don't publish a
        /// redundant change and spin the update loop.
        private func finishPreparing() {
            if viewModel.isPreparingScene { viewModel.isPreparingScene = false }
        }

        /// Build a fresh level for `root` OFF the main thread, then attach it on the
        /// main actor. Building (constructing hundreds of `SCNNode`s and rendering a
        /// bitmap label per item) is the expensive step that used to freeze the UI for
        /// large folders; the loading overlay stays up until `attachLevel` finishes.
        private func pushLevel(root: FileSystemNode) {
            // Capture the parent now (popLevels already ran); positioning is cheap and
            // happens on the main actor once the build returns.
            let parent = levels.last
            // Show the back control whenever there's a parent level to return to; fall
            // back to the navigable filesystem parent on a re-root (no parent level).
            let parentURL = parent?.url ?? navigableParentURL(for: root.url)
            // Capture the color mode now, on the main actor — the detached build
            // must not read view-model state from another thread.
            let colorMode = viewModel.colorMode
            Task { [weak self] in
                let built = await Task.detached(priority: .userInitiated) {
                    SceneBuilder.makeLevelNode(root: root, parentURL: parentURL, colorMode: colorMode)
                }.value
                guard let self else { return }
                guard let view = self.scnView else {
                    self.attachLevel(root: root, node: built.node, halfExtent: built.halfExtent,
                                     hasBack: built.hasBack, parent: parent)
                    return
                }
                // Upload the level's geometry/materials/textures to the GPU on a
                // background thread BEFORE it enters the live scene. Without this,
                // the first frame that renders the new level uploads hundreds of
                // label textures on the main thread — the remaining hitch "when
                // rendering starts". Attach only once the resources are ready.
                view.prepare([built.node]) { [weak self] _ in
                    Task { @MainActor in
                        self?.attachLevel(root: root, node: built.node, halfExtent: built.halfExtent,
                                          hasBack: built.hasBack, parent: parent)
                    }
                }
            }
        }

        /// Main-actor tail of `pushLevel`: anchor the freshly-built level on the folder
        /// tile that was entered, cross-fade it in as the parent fades out, fly the
        /// camera in, and drop the loading overlay.
        private func attachLevel(root: FileSystemNode, node: SCNNode, halfExtent: CGFloat, hasBack: Bool, parent: Level?) {
            let center: SCNVector3
            if let parent {
                // Center the child on the folder tile we entered (dropped a step so the
                // parent reads as behind/above). The camera then flies in toward it, so
                // the tile visually "becomes" its contents.
                let tile = folderTileWorldPosition(in: parent, url: root.url) ?? parent.center
                center = SCNVector3(tile.x, parent.center.y - levelDrop, tile.z)
            } else {
                center = SCNVector3(0, 0, 0)
            }
            node.position = center
            node.opacity = parent == nil ? 1 : 0   // fresh root shows at once; children fade in
            scene.rootNode.addChildNode(node)
            let level = Level(url: root.url, node: node, center: center, halfExtent: halfExtent, hasBack: hasBack)
            levels.append(level)

            // Cross-fade the new level in while the parent fades out, then hide the
            // parent so it's neither drawn nor hit-testable. It stays in the stack so
            // going back can fade it straight back in.
            if let parent {
                let parentNode = parent.node
                SCNTransaction.begin()
                SCNTransaction.animationDuration = levelFadeDuration
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                SCNTransaction.completionBlock = { Task { @MainActor in parentNode.isHidden = true } }
                node.opacity = 1
                parentNode.opacity = 0
                SCNTransaction.commit()
            }

            flyToLevel(level)
            rebuildNodeIndex()
            // Keep the overlay up until SceneKit has actually drawn the first frame
            // containing this level (the render delegate clears it), so the wait
            // never flashes to a black scene before the geometry appears.
            clearOverlayOnNextRender = true
        }

        /// World position of the subdir tile for `url` within `level` — the anchor the
        /// child level zooms out from. Nil if that tile isn't in the level.
        private func folderTileWorldPosition(in level: Level, url: URL) -> SCNVector3? {
            for child in level.node.childNodes
            where child.name == "pedestal:subdir" && child.fsPayload?.url == url {
                return child.worldPosition
            }
            return nil
        }

        private func flyToLevel(_ level: Level) {
            var center = level.center
            var extent = level.halfExtent
            // The back control sits just outside the grid's NW corner. Fold it into
            // the frame: take the bounding box of the grid (+halfExtent) and the back
            // corner, then center on it so the whole plate (contents + back) shows.
            if level.hasBack {
                let nwMost = -(level.halfExtent + SceneBuilder.cellSpacing + 1.6)
                let c = (nwMost + level.halfExtent) / 2
                center = SCNVector3(center.x + c, center.y, center.z + c)
                extent = (level.halfExtent - nwMost) / 2
            }
            // Floor the zoom so sparse folders don't end up uncomfortably close.
            extent = max(extent, minLevelFramingExtent)
            flyToFrame(center: center, halfExtent: extent)
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

        /// Animated counterpart to `popLevels` for "go back up the tree": fade the
        /// deeper levels out (removing them when the fade finishes) and fade the
        /// now-current level back in (un-hiding it first).
        private func popLevelsAnimated(below idx: Int) {
            let doomed = (idx + 1 < levels.count) ? Array(levels[(idx + 1)...]) : []
            if !doomed.isEmpty { levels.removeSubrange((idx + 1)...) }
            let targetNode = levels.last?.node
            targetNode?.isHidden = false   // un-hide so it can fade back in

            SCNTransaction.begin()
            SCNTransaction.animationDuration = levelFadeDuration
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            SCNTransaction.completionBlock = { [weak self] in
                Task { @MainActor in
                    doomed.forEach { $0.node.removeFromParentNode() }
                    self?.rebuildNodeIndex()
                }
            }
            doomed.forEach { $0.node.opacity = 0 }
            targetNode?.opacity = 1
            SCNTransaction.commit()
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

        /// Re-frame the deepest (current) level.
        func resetView() {
            if let level = levels.last { flyToLevel(level) }
        }

        // MARK: - Selection ring

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
            // The pulse action starts when the ring is shown (`moveSpotlight`),
            // not here: a repeat-forever action on a hidden ring would keep
            // SceneKit re-rendering every frame even with nothing selected.
        }

        /// Scale pulse only — no tilt animation. The X-tilt was rotating the
        /// flat halo so its front edge dipped under the plate's surface.
        private static func makeRingPulse() -> SCNAction {
            let pulse = SCNAction.sequence([
                SCNAction.scale(to: 1.05, duration: 0.9),
                SCNAction.scale(to: 1.00, duration: 0.9),
            ])
            pulse.timingMode = .easeInEaseOut
            return SCNAction.repeatForever(pulse)
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

        /// Position the selection ring around `target`. The ring is the entire
        /// selection feedback.
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

            if inner.action(forKey: "pulse") == nil {
                inner.runAction(Self.makeRingPulse(), forKey: "pulse")
            }
        }

        /// Ramp the selection ring to zero (parked) and stop its pulse, so the
        /// hidden ring doesn't keep the render loop alive.
        private func hideSpotlight() {
            selectionRingInner?.removeAction(forKey: "pulse")
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.20
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeIn)
            selectionRingNode?.opacity = 0
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

        // MARK: - Focus request (sidebar → 3D)

        func handleFocusRequest() {
            guard let req = viewModel.sceneFocusRequest, req.token != lastFocusToken else { return }
            lastFocusToken = req.token

            // If the item is rendered in the current scene (file or folder tile),
            // just frame it — selecting a folder shouldn't open it.
            if let node = findNode(forPath: req.url.path) {
                flyToFrame(
                    center: node.worldPosition,
                    halfExtent: footprint(node) / 2,
                    duration: 0.5,
                    tight: true
                )
                return
            }
            // Not in the current scene (deeper than what's rendered) — re-root to a
            // DIRECTORY so it becomes a new layer. Never re-root onto a file.
            viewModel.descend(into: directoryToReRoot(for: req.url))
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

            // Grid is (roughly) square in the XZ plane. A full bounding-sphere fit
            // (radius = halfExtent·√2, the diagonal) is safe but overshoots: at the
            // fixed 32° overview pitch the square's on-screen footprint is governed
            // by its half-width, not its diagonal, so √2 left a ton of dead margin.
            // We fit a tighter radius (≈ half-width + a little) for the overview,
            // which still contains a square-ish grid at this pitch. The `tight`
            // (single-item focus) path keeps the conservative sphere fit — it dollies
            // onto one small slab where over-fitting would read as "floating".
            // In `tight` mode we also skip the grid-size floor and shrink the slack.
            let cornerFactor = tight ? sqrt(2.0) : 1.12
            let ext = tight ? Double(halfExtent) : Double(max(halfExtent, 1.5))
            let slack = tight ? 0.2 : 0.4
            let radius = cornerFactor * ext + slack

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
            let margin = tight ? 1.0 : 1.05
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
                // Compare by identity token: ObjectIdentifier is Sendable, so the
                // non-Sendable NSWindow itself never crosses into the actor hop.
                let windowID = (note.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let windowID,
                          self.scnView?.window.map(ObjectIdentifier.init) == windowID else { return }
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
                // Double click → open: files in the default app, folders by descending.
                if target.name == "file", let url {
                    NSWorkspace.shared.open(url)
                    viewModel.select(url)
                } else if target.name == "pedestal:subdir", let url {
                    viewModel.descend(into: url)
                }
            } else {
                // Single click → select and frame the item (file or folder), dollied
                // in close FSN-style. Folders are opened by double-click, not a single
                // click.
                viewModel.select(url)
                flyToFrame(
                    center: target.worldPosition,
                    halfExtent: footprint(target) / 2,
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

    // The panel-control overrides are nonisolated in the SDK but AppKit only
    // calls them on the main thread — `assumeIsolated` makes that explicit.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if panel.dataSource === self { panel.dataSource = nil }
            if panel.delegate === self { panel.delegate = nil }
        }
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

// `@preconcurrency`: the Quick Look protocols predate Swift concurrency; AppKit
// drives them on the main thread, where this main-actor view already lives.
extension InteractiveSCNView: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        coordinator?.viewModel.actionableURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        coordinator?.viewModel.actionableURL as QLPreviewItem?
    }
}

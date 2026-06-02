import SwiftUI
import SceneKit
import AppKit

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
        private var lastHalfExtent: CGFloat = 8
        private var focusedSubdir: SCNNode?
        private var focusLabelNodes: [SCNNode] = []
        private var levels: [Level] = []
        private var lastSelectedPath: String?
        private var tiltedNode: SCNNode?
        private var tiltSavedEuler: SCNVector3?
        private var tiltSavedPos: SCNVector3?
        private var hoveredNode: SCNNode?
        private var hoverSavedEmission: Any?
        private var keyMonitor: Any?

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
            guard lastRootID != root.id else { return }
            lastRootID = root.id
            clearHover()
            clearFocusLabels()
            clearSelectionTilt()
            focusedSubdir = nil

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
        }

        private func pushLevel(root: FileSystemNode) {
            let (node, halfExtent) = SceneBuilder.makeLevelNode(root: root)
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
        /// angle never changes between navigations — only its position.
        private func flyToFrame(center: SCNVector3, halfExtent: CGFloat, duration: TimeInterval = 0.6) {
            let (distance, height) = overviewDistanceHeight(halfExtent: halfExtent)
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

        /// Re-frame the deepest (current) level and clear any focused-subfolder labels.
        func resetView() {
            clearFocusLabels()
            focusedSubdir = nil
            if let level = levels.last { flyToLevel(level) }
        }

        /// Fly into a subfolder platform without rebuilding (parent stays visible),
        /// and label its individual items so its contents become readable in place.
        func focusSubdir(_ platform: SCNNode) {
            clearFocusLabels()
            focusedSubdir = platform

            let platformHeight = (platform.geometry as? SCNBox)?.height ?? CGFloat(SceneBuilder.subdirPlatformHeight)
            let topY = platformHeight / 2 + 0.012

            for child in platform.childNodes {
                guard let n = child.name, n == "file" || n == "pedestal:subdir",
                      let path = child.value(forKey: "fsURL") as? String else { continue }
                let itemName = (path as NSString).lastPathComponent
                let box = child.geometry as? SCNBox
                let itemW = Double(box?.width ?? 0.5)
                let itemHalfDepth = (box?.length ?? 0.5) / 2
                let label = SceneBuilder.makeContentLabel(
                    text: itemName,
                    maxWorldWidth: CGFloat(max(itemW * 1.5, 0.55))
                )
                label.position = SCNVector3(
                    child.position.x,
                    topY,
                    child.position.z + itemHalfDepth + 0.03
                )
                platform.addChildNode(label)
                focusLabelNodes.append(label)
            }

            // Frame the focused platform at the SAME camera angle as every other view
            // (no special close-up angle), just dollied in to the platform's footprint.
            flyToFrame(center: platform.worldPosition, halfExtent: SceneBuilder.cellSize, duration: 0.55)
        }

        private func clearFocusLabels() {
            focusLabelNodes.forEach { $0.removeFromParentNode() }
            focusLabelNodes.removeAll()
        }

        // MARK: - Selection tilt (raise the selected file like an opened document)

        func handleSelectionChange() {
            let path = viewModel.selectedURL?.path
            if path == lastSelectedPath { return }
            lastSelectedPath = path
            clearSelectionTilt()
            guard let path, let node = findNode(forPath: path), node.name == "file" else { return }
            tiltSavedEuler = node.eulerAngles
            tiltSavedPos = node.position
            tiltedNode = node
            // First lift the slab clear of the folder plate, THEN tilt it — so its
            // bottom edge never dips into the surrounding polygons. Positive X rotation
            // lifts the back edge so the top face (icon + label) faces the camera.
            let lift = SCNAction.moveBy(x: 0, y: 0.8, z: 0, duration: 0.16)
            lift.timingMode = .easeOut
            let tilt = SCNAction.rotateTo(x: CGFloat.pi * 0.32, y: 0, z: 0, duration: 0.22, usesShortestUnitArc: true)
            tilt.timingMode = .easeInEaseOut
            node.runAction(.sequence([lift, tilt]))
        }

        private func clearSelectionTilt() {
            if let n = tiltedNode {
                n.removeAllActions()
                if let e = tiltSavedEuler { n.eulerAngles = e }
                if let p = tiltSavedPos { n.position = p }
            }
            tiltedNode = nil
            tiltSavedEuler = nil
            tiltSavedPos = nil
        }

        // MARK: - Focus request (sidebar → 3D)

        func handleFocusRequest() {
            guard let req = viewModel.sceneFocusRequest, req.token != lastFocusToken else { return }
            lastFocusToken = req.token

            if let node = findNode(forPath: req.url.path) {
                if node.name == "pedestal:subdir" {
                    enterSubdir(node, url: req.url)
                } else {
                    flyToFrame(center: node.worldPosition, halfExtent: 1.4, duration: 0.5)
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
            var result: SCNNode?
            scene.rootNode.enumerateChildNodes { node, stop in
                if let p = node.value(forKey: "fsURL") as? String, p == path {
                    result = node
                    stop.pointee = true
                }
            }
            return result
        }

        // MARK: - Camera framing

        /// Compute (distance, height) for an overview that frames the whole grid.
        ///
        /// Analytic bounding-sphere fit: enclose the grid in a sphere of radius `R`
        /// and back the camera off until that sphere fits within the camera's
        /// narrower field-of-view axis. No matrix/clip-space conventions to get
        /// wrong, and it's guaranteed to contain the entire grid.
        private func overviewDistanceHeight(halfExtent: CGFloat) -> (distance: Double, height: Double) {
            let pitch = 32.0 * .pi / 180.0
            let cosP = cos(pitch), sinP = sin(pitch)

            // Grid is (roughly) square in the XZ plane; the corner sits at
            // halfExtent·√2 from center. Add the tallest block + a little slack.
            let ext = Double(max(halfExtent, 1.5))
            let radius = sqrt(2.0) * ext + 1.0

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
            // plus margin so content isn't edge-to-edge.
            let margin = 1.18
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
                return MainActor.assumeIsolated { self.handleMonitoredEvent(event) }
            }
        }

        /// Remove the key/flags monitor.
        func uninstallEventMonitors() {
            if let m = keyMonitor {
                NSEvent.removeMonitor(m)
                keyMonitor = nil
            }
        }

        /// Route a monitored key event to the fly camera; swallow it (return nil) if
        /// the camera consumed it, otherwise pass it through.
        private func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
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
            let hits = view.hitTest(point, options: [
                .ignoreHiddenNodes: true,
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
            ])
            guard let first = hits.first, let target = interactiveAncestor(of: first.node) else {
                // Clicking empty space deselects and re-frames the whole folder.
                viewModel.select(nil)
                resetView()
                return
            }
            let path = target.value(forKey: "fsURL") as? String
            let url = path.map { URL(fileURLWithPath: $0) }

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
                // (same angle as everything else).
                viewModel.select(url)
                flyToFrame(center: target.worldPosition, halfExtent: 1.4, duration: 0.45)
            }
        }

        /// Hit-test under the cursor and update the hover highlight + HUD target.
        func handleHoverAt(point: CGPoint) {
            guard let view = scnView else { return }
            let hits = view.hitTest(point, options: [
                .ignoreHiddenNodes: true,
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
            ])
            let target = hits.lazy.compactMap { self.interactiveAncestor(of: $0.node) }.first
            setHover(target)
            let path = target?.value(forKey: "fsURL") as? String
            viewModel.hover(path.map { URL(fileURLWithPath: $0) })
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

        /// Walk up from a hit node to the nearest interactive ancestor (file or folder).
        private func interactiveAncestor(of node: SCNNode) -> SCNNode? {
            var current: SCNNode? = node
            while let n = current {
                if let name = n.name, name == "file" || name == "pedestal:subdir" {
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
                highlight = NSColor(calibratedRed: 0.30, green: 0.20, blue: 0.05, alpha: 1)
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
}

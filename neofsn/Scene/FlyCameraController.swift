import SceneKit
import AppKit

@MainActor
final class FlyCameraController {

    let cameraNode: SCNNode

    // Movement state
    private var heldKeys: Set<UInt16> = []
    private var velocity = SIMD3<Double>(0, 0, 0)
    private var yaw: Double = 0
    private var pitch: Double = -0.45

    // Tuning
    private let moveSpeed: Double = 14
    private let boostMultiplier: Double = 3
    private let lookSensitivity: Double = 0.0045
    private let smoothing: Double = 12
    private let damping: Double = 9
    private let scrollSpeed: Double = 0.45

    private var displayTimer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var boost: Bool = false

    /// Bumped whenever a framing flight starts or is cancelled, so a flight's
    /// deferred completion only applies if it's still the active flight.
    private var flightToken = 0

    /// Bind the controller to a camera node and apply the initial yaw/pitch.
    init(cameraNode: SCNNode, initialYaw: Double = 0, initialPitch: Double = -0.45) {
        self.cameraNode = cameraNode
        self.yaw = initialYaw
        self.pitch = initialPitch
        applyOrientation()
    }

    // MARK: - Run loop

    /// Start the 60 Hz update loop that integrates keyboard movement.
    func start() {
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    /// Stop the update loop (call when the hosting view goes away).
    func stop() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    // MARK: - Public reset

    /// Snap the camera back to its default position and orientation.
    func resetToDefault() {
        cameraNode.removeAllActions()
        flightToken &+= 1
        yaw = 0
        pitch = -0.45
        velocity = .zero
        cameraNode.position = SCNVector3(0, 11, 19)
        applyOrientation()
    }

    /// Cancel any in-flight framing animation and recover the camera's *live*
    /// orientation into `yaw`/`pitch`. The fly animates the node directly while
    /// `yaw`/`pitch` stay frozen at their pre-flight values, so without this an
    /// interrupting look/scroll/move would snap the view back to a stale angle.
    private func cancelFlight() {
        let live = cameraNode.presentation.eulerAngles
        cameraNode.removeAllActions()
        flightToken &+= 1   // invalidate any pending flight completion
        pitch = Double(live.x)
        yaw = Double(live.y)
    }

    /// Clear all held movement input. Called when the window loses key focus so a
    /// key still physically held during Cmd-Tab doesn't leave the camera drifting.
    func releaseAllKeys() {
        heldKeys.removeAll()
        boost = false
        velocity = .zero
    }

    /// Animate the camera to look at `focus` from `distance` back and `height` up
    /// (absolute Y), facing along -Z. Used for all overview/level/focus framing.
    func flyToOverview(of focus: SCNVector3, distance: Double = 18, height: Double = 11, duration: TimeInterval = 0.6) {
        cameraNode.removeAllActions()
        flightToken &+= 1
        let token = flightToken
        velocity = .zero
        let target = SCNVector3(focus.x, CGFloat(height), focus.z + CGFloat(distance))
        let newYaw: Double = 0
        let dx = Double(focus.x - target.x)
        let dy = Double(focus.y - target.y)
        let dz = Double(focus.z - target.z)
        let horiz = sqrt(dx * dx + dz * dz)
        let newPitch = atan2(dy, horiz)

        let move = SCNAction.move(to: target, duration: duration)
        move.timingMode = .easeInEaseOut
        let rotate = SCNAction.rotateTo(
            x: CGFloat(newPitch),
            y: CGFloat(newYaw),
            z: 0,
            duration: duration,
            usesShortestUnitArc: true
        )
        rotate.timingMode = .easeInEaseOut
        cameraNode.runAction(.group([move, rotate])) { [weak self] in
            Task { @MainActor in
                // Only sync state if this flight wasn't superseded or interrupted.
                guard let self, self.flightToken == token else { return }
                self.yaw = newYaw
                self.pitch = newPitch
            }
        }
    }

    // MARK: - Input

    /// Track a pressed movement key. Returns true if the event was a movement key
    /// (so the host can swallow it); Command-modified keys are ignored.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return false }
        boost = event.modifierFlags.contains(.shift)
        let code = event.keyCode
        if Self.movementKeyCodes.contains(code) {
            // Movement keys take over from any in-flight framing animation.
            if heldKeys.isEmpty { cancelFlight() }
            heldKeys.insert(code)
            return true
        }
        return false
    }

    /// Release a movement key. Returns true if it was a movement key.
    func handleKeyUp(_ event: NSEvent) -> Bool {
        boost = event.modifierFlags.contains(.shift)
        heldKeys.remove(event.keyCode)
        return Self.movementKeyCodes.contains(event.keyCode)
    }

    /// Update the speed-boost state when modifier flags change (Shift held).
    func handleFlagsChanged(_ event: NSEvent) {
        boost = event.modifierFlags.contains(.shift)
    }

    func handleMouseDrag(deltaX: CGFloat, deltaY: CGFloat) {
        // Manual input is authoritative: cancel any in-flight focus animation and
        // recover the live orientation so the look delta applies from where the
        // camera actually is (not a stale pre-flight angle).
        cancelFlight()
        yaw -= Double(deltaX) * lookSensitivity
        pitch -= Double(deltaY) * lookSensitivity
        pitch = max(-.pi / 2 + 0.05, min(.pi / 2 - 0.05, pitch))
        applyOrientation()
    }

    func handleScroll(deltaY: CGFloat) {
        // Cancel any in-flight focus animation (recovering live orientation) so the
        // dolly takes over immediately and moves along the correct view direction.
        cancelFlight()
        // Move forward/back along view direction
        let forward = forwardVector()
        let step = Double(deltaY) * scrollSpeed
        cameraNode.position = SCNVector3(
            CGFloat(Double(cameraNode.position.x) + forward.x * step),
            CGFloat(Double(cameraNode.position.y) + forward.y * step),
            CGFloat(Double(cameraNode.position.z) + forward.z * step)
        )
    }

    // MARK: - Per-frame update

    /// Per-frame integrator: accumulates held-key input into a smoothed velocity and
    /// advances the camera position (with damping when no keys are held).
    private func tick() {
        let now = CACurrentMediaTime()
        let dt: Double
        if lastTick == 0 {
            dt = 1.0 / 60.0
        } else {
            dt = max(0.0001, min(0.1, now - lastTick))
        }
        lastTick = now

        // Build desired movement in camera-local axes
        var forward: Double = 0
        var strafe: Double = 0
        var lift: Double = 0
        if heldKeys.contains(Self.keyW) || heldKeys.contains(Self.arrowUp) { forward += 1 }
        if heldKeys.contains(Self.keyS) || heldKeys.contains(Self.arrowDown) { forward -= 1 }
        if heldKeys.contains(Self.keyA) || heldKeys.contains(Self.arrowLeft) { strafe -= 1 }
        if heldKeys.contains(Self.keyD) || heldKeys.contains(Self.arrowRight) { strafe += 1 }
        if heldKeys.contains(Self.keyE) { lift += 1 }
        if heldKeys.contains(Self.keyQ) { lift -= 1 }

        let len = sqrt(forward * forward + strafe * strafe + lift * lift)
        if len > 1 {
            forward /= len; strafe /= len; lift /= len
        }

        let speed = moveSpeed * (boost ? boostMultiplier : 1.0)
        let fwdVec = forwardVector()
        let rightVec = rightVector()

        let target = SIMD3<Double>(
            (fwdVec.x * forward + rightVec.x * strafe) * speed,
            lift * speed,
            (fwdVec.z * forward + rightVec.z * strafe) * speed
        )

        // If no input, decay velocity. Otherwise lerp toward target.
        if len < 0.001 {
            let decay = exp(-damping * dt)
            velocity *= decay
        } else {
            let blend = 1 - exp(-smoothing * dt)
            velocity += (target - velocity) * blend
        }

        // Apply
        if simd_length_squared(velocity) > 1e-8 {
            let pos = cameraNode.position
            cameraNode.position = SCNVector3(
                CGFloat(Double(pos.x) + velocity.x * dt),
                CGFloat(Double(pos.y) + velocity.y * dt),
                CGFloat(Double(pos.z) + velocity.z * dt)
            )
        }
    }

    // MARK: - Helpers

    /// Push the current yaw/pitch onto the camera node's Euler angles.
    private func applyOrientation() {
        cameraNode.eulerAngles = SCNVector3(CGFloat(pitch), CGFloat(yaw), 0)
    }

    /// World-space forward (view) direction for the current yaw/pitch.
    private func forwardVector() -> SIMD3<Double> {
        // SceneKit camera looks down -Z in its local space.
        let cy = cos(yaw), sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        return SIMD3<Double>(-sy * cp, sp, -cy * cp)
    }

    /// World-space right (strafe) direction for the current yaw.
    private func rightVector() -> SIMD3<Double> {
        let cy = cos(yaw), sy = sin(yaw)
        return SIMD3<Double>(cy, 0, -sy)
    }

    // MARK: - Key codes (US ANSI)

    static let keyA: UInt16 = 0
    static let keyS: UInt16 = 1
    static let keyD: UInt16 = 2
    static let keyW: UInt16 = 13
    static let keyQ: UInt16 = 12
    static let keyE: UInt16 = 14
    static let arrowLeft: UInt16 = 123
    static let arrowRight: UInt16 = 124
    static let arrowDown: UInt16 = 125
    static let arrowUp: UInt16 = 126

    static let movementKeyCodes: Set<UInt16> = [
        keyW, keyA, keyS, keyD, keyQ, keyE,
        arrowUp, arrowDown, arrowLeft, arrowRight,
    ]
}

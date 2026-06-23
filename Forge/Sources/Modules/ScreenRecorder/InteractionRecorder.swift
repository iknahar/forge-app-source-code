import AppKit
import QuartzCore

// MARK: - Serializable track (the input to the Phase 3b auto-zoom engine)

/// One sampled interaction during a recording. `t` is **active** seconds since
/// record start (paused time already removed, so it aligns with the retimed
/// video). `(x, y)` is `NSEvent.mouseLocation` — global screen coords with a
/// **bottom-left** origin (the render engine flips to the video's top-left).
struct InteractionEvent: Codable {
    enum Kind: String, Codable { case move, leftClick, rightClick, scroll }
    let t: Double
    let x: Double
    let y: Double
    let kind: Kind
}

/// One sample of the live camera-bubble geometry during recording. `t` is
/// **active** seconds (same clock as InteractionEvent). `(x, y)` is the bubble
/// CENTER in global bottom-left screen points (like `mouseLocation`); `h` is the
/// bubble height in points. The editor normalizes these to the canvas exactly
/// like cursor coords, so the avatar lands where the user actually had it.
struct CameraKeyframe: Codable {
    let t: Double
    let x: Double
    let y: Double
    let h: Double
}

/// Sidecar written next to the `.mov` as `<movie>.forgerec.json`. Everything
/// the auto-zoom render pass + editor need to reconstruct the camera path.
struct InteractionTrack: Codable {
    let screenWidth: Double
    let screenHeight: Double
    let scale: Double
    let duration: Double
    let events: [InteractionEvent]
    /// Live avatar (webcam bubble) movement/resize path. Optional for sidecars
    /// written before this feature existed.
    var cameraKeyframes: [CameraKeyframe]? = nil
    /// Spans (active seconds, `[start, end]`) where the camera was toggled OFF
    /// during recording — the editor/export omit the avatar for these.
    var cameraOffSpans: [[Double]]? = nil
    /// Global BOTTOM-LEFT origin (points) of the captured canvas, in the same
    /// space as event x/y (NSEvent.mouseLocation). (0,0) for a full PRIMARY
    /// display. Optional → old sidecars decode as nil and are treated as (0,0).
    var originX: Double? = nil
    var originY: Double? = nil
}

// MARK: - Recorder

/// Captures the cursor/click timeline alongside the video. Mouse-only NSEvent
/// global monitors (no Accessibility needed). Active-time stamped so paused
/// spans don't appear in the track — matching the recorder's retimed video.
final class InteractionRecorder {

    private var events: [InteractionEvent] = []
    private var cameraKeyframes: [CameraKeyframe] = []
    private var cameraOffSpans: [[Double]] = []
    private var cameraOffStart: Double?
    private var monitors: [Any] = []
    private var startTime: CFTimeInterval = 0
    private var pausedAccum: Double = 0
    private var pauseStartedAt: CFTimeInterval?
    private var lastMoveT: Double = -1
    private let lock = NSLock()

    /// Begin sampling. Must be called on the main thread (NSEvent monitors).
    func start() {
        lock.lock(); events.removeAll(); cameraKeyframes.removeAll()
        cameraOffSpans.removeAll(); cameraOffStart = nil; lock.unlock()
        pausedAccum = 0
        pauseStartedAt = nil
        lastMoveT = -1
        startTime = CACurrentMediaTime()

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .leftMouseDown, .rightMouseDown, .scrollWheel,
        ]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] ev in
            self?.handle(ev)
        }) {
            monitors.append(m)
        }
    }

    func pause() { if pauseStartedAt == nil { pauseStartedAt = CACurrentMediaTime() } }

    func resume() {
        if let s = pauseStartedAt {
            pausedAccum += CACurrentMediaTime() - s
            pauseStartedAt = nil
        }
    }

    /// Stop monitoring and return the finished track. `screen`/`scale` describe
    /// the recorded display so the render engine can map coords → pixels.
    func finish(screenSize: CGSize, scale: CGFloat, origin: CGPoint = .zero) -> InteractionTrack {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        let dur = activeTime()
        lock.lock()
        let snapshot = events; let cam = cameraKeyframes
        if let s = cameraOffStart { cameraOffSpans.append([s, max(s, dur)]); cameraOffStart = nil }
        let off = cameraOffSpans
        lock.unlock()
        return InteractionTrack(
            screenWidth: Double(screenSize.width),
            screenHeight: Double(screenSize.height),
            scale: Double(scale),
            duration: max(0, dur),
            events: snapshot,
            cameraKeyframes: cam.isEmpty ? nil : cam,
            cameraOffSpans: off.isEmpty ? nil : off,
            originX: Double(origin.x),
            originY: Double(origin.y)
        )
    }

    /// Mark the camera as toggled OFF (begins an off-span at the current time).
    func cameraOff() {
        guard pauseStartedAt == nil else { return }
        lock.lock(); if cameraOffStart == nil { cameraOffStart = activeTime() }; lock.unlock()
    }
    /// Mark the camera as toggled back ON (closes the open off-span).
    func cameraOn() {
        lock.lock()
        if let s = cameraOffStart { cameraOffSpans.append([s, activeTime()]); cameraOffStart = nil }
        lock.unlock()
    }

    /// Record the live camera bubble's geometry at the current active time.
    /// `centerX/centerY` = bubble centre in global bottom-left screen points;
    /// `height` = bubble height in points. Ignored while paused.
    func recordCameraKeyframe(centerX: Double, centerY: Double, height: Double) {
        guard pauseStartedAt == nil else { return }
        let t = activeTime()
        lock.lock()
        cameraKeyframes.append(CameraKeyframe(t: max(0, t), x: centerX, y: centerY, h: height))
        lock.unlock()
    }

    // MARK: - Internals

    private func activeTime() -> Double {
        (CACurrentMediaTime() - startTime) - pausedAccum
    }

    private func handle(_ ev: NSEvent) {
        guard pauseStartedAt == nil else { return }   // ignore while paused
        let t = activeTime()
        let kind: InteractionEvent.Kind
        switch ev.type {
        case .leftMouseDown:  kind = .leftClick
        case .rightMouseDown: kind = .rightClick
        case .scrollWheel:    kind = .scroll
        default:                                       // moves / drags
            if lastMoveT >= 0, t - lastMoveT < 1.0 / 60.0 { return }  // ~60Hz throttle
            lastMoveT = t
            kind = .move
        }
        let p = NSEvent.mouseLocation
        lock.lock()
        events.append(InteractionEvent(t: t, x: Double(p.x), y: Double(p.y), kind: kind))
        lock.unlock()
    }
}

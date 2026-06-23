import SwiftUI
import AppKit
import AVKit
import AVFoundation
import Combine
import CoreImage

// =====================================================================================
// RecordingEditor — manual, box-based zoom editor for Forge screen recordings.
//
// The user ADDS zoom segments (none exist initially). Each segment defines a time range
// [start, end] and a NORMALIZED box (0..1, TOP-LEFT origin) in the VIDEO's space — the
// region to zoom INTO. The box is defined by dragging a rectangle directly on the
// preview; it is aspect-locked to the video and clamped to [0,1].
//
//   box -> ZoomKeyframe:  scale = 1 / box.side  (box is aspect-locked so w == h frac),
//                         focus = box center.   scale clamped 1.0...4.0.
//
// Auto-zoom is OPT-IN: it calls ZoomPlanner.plan and converts keyframes into segments.
//
// Out of scope (left as // TODO hooks): speed/crop/trim, image backgrounds,
// aspect-ratio canvas, cursor styling.
// =====================================================================================

enum RecordingEditor {

    /// Window controllers are retained here so the editor window survives. Each
    /// controller removes itself from this array when its window closes.
    private static var controllers: [EditorWindowController] = []

    static func open(movieURL: URL, track: InteractionTrack, cameraURL: URL? = nil) {
        let controller = EditorWindowController(movieURL: movieURL, track: track, cameraURL: cameraURL) { closed in
            controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Window controller (strong retention + teardown)

final class EditorWindowController: NSWindowController, NSWindowDelegate {

    private let onClose: (EditorWindowController) -> Void
    private let playerHolder: PlayerHolder

    init(movieURL: URL, track: InteractionTrack, cameraURL: URL? = nil,
         onClose: @escaping (EditorWindowController) -> Void) {
        self.onClose = onClose

        // Establish a duration: prefer the asset's real duration, fall back to track.
        let asset = AVURLAsset(url: movieURL)
        let assetDuration = CMTimeGetSeconds(asset.duration)
        let duration = (assetDuration.isFinite && assetDuration > 0) ? assetDuration
                       : max(0.1, track.duration)

        // Bug-fix (preview aspect): derive the preview aspect from the asset's REAL
        // video track (natural size corrected by its preferredTransform) so the
        // letterbox rect used for hit-testing / box overlay matches exactly where
        // AVPlayerLayer (.resizeAspect) actually draws the video — and matches the
        // renderer, which computes its renderSize the same way. Only fall back to the
        // interaction track's screen dimensions when the video track is unavailable.
        var previewAspect: CGFloat = 0
        if let vTrack = asset.tracks(withMediaType: .video).first {
            let natural = vTrack.naturalSize
            let display = CGRect(origin: .zero, size: natural).applying(vTrack.preferredTransform)
            let w = abs(display.width)
            let h = abs(display.height)
            if w > 0, h > 0 { previewAspect = w / h }
        }

        let holder = PlayerHolder(movieURL: movieURL, cameraURL: cameraURL)
        self.playerHolder = holder

        let state = EditorState(duration: duration, track: track, videoAspect: previewAspect)
        state.cameraURL = cameraURL

        let rootView = EditorRootView(
            movieURL: movieURL,
            track: track,
            state: state,
            playerHolder: holder
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Recording"
        window.isReleasedWhenClosed = false   // we manage lifetime explicitly
        window.minSize = NSSize(width: 940, height: 620)
        window.contentView = NSHostingView(rootView: rootView)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func windowWillClose(_ notification: Notification) {
        // Tear down AVPlayer to stop playback / free decode resources. teardown()
        // removes the periodic time observer FIRST (before dropping the item), so
        // observer removal is deterministic regardless of whether .onDisappear fires.
        playerHolder.teardown()
        onClose(self)
    }
}

// MARK: - Player holder (owns the AVPlayer AND its time observer; tears both down)

final class PlayerHolder: ObservableObject {
    let player: AVPlayer
    let sourceAsset: AVURLAsset
    /// Separate player for the webcam overlay (muted; driven by the playhead).
    let cameraPlayer: AVPlayer?

    // Observer ownership lives here so removal is tied to the player's lifetime,
    // not the SwiftUI view lifecycle. Removed in teardown() BEFORE the item is
    // dropped — Apple requires removeTimeObserver before releasing the player.
    private var timeObserver: Any?

    init(movieURL: URL, cameraURL: URL? = nil) {
        self.sourceAsset = AVURLAsset(url: movieURL)
        self.player = AVPlayer()
        self.player.actionAtItemEnd = .pause
        if let cameraURL {
            let cp = AVPlayer(url: cameraURL)
            cp.isMuted = true
            cp.actionAtItemEnd = .pause
            self.cameraPlayer = cp
        } else {
            self.cameraPlayer = nil
        }
    }

    /// Swap the player to the EDITED timeline (cuts removed + speed baked) so
    /// playback is continuous — no seeking to skip cuts. Identity edits play the
    /// source directly. Called on load and whenever the timeline changes.
    func loadEdited(pieces: [EditPiece], sourceDuration: Double) {
        let item: AVPlayerItem
        if pieces.isEmpty || EditTimeline.isIdentity(pieces, sourceDuration: sourceDuration) {
            item = AVPlayerItem(asset: sourceAsset)
        } else if let (comp, _) = EditTimeline.composition(source: sourceAsset, pieces: pieces) {
            item = AVPlayerItem(asset: comp)
        } else {
            item = AVPlayerItem(asset: sourceAsset)
        }
        item.audioTimePitchAlgorithm = .spectral   // preserve pitch at non-1× speed
        player.replaceCurrentItem(with: item)
    }

    /// Register a periodic time observer, storing the token so teardown can remove
    /// it exactly once. Idempotent: a second call while one exists is a no-op.
    func addPlayheadObserver(interval: CMTime, queue: DispatchQueue = .main,
                             handler: @escaping (CMTime) -> Void) {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: queue, using: handler)
    }

    /// Remove the observer if present. Safe to call multiple times.
    func removePlayheadObserver() {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
    }

    func teardown() {
        removePlayheadObserver()       // MUST precede replaceCurrentItem(nil)
        player.pause()
        player.replaceCurrentItem(with: nil)
        cameraPlayer?.pause()
        cameraPlayer?.replaceCurrentItem(with: nil)
    }
}

// MARK: - Zoom model

struct ZoomSegment: Identifiable, Equatable {
    let id: UUID
    var start: Double          // seconds on the timeline
    var end: Double            // seconds on the timeline
    var box: CGRect            // NORMALIZED 0..1 in the video's space, TOP-LEFT origin

    init(id: UUID = UUID(), start: Double, end: Double, box: CGRect) {
        self.id = id
        self.start = start
        self.end = end
        self.box = box
    }

    /// Effective scale derived from the (aspect-locked) box. Clamped 1...4.
    var scale: CGFloat {
        let side = max(0.0001, max(box.width, box.height))
        return min(4.0, max(1.0, 1.0 / side))
    }

    var focus: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

// MARK: - Speed model

/// A time range of the ORIGINAL recording played at `factor`× (e.g. 0.5 = half
/// speed, 2 = double). Ranges not covered by any segment play at the global
/// `EditorState.speed`. Times are in source seconds.
struct SpeedSegment: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
    var factor: Double

    init(id: UUID = UUID(), start: Double, end: Double, factor: Double) {
        self.id = id
        self.start = start
        self.end = end
        self.factor = factor
    }
}

// MARK: - Cut model

/// A removed span of the ORIGINAL recording (source seconds). Multiple cuts can
/// be placed anywhere; the output is the recording minus every cut. The cut's
/// duration is `end - start` and is adjustable.
struct CutRange: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
    init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = start
        self.end = end
    }
}

// MARK: - Spotlight model

/// Highlight a region for a time span: everything outside `box` is dimmed.
/// `box` is normalized (0..1, TOP-LEFT) in the video's space.
struct SpotlightSegment: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
    var box: CGRect
    var dim: CGFloat       // how dark the surround is (mask opacity), 0...1
    var roundness: CGFloat // corner radius as a fraction of the box's short side, 0...0.5
    var feather: CGFloat   // soft-edge radius in normalized units (× short side), 0...0.5
    init(id: UUID = UUID(), start: Double, end: Double, box: CGRect,
         dim: CGFloat = 0.55, roundness: CGFloat = 0.12, feather: CGFloat = 0.04) {
        self.id = id; self.start = start; self.end = end; self.box = box
        self.dim = dim; self.roundness = roundness; self.feather = feather
    }
}

// MARK: - Blur model

/// Blur/redact a region for a time span. `box` is normalized (0..1, TOP-LEFT).
/// `strength` 0..1 scales the blur radius.
struct BlurSegment: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
    var box: CGRect
    var strength: CGFloat
    var roundness: CGFloat // corner radius as a fraction of the box's short side, 0...0.5
    init(id: UUID = UUID(), start: Double, end: Double, box: CGRect,
         strength: CGFloat = 0.6, roundness: CGFloat = 0.08) {
        self.id = id; self.start = start; self.end = end; self.box = box
        self.strength = strength; self.roundness = roundness
    }
}

// MARK: - Camera path

/// A normalized avatar (webcam bubble) keyframe in the editor's canvas space.
/// `t` is SOURCE seconds; `center` is the bubble centre (top-left origin, 0..1);
/// `h` is the bubble height as a fraction of canvas height. Built from the
/// recorded CameraKeyframe sidecar so the editor replays the live movement.
struct CameraKey: Equatable {
    var t: Double
    var center: CGPoint
    var h: CGFloat
}

// MARK: - Remembered effect settings

/// Persists the user's last-tweaked effect appearance so newly added effects
/// adopt their preferences instead of hard-coded defaults.
enum RecorderDefaults {
    private static let ud = UserDefaults.standard
    private static func get(_ k: String, _ d: CGFloat) -> CGFloat {
        ud.object(forKey: k) == nil ? d : CGFloat(ud.double(forKey: k))
    }
    private static func set(_ k: String, _ v: CGFloat) { ud.set(Double(v), forKey: k) }

    static var spotlightDim: CGFloat { get { get("forge.spot.dim", 0.55) } set { set("forge.spot.dim", newValue) } }
    static var spotlightRoundness: CGFloat { get { get("forge.spot.round", 0.12) } set { set("forge.spot.round", newValue) } }
    static var spotlightFeather: CGFloat { get { get("forge.spot.feather", 0.04) } set { set("forge.spot.feather", newValue) } }
    static var blurStrength: CGFloat { get { get("forge.blur.strength", 0.6) } set { set("forge.blur.strength", newValue) } }
    static var blurRoundness: CGFloat { get { get("forge.blur.round", 0.08) } set { set("forge.blur.round", newValue) } }
    static var zoomSide: CGFloat { get { get("forge.zoom.side", 0.5) } set { set("forge.zoom.side", min(0.95, max(0.2, newValue))) } }
}

// MARK: - Movement feel

/// FocuSee-style motion presets. For zoom/pan this sets the ramp duration
/// (longer = slower, smoother glide); for the cursor it sets the path-smoothing
/// time constant (larger = smoother, more follow-through).
enum MovementSpeed: String, CaseIterable, Identifiable {
    case slow, medium, fast, rapid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .slow: return "Slow"
        case .medium: return "Medium"
        case .fast: return "Fast"
        case .rapid: return "Rapid"
        }
    }
    /// Zoom/pan ramp in/out duration (seconds).
    var rampSeconds: Double {
        switch self {
        case .slow: return 0.9
        case .medium: return 0.6
        case .fast: return 0.4
        case .rapid: return 0.25
        }
    }
    /// Cursor smoothing time constant (seconds). 0 ≈ no smoothing.
    var cursorTau: Double {
        switch self {
        case .slow: return 0.20
        case .medium: return 0.10
        case .fast: return 0.05
        case .rapid: return 0.0
        }
    }
}

/// Camera bubble shape.
enum CameraShape: String, CaseIterable, Identifiable {
    case circle, rounded
    var id: String { rawValue }
    var title: String { self == .circle ? "Circle" : "Rounded" }
}

enum CameraLayout: String, CaseIterable, Identifiable {
    case bubble, fullscreen
    var id: String { rawValue }
    var title: String { self == .bubble ? "Bubble" : "Full screen" }
}

// MARK: - Background

enum EditorBackground: Equatable {
    case gradient(top: NSColor, bottom: NSColor, name: String)   // kept for back-compat (unused in picker)
    case solid(NSColor)
    case image(name: String, url: URL)
    case hidden

    /// The fixed 4-color palette offered in the editor (no custom picker).
    static let colorPresets: [NSColor] = [
        NSColor(srgbRed: 0.07, green: 0.09, blue: 0.15, alpha: 1), // Ink
        NSColor(srgbRed: 0.20, green: 0.22, blue: 0.28, alpha: 1), // Slate
        NSColor(srgbRed: 0.36, green: 0.20, blue: 0.86, alpha: 1), // Indigo
        NSColor(srgbRed: 0.996, green: 0.314, blue: 0.004, alpha: 1), // Strativ Orange
    ]

    /// Curated gradient presets (top → bottom) for the Gradient tab.
    static let gradientPresets: [EditorBackground] = [
        .gradient(top: NSColor(srgbRed: 0.45, green: 0.30, blue: 0.95, alpha: 1),
                  bottom: NSColor(srgbRed: 0.16, green: 0.10, blue: 0.40, alpha: 1), name: "Dusk"),
        .gradient(top: NSColor(srgbRed: 0.16, green: 0.72, blue: 0.92, alpha: 1),
                  bottom: NSColor(srgbRed: 0.10, green: 0.24, blue: 0.65, alpha: 1), name: "Ocean"),
        .gradient(top: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.30, alpha: 1),
                  bottom: NSColor(srgbRed: 0.92, green: 0.27, blue: 0.45, alpha: 1), name: "Sunset"),
        .gradient(top: NSColor(srgbRed: 0.30, green: 0.85, blue: 0.66, alpha: 1),
                  bottom: NSColor(srgbRed: 0.10, green: 0.42, blue: 0.40, alpha: 1), name: "Forest"),
        .gradient(top: NSColor(srgbRed: 0.92, green: 0.30, blue: 0.70, alpha: 1),
                  bottom: NSColor(srgbRed: 0.40, green: 0.16, blue: 0.55, alpha: 1), name: "Berry"),
        .gradient(top: NSColor(srgbRed: 0.42, green: 0.46, blue: 0.55, alpha: 1),
                  bottom: NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1), name: "Slate"),
    ]

    /// Up to 10 background images: bundled `RecordingBackgrounds/` + the user
    /// drop-in folder `~/Library/Application Support/Forge/Backgrounds/`.
    /// No upload UI — these two folders are the only sources.
    static func loadImagePresets() -> [EditorBackground] {
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff"]
        var urls: [URL] = []
        func scan(_ dir: URL?) {
            guard let dir = dir,
                  let items = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil) else { return }
            urls += items.filter { exts.contains($0.pathExtension.lowercased()) }
        }
        if let res = Bundle.main.resourceURL {
            scan(res.appendingPathComponent("RecordingBackgrounds"))
        }
        if let appSup = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first {
            scan(appSup.appendingPathComponent("Forge/Backgrounds"))
        }
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return sorted.prefix(16).map {
            .image(name: $0.deletingPathExtension().lastPathComponent, url: $0)
        }
    }

    var displayName: String {
        switch self {
        case .gradient(_, _, let name): return name
        case .solid: return "Color"
        case .image(let name, _): return name
        case .hidden: return "None"
        }
    }
}

// MARK: - Editor state (ObservableObject)

final class EditorState: ObservableObject {

    @Published var segments: [ZoomSegment] = []        // starts EMPTY
    @Published var selectedSegmentID: UUID?
    /// Per-part speed regions (source-time). Empty = whole recording at `speed`.
    @Published var speedSegments: [SpeedSegment] = []
    @Published var selectedSpeedID: UUID?
    /// Removed spans (source-time). The output is the recording minus these.
    @Published var cuts: [CutRange] = []
    @Published var selectedCutID: UUID?
    /// Spotlight regions (dim around a box for a span).
    @Published var spotlights: [SpotlightSegment] = []
    @Published var selectedSpotlightID: UUID?
    /// Blur/redact regions.
    @Published var blurs: [BlurSegment] = []
    @Published var selectedBlurID: UUID?
    @Published var background: EditorBackground = .solid(EditorBackground.colorPresets[0])
    /// Up to 10 image backgrounds discovered at launch (bundled + user folder).
    @Published var imageBackgrounds: [EditorBackground] = EditorBackground.loadImagePresets()

    @Published var cornerRadius: CGFloat = 14
    @Published var padding: CGFloat = 0.06             // paddingFraction
    @Published var shadow: Bool = true
    /// Background blur (points in preview / scaled in export). Mainly affects
    /// wallpaper backgrounds; near-invisible on solids.
    @Published var backgroundBlur: CGFloat = 0

    // Synthetic cursor (the real one is hidden at capture). Drawn in preview +
    // export from `cursorSamples`. Scale multiplies a ~2%-of-height base.
    @Published var showCursor = true
    @Published var cursorScale: CGFloat = 2.0
    @Published var cursorStyle: CursorStyle = .dark
    @Published var clickEffect: ClickEffect = .ring
    @Published var hideCursorWhenIdle = false
    /// Cursor path (normalized top-left, source-time), built once from the track.
    let cursorSamples: [CursorSample]
    /// Click positions (source-time, normalized) for click effects.
    let clicks: [CursorSample]
    /// Times (source seconds) at which the cursor moved meaningfully (idle calc).
    private let moveTimes: [Double]
    private var cursorCGCache: (h: CGFloat, style: CursorStyle, cg: CGImage)?
    private var smoothedCache: (tau: Double, samples: [CursorSample])?

    /// Seconds of stillness after which an idle cursor is hidden.
    static let idleHideAfter: Double = 2.5

    // Movement feel (FocuSee-style). Zoom/pan ramp + cursor smoothing.
    @Published var zoomMovement: MovementSpeed = .medium
    @Published var cursorMovement: MovementSpeed = .medium

    /// Webcam recording + overlay bubble (Phase 2 preview; Phase 3 export).
    var cameraURL: URL?
    var hasCamera: Bool { cameraURL != nil }
    @Published var cameraVisible = true
    @Published var cameraShape: CameraShape = .circle
    @Published var cameraLayout: CameraLayout = .bubble
    /// Bubble centre (normalized in the canvas) + height (fraction of canvas height).
    /// When `cameraFollowsPath`, these are driven by `cameraPath` at the playhead;
    /// otherwise they are a fixed position the user set by dragging in the editor.
    @Published var cameraCenter = CGPoint(x: 0.85, y: 0.82)
    @Published var cameraHeightFrac: CGFloat = 0.17
    /// Recorded live-movement path (source time). Empty if the avatar never moved
    /// or the recording predates this feature.
    @Published var cameraPath: [CameraKey] = []
    /// When true, the avatar replays its recorded movement; a manual drag/resize
    /// in the editor switches this off (pins it to a fixed spot).
    @Published var cameraFollowsPath = false
    /// Source-time spans where the camera was toggled OFF during recording — the
    /// avatar is hidden in preview + omitted from export for these.
    @Published var cameraOffSpans: [(Double, Double)] = []

    /// Whether the avatar is visible at source time `t` (not inside an off-span).
    func cameraVisibleAt(_ t: Double) -> Bool {
        !cameraOffSpans.contains { t >= $0.0 && t < $0.1 }
    }

    func resetCameraPosition() {
        cameraCenter = CGPoint(x: 0.85, y: 0.82)
        cameraHeightFrac = 0.17
        cameraFollowsPath = false
    }

    /// Avatar geometry at source time `t`: interpolates the recorded path when
    /// following, else the fixed scalar position.
    func cameraSample(at t: Double) -> (center: CGPoint, h: CGFloat) {
        guard cameraFollowsPath, !cameraPath.isEmpty else { return (cameraCenter, cameraHeightFrac) }
        if t <= cameraPath.first!.t { let f = cameraPath.first!; return (f.center, f.h) }
        if t >= cameraPath.last!.t  { let l = cameraPath.last!;  return (l.center, l.h) }
        var lo = cameraPath[0]
        for k in cameraPath.dropFirst() {
            if k.t >= t {
                let span = k.t - lo.t
                let u = span > 1e-6 ? CGFloat((t - lo.t) / span) : 0
                return (CGPoint(x: lo.center.x + (k.center.x - lo.center.x) * u,
                                y: lo.center.y + (k.center.y - lo.center.y) * u),
                        lo.h + (k.h - lo.h) * u)
            }
            lo = k
        }
        let l = cameraPath.last!; return (l.center, l.h)
    }

    /// Pin the avatar to a fixed position (called when the user drags/resizes it
    /// in the editor) — stops following the recorded movement, holding wherever
    /// it currently is at the playhead.
    func pinCameraToCurrent() {
        guard cameraFollowsPath else { return }
        let g = cameraSample(at: playhead)
        cameraCenter = g.center
        cameraHeightFrac = g.h
        cameraFollowsPath = false
    }

    // Playback (preview transport). isPlaying mirrors the AVPlayer; the preview
    // applies live zoom only while playing so editing happens on a flat frame.
    @Published var isPlaying = false

    // Global playback speed multiplier applied to the whole recording.
    @Published var speed: Double = 1.0

    /// Bumped whenever the edited timeline changes structurally (cut/speed
    /// add/remove/commit). The editor rebuilds the playback composition on this.
    @Published private(set) var timelineRevision = 0
    func bumpTimeline() { timelineRevision &+= 1 }

    @Published var playhead: Double = 0

    /// True while the user is actively scrubbing the timeline. The periodic time
    /// observer suppresses its own writes to `playhead` while this is set, so the
    /// scrub gesture is the single writer during a drag (no backward stutter from
    /// stale async player time). Not @Published — it gates a writer, not the UI.
    var isScrubbing = false

    let duration: Double

    /// Aspect ratio (w/h) of the video, used to aspect-lock zoom boxes.
    let videoAspect: CGFloat

    // Undo/redo of the zoom + speed + cut lists (simple snapshot stacks).
    private struct EditSnapshot {
        var zoom: [ZoomSegment]; var speed: [SpeedSegment]; var cuts: [CutRange]
        var spotlights: [SpotlightSegment]; var blurs: [BlurSegment]
    }
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []

    // Coalescing token for per-control edits (steppers / nudge). While a token is
    // active, repeated edits from the SAME control reuse the single snapshot taken
    // when the token was opened, so one logical edit == one undo entry.
    private var activeEditToken: String?

    init(duration: Double, track: InteractionTrack, videoAspect: CGFloat = 0) {
        self.duration = max(0.1, duration)
        if videoAspect.isFinite, videoAspect > 0 {
            self.videoAspect = videoAspect
        } else if track.screenWidth > 0, track.screenHeight > 0 {
            self.videoAspect = CGFloat(track.screenWidth / track.screenHeight)
        } else {
            self.videoAspect = 16.0 / 9.0
        }
        // Cursor path: normalize global bottom-left screen coords → video
        // top-left (full-display assumption; region/window are approximate).
        let sw = track.screenWidth > 0 ? track.screenWidth : 1
        let sh = track.screenHeight > 0 ? track.screenHeight : 1
        // Global bottom-left origin of the captured canvas (0,0 for full primary
        // display). Subtracting it fixes region/secondary-display offset.
        let ox = track.originX ?? 0
        let oy = track.originY ?? 0
        func norm(_ e: InteractionEvent) -> CursorSample {
            CursorSample(t: e.t,
                         nx: Swift.min(1, Swift.max(0, (e.x - ox) / sw)),
                         ny: Swift.min(1, Swift.max(0, 1 - (e.y - oy) / sh)))
        }
        let samples = track.events.map(norm)
        self.cursorSamples = samples
        self.clicks = track.events.filter { $0.kind == .leftClick || $0.kind == .rightClick }.map(norm)
        // Times where the cursor actually moved (> ~0.3% of the frame) — for idle.
        var moves: [Double] = []
        var prev: CursorSample?
        for s in samples {
            if let p = prev, hypot(s.nx - p.nx, s.ny - p.ny) > 0.003 { moves.append(s.t) }
            prev = s
        }
        self.moveTimes = moves
        // Avatar (camera bubble) movement path — normalized the SAME way as the
        // cursor so it lands exactly where the user had it during recording.
        if let cam = track.cameraKeyframes, !cam.isEmpty {
            let path = cam.map { k in
                CameraKey(t: k.t,
                          center: CGPoint(x: Swift.min(1, Swift.max(0, (k.x - ox) / sw)),
                                          y: Swift.min(1, Swift.max(0, 1 - (k.y - oy) / sh))),
                          h: CGFloat(Swift.min(0.8, Swift.max(0.05, k.h / sh))))
            }.sorted { $0.t < $1.t }
            self.cameraPath = path
            self.cameraFollowsPath = true
            if let f = path.first { self.cameraCenter = f.center; self.cameraHeightFrac = f.h }
        }
        if let off = track.cameraOffSpans {
            self.cameraOffSpans = off.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        }
        // Open on the 6th wallpaper if available (13-ventura-light); else the
        // first; else the flat-colour fallback. After all stored props are
        // initialised (Swift requires this).
        if imageBackgrounds.indices.contains(5) {
            background = imageBackgrounds[5]
        } else if let firstWallpaper = imageBackgrounds.first {
            background = firstWallpaper
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var selectedSegment: ZoomSegment? {
        guard let id = selectedSegmentID else { return nil }
        return segments.first { $0.id == id }
    }

    // MARK: Mutation helpers (snapshot-based undo)

    private func snapshot() {
        undoStack.append(EditSnapshot(zoom: segments, speed: speedSegments, cuts: cuts,
                                      spotlights: spotlights, blurs: blurs))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(EditSnapshot(zoom: segments, speed: speedSegments, cuts: cuts,
                                      spotlights: spotlights, blurs: blurs))
        segments = prev.zoom
        speedSegments = prev.speed
        cuts = prev.cuts
        spotlights = prev.spotlights
        blurs = prev.blurs
        reconcileSelection()
        bumpTimeline()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(EditSnapshot(zoom: segments, speed: speedSegments, cuts: cuts,
                                      spotlights: spotlights, blurs: blurs))
        segments = next.zoom
        speedSegments = next.speed
        cuts = next.cuts
        spotlights = next.spotlights
        blurs = next.blurs
        reconcileSelection()
        bumpTimeline()
    }

    private func reconcileSelection() {
        if let id = selectedSegmentID, !segments.contains(where: { $0.id == id }) {
            selectedSegmentID = nil
        }
        if let id = selectedSpeedID, !speedSegments.contains(where: { $0.id == id }) {
            selectedSpeedID = nil
        }
        if let id = selectedCutID, !cuts.contains(where: { $0.id == id }) {
            selectedCutID = nil
        }
        if let id = selectedSpotlightID, !spotlights.contains(where: { $0.id == id }) {
            selectedSpotlightID = nil
        }
        if let id = selectedBlurID, !blurs.contains(where: { $0.id == id }) {
            selectedBlurID = nil
        }
    }

    // MARK: Commands

    /// Adds a default 1.5s zoom block at the playhead with a centered 60% box
    /// (aspect-locked to the video, so width == height as a fraction).
    func addZoomSegment(at playhead: Double) {
        snapshot()
        let block = makeDefaultBlock(at: playhead)
        let frac = RecorderDefaults.zoomSide
        let box = CGRect(x: (1 - frac) / 2, y: (1 - frac) / 2, width: frac, height: frac)
        let seg = ZoomSegment(start: block.start, end: block.end, box: box)
        segments.append(seg)
        segments.sort { $0.start < $1.start }
        clearSelection(); selectedSegmentID = seg.id
    }

    /// Computes a default ~1.5s block anchored at the playhead, clamped to timeline.
    func makeDefaultBlock(at playhead: Double) -> (start: Double, end: Double) {
        let blockLen = 1.5
        var start = max(0, min(playhead, duration))
        var end = start + blockLen
        if end > duration { end = duration; start = max(0, end - blockLen) }
        if end <= start { end = min(duration, start + 0.1) }
        return (start, end)
    }

    /// Append a fully-built segment (used by the preview's drag-to-create) with a
    /// single undo snapshot, then select it.
    func addSegment(_ seg: ZoomSegment) {
        snapshot()
        var s = seg
        s.box = clampAspectLockedBox(seg.box)
        segments.append(s)
        segments.sort { $0.start < $1.start }
        clearSelection(); selectedSegmentID = s.id
        RecorderDefaults.zoomSide = s.box.width
    }

    /// Replaces the box of a segment, kept aspect-locked & clamped. NO snapshot —
    /// call during a live drag (snapshot once at drag start via beginEdit()).
    func updateBox(for id: UUID, to box: CGRect) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[idx].box = clampAspectLockedBox(box)
        RecorderDefaults.zoomSide = segments[idx].box.width   // remember zoom level
    }

    /// Push an undo snapshot then set the box once (e.g. inspector nudge).
    /// `editToken`, when supplied, coalesces consecutive calls from the same control
    /// (e.g. repeated nudge clicks) into a SINGLE undo entry.
    func commitBox(for id: UUID, to box: CGRect, editToken: String? = nil) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        snapshotForToken(editToken)
        segments[idx].box = clampAspectLockedBox(box)
    }

    func updateTiming(for id: UUID, start: Double, end: Double, snapshotFirst: Bool) {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else { return }
        if snapshotFirst { snapshot() }
        var s = max(0, min(start, duration))
        var e = max(0, min(end, duration))
        if e <= s { e = min(duration, s + 0.1); if e <= s { s = max(0, e - 0.1) } }
        segments[idx].start = s
        segments[idx].end = e
    }

    /// Timing edit that coalesces consecutive changes from the same control
    /// (a held/clicked Stepper) into one undo entry via `editToken`.
    func updateTiming(for id: UUID, start: Double, end: Double, editToken: String) {
        snapshotForToken(editToken)
        updateTiming(for: id, start: start, end: end, snapshotFirst: false)
    }

    /// Take an undo snapshot before an interactive edit (drag begin). Drag gestures
    /// end the coalescing window so the NEXT control starts a fresh undo entry.
    func beginEdit() {
        activeEditToken = nil
        snapshot()
    }

    /// Snapshot only when starting a NEW coalescing window (token differs from the
    /// active one). Repeated calls with the same token reuse the existing snapshot,
    /// collapsing a burst of stepper/nudge steps into a single undo entry. A nil
    /// token always snapshots (one-shot edit).
    private func snapshotForToken(_ token: String?) {
        guard let token else { activeEditToken = nil; snapshot(); return }
        if activeEditToken != token {
            activeEditToken = token
            snapshot()
        }
    }

    /// Close the current coalescing window (call when a control commits / loses
    /// focus). The next edit — even from the same control — starts a new undo entry.
    func endCoalescing() { activeEditToken = nil }

    func deleteSelected() {
        guard let id = selectedSegmentID,
              segments.contains(where: { $0.id == id }) else { return }
        endCoalescing()
        snapshot()
        segments.removeAll { $0.id == id }
        selectedSegmentID = nil
    }

    func resetTimeline() {
        guard !segments.isEmpty || !speedSegments.isEmpty || !cuts.isEmpty
            || !spotlights.isEmpty || !blurs.isEmpty else { return }
        endCoalescing()
        snapshot()
        segments.removeAll()
        speedSegments.removeAll()
        cuts.removeAll()
        spotlights.removeAll()
        blurs.removeAll()
        selectedSegmentID = nil
        selectedSpeedID = nil
        selectedCutID = nil
        selectedSpotlightID = nil
        selectedBlurID = nil
        bumpTimeline()
    }

    /// Auto-zoom on CLICK: one zoom segment per click (clusters of clicks within
    /// `mergeGap` collapse into one), centered on where you clicked, at ~2× for
    /// ~1.5s. Every segment is an ordinary ZoomSegment, so it's fully
    /// reshapeable (drag the box) + duration-editable (drag the block / steppers).
    func autoZoom(from track: InteractionTrack) {
        guard !clicks.isEmpty else { return }
        endCoalescing()
        snapshot()
        segments.removeAll()
        selectedSegmentID = nil

        let mergeGap = 0.8          // clicks closer than this share one zoom
        let holdLen = 1.5           // seconds the zoom holds after the last click
        let frac: CGFloat = RecorderDefaults.zoomSide   // remembered zoom level
        let sorted = clicks.sorted { $0.t < $1.t }

        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1].t - sorted[j].t < mergeGap { j += 1 }

            let cluster = sorted[i...j]
            let cx = cluster.map { $0.nx }.reduce(0, +) / Double(cluster.count)
            let cy = cluster.map { $0.ny }.reduce(0, +) / Double(cluster.count)
            let startT = max(0, min(sorted[i].t, duration))
            var endT = min(duration, sorted[j].t + holdLen)
            if endT <= startT { endT = min(duration, startT + 0.3) }

            let box = clampAspectLockedBox(
                CGRect(x: CGFloat(cx) - frac / 2, y: CGFloat(cy) - frac / 2, width: frac, height: frac))
            if endT > startT {
                segments.append(ZoomSegment(start: startT, end: endT, box: box))
            }
            i = j + 1
        }
        segments.sort { $0.start < $1.start }
    }

    // MARK: Keyframe expansion

    /// Expand segments into a strictly-increasing keyframe path spanning [0, duration].
    ///
    /// Overlapping / adjacent segments are first COALESCED into non-overlapping groups
    /// (any two whose [start,end] windows, expanded by `ramp` on each side, touch are
    /// merged, taking the max-scale segment's scale + focus). This prevents the camera
    /// from collapsing to full-frame and recentering in the MIDDLE of an active zoom —
    /// the failure mode of the old per-segment 4-keyframe emission for overlaps.
    ///
    /// Per group: ramp-in (scale 1, CENTERED) -> start (scale@focus) -> hold (end,
    /// scale@focus) -> ramp-out (scale 1, centered). Ramps are clamped so they never
    /// cross into a neighbouring group. Outside groups the camera rests at scale 1
    /// centered.
    func buildKeyframes() -> [ZoomKeyframe] {
        let cx: CGFloat = 0.5
        let cy: CGFloat = 0.5

        func restingPath() -> [ZoomKeyframe] {
            [ZoomKeyframe(t: 0, scale: 1, focusX: cx, focusY: cy),
             ZoomKeyframe(t: duration, scale: 1, focusX: cx, focusY: cy)]
        }

        guard !segments.isEmpty else { return restingPath() }

        let ramp = zoomMovement.rampSeconds   // Slow/Med/Fast/Rapid → gentler↔snappier

        // Normalize + sort segments (clamped to timeline, positive length).
        let normalized: [ZoomSegment] = segments.compactMap { seg in
            let start = max(0, min(seg.start, duration))
            let end = max(0, min(seg.end, duration))
            guard end > start else { return nil }
            return ZoomSegment(id: seg.id, start: start, end: end, box: seg.box)
        }.sorted { $0.start < $1.start }

        guard !normalized.isEmpty else { return restingPath() }

        // ── Coalesce overlapping / ramp-adjacent segments into groups ─────────
        struct Group { var start: Double; var end: Double; var scale: CGFloat; var focus: CGPoint }
        var groups: [Group] = []
        for seg in normalized {
            if var last = groups.last,
               // Two segments whose ramp-expanded windows touch must merge, else
               // one's ramp-out (scale 1) would land inside the other's hold.
               seg.start <= last.end + 2 * ramp {
                last.end = max(last.end, seg.end)
                if seg.scale > last.scale { last.scale = seg.scale; last.focus = seg.focus }
                groups[groups.count - 1] = last
            } else {
                groups.append(Group(start: seg.start, end: seg.end,
                                    scale: seg.scale, focus: seg.focus))
            }
        }

        // ── Emit keyframes, clamping ramps so they never cross a neighbour ────
        var kfs: [ZoomKeyframe] = []
        kfs.append(ZoomKeyframe(t: 0, scale: 1, focusX: cx, focusY: cy))

        for (gi, g) in groups.enumerated() {
            let prevEnd = (gi > 0) ? groups[gi - 1].end : 0
            let nextStart = (gi + 1 < groups.count) ? groups[gi + 1].start : duration

            // Ramp-in cannot reach before prevEnd (split the available gap).
            let inRamp = min(ramp, max(0, (g.start - prevEnd) / 2))
            let rampInStart = max(0, g.start - inRamp)

            // Ramp-out cannot reach past nextStart (split the available gap).
            let outRamp = min(ramp, max(0, (nextStart - g.end) / 2))
            let rampOutEnd = min(duration, g.end + outRamp)

            // Scale-1 ramp anchors are CENTERED (matching the resting state and the
            // ramp-out); focus then interpolates from center toward the box focus as
            // scale ramps 1 -> s. This keeps ramp-in and ramp-out symmetric and avoids
            // a sideways drift of a full-frame image before any zoom occurs.
            kfs.append(ZoomKeyframe(t: rampInStart, scale: 1, focusX: cx, focusY: cy))
            kfs.append(ZoomKeyframe(t: g.start, scale: g.scale, focusX: g.focus.x, focusY: g.focus.y))
            kfs.append(ZoomKeyframe(t: g.end, scale: g.scale, focusX: g.focus.x, focusY: g.focus.y))
            kfs.append(ZoomKeyframe(t: rampOutEnd, scale: 1, focusX: cx, focusY: cy))
        }

        if let last = kfs.last, last.t < duration {
            kfs.append(ZoomKeyframe(t: duration, scale: 1, focusX: cx, focusY: cy))
        }

        return dedupeMonotonic(kfs.sorted { $0.t < $1.t })
    }

    // MARK: Live camera (preview)

    /// Interpolated camera (scale + focus, normalized TOP-LEFT) at time `t`,
    /// derived from the SAME keyframe path the renderer uses, so the live
    /// preview matches the exported zoom. Smoothstep eases each segment to
    /// approximate the renderer's cubic interpolation.
    func camera(at t: Double) -> (scale: CGFloat, fx: CGFloat, fy: CGFloat) {
        let kfs = buildKeyframes()
        guard let first = kfs.first else { return (1, 0.5, 0.5) }
        if t <= first.t { return (first.scale, first.focusX, first.focusY) }
        if let last = kfs.last, t >= last.t { return (last.scale, last.focusX, last.focusY) }
        for i in 0..<(kfs.count - 1) {
            let a = kfs[i], b = kfs[i + 1]
            if t >= a.t, t <= b.t {
                let span = b.t - a.t
                let f = span > 0 ? (t - a.t) / span : 0
                let e = CGFloat(f * f * f * (f * (f * 6 - 15) + 10))   // smootherstep (quintic)
                return (a.scale + (b.scale - a.scale) * e,
                        a.focusX + (b.focusX - a.focusX) * e,
                        a.focusY + (b.focusY - a.focusY) * e)
            }
        }
        return (1, 0.5, 0.5)
    }

    // MARK: Background

    /// "Pick random wallpaper" — selects a random image background.
    func randomWallpaper() {
        guard !imageBackgrounds.isEmpty else { return }
        let pick = imageBackgrounds[Int.random(in: 0..<imageBackgrounds.count)]
        if imageBackgrounds.count > 1, pick == background,
           let other = imageBackgrounds.first(where: { $0 != background }) {
            background = other          // avoid re-picking the current one
        } else {
            background = pick
        }
    }

    // MARK: Per-part speed

    var selectedSpeed: SpeedSegment? {
        guard let id = selectedSpeedID else { return nil }
        return speedSegments.first { $0.id == id }
    }

    /// Effective playback factor at source time `t`: a covering speed region,
    /// else the global `speed`.
    func effectiveSpeed(at t: Double) -> Double {
        for seg in speedSegments where t >= seg.start && t < seg.end { return max(0.1, seg.factor) }
        return max(0.1, speed)
    }

    func addSpeedSegment(at playhead: Double, factor: Double = 2.0) {
        endCoalescing(); snapshot()
        let block = makeDefaultBlock(at: playhead)
        let seg = SpeedSegment(start: block.start, end: block.end, factor: factor)
        speedSegments.append(seg)
        speedSegments.sort { $0.start < $1.start }
        selectedSpeedID = seg.id
        selectedSegmentID = nil
        bumpTimeline()
    }

    func updateSpeedTiming(for id: UUID, start: Double, end: Double, snapshotFirst: Bool) {
        guard let idx = speedSegments.firstIndex(where: { $0.id == id }) else { return }
        if snapshotFirst { snapshot() }
        var s = max(0, min(start, duration))
        var e = max(0, min(end, duration))
        if e <= s { e = min(duration, s + 0.1); if e <= s { s = max(0, e - 0.1) } }
        speedSegments[idx].start = s
        speedSegments[idx].end = e
    }

    func setSpeedFactor(for id: UUID, _ f: Double) {
        guard let idx = speedSegments.firstIndex(where: { $0.id == id }) else { return }
        endCoalescing(); snapshot()
        speedSegments[idx].factor = max(0.1, min(10, f))
        bumpTimeline()
    }

    func deleteSelectedSpeed() {
        guard let id = selectedSpeedID, speedSegments.contains(where: { $0.id == id }) else { return }
        endCoalescing(); snapshot()
        speedSegments.removeAll { $0.id == id }
        selectedSpeedID = nil
        bumpTimeline()
    }

    // MARK: Cuts (multi-range trim)

    var selectedCut: CutRange? {
        guard let id = selectedCutID else { return nil }
        return cuts.first { $0.id == id }
    }

    /// A cut covering source time `t` (used by live preview to skip over it).
    func cutContaining(_ t: Double) -> CutRange? {
        cuts.first { t >= $0.start && t < $0.end }
    }

    func addCut(at playhead: Double, duration: Double = 1.0) {
        endCoalescing(); snapshot()
        var s = max(0, min(playhead, self.duration))
        var e = min(self.duration, s + duration)
        if e - s < 0.1 { s = max(0, e - 0.1) }       // keep a minimum span near the end
        let cut = CutRange(start: s, end: e)
        cuts.append(cut)
        cuts.sort { $0.start < $1.start }
        selectedCutID = cut.id
        selectedSegmentID = nil
        selectedSpeedID = nil
        bumpTimeline()
    }

    func updateCutTiming(for id: UUID, start: Double, end: Double, snapshotFirst: Bool) {
        guard let idx = cuts.firstIndex(where: { $0.id == id }) else { return }
        if snapshotFirst { snapshot() }
        var s = max(0, min(start, duration))
        var e = max(0, min(end, duration))
        if e <= s { e = min(duration, s + 0.1); if e <= s { s = max(0, e - 0.1) } }
        cuts[idx].start = s
        cuts[idx].end = e
    }

    func deleteSelectedCut() {
        guard let id = selectedCutID, cuts.contains(where: { $0.id == id }) else { return }
        endCoalescing(); snapshot()
        cuts.removeAll { $0.id == id }
        selectedCutID = nil
        bumpTimeline()
    }

    // MARK: Spotlight

    var selectedSpotlight: SpotlightSegment? { spotlights.first { $0.id == selectedSpotlightID } }
    func spotlight(at t: Double) -> SpotlightSegment? { spotlights.first { t >= $0.start && t < $0.end } }

    func addSpotlight(at playhead: Double) {
        endCoalescing(); snapshot()
        let block = makeDefaultBlock(at: playhead)
        let frac: CGFloat = 0.5
        let box = CGRect(x: (1 - frac) / 2, y: (1 - frac) / 2, width: frac, height: frac)
        let s = SpotlightSegment(start: block.start, end: block.end, box: box,
                                 dim: RecorderDefaults.spotlightDim,
                                 roundness: RecorderDefaults.spotlightRoundness,
                                 feather: RecorderDefaults.spotlightFeather)
        spotlights.append(s); spotlights.sort { $0.start < $1.start }
        clearSelection(); selectedSpotlightID = s.id
    }

    func updateSpotlightTiming(for id: UUID, start: Double, end: Double, snapshotFirst: Bool) {
        guard let idx = spotlights.firstIndex(where: { $0.id == id }) else { return }
        if snapshotFirst { snapshot() }
        var s = max(0, min(start, duration)), e = max(0, min(end, duration))
        if e <= s { e = min(duration, s + 0.1); if e <= s { s = max(0, e - 0.1) } }
        spotlights[idx].start = s; spotlights[idx].end = e
    }

    func updateSpotlightBox(for id: UUID, to box: CGRect) {
        guard let idx = spotlights.firstIndex(where: { $0.id == id }) else { return }
        spotlights[idx].box = clampFreeBox(box)
    }

    func setSpotlightDim(for id: UUID, _ v: CGFloat) {
        guard let idx = spotlights.firstIndex(where: { $0.id == id }) else { return }
        spotlights[idx].dim = min(1, max(0, v))
        RecorderDefaults.spotlightDim = spotlights[idx].dim
    }
    func setSpotlightRoundness(for id: UUID, _ v: CGFloat) {
        guard let idx = spotlights.firstIndex(where: { $0.id == id }) else { return }
        spotlights[idx].roundness = min(0.5, max(0, v))
        RecorderDefaults.spotlightRoundness = spotlights[idx].roundness
    }
    func setSpotlightFeather(for id: UUID, _ v: CGFloat) {
        guard let idx = spotlights.firstIndex(where: { $0.id == id }) else { return }
        spotlights[idx].feather = min(0.5, max(0, v))
        RecorderDefaults.spotlightFeather = spotlights[idx].feather
    }
    /// Copy the selected spotlight's look (dim / roundness / feather) to every spotlight.
    func applySpotlightLookToAll() {
        guard let s = selectedSpotlight else { return }
        snapshot()
        for i in spotlights.indices {
            spotlights[i].dim = s.dim; spotlights[i].roundness = s.roundness; spotlights[i].feather = s.feather
        }
    }

    func deleteSelectedSpotlight() {
        guard let id = selectedSpotlightID, spotlights.contains(where: { $0.id == id }) else { return }
        endCoalescing(); snapshot()
        spotlights.removeAll { $0.id == id }
        selectedSpotlightID = nil
    }

    /// Clamp a free-aspect box into [0,1] with a minimum size.
    func clampFreeBox(_ b: CGRect) -> CGRect {
        let w = min(1, max(0.08, b.width)), h = min(1, max(0.08, b.height))
        let x = min(max(0, b.minX), 1 - w), y = min(max(0, b.minY), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Blur

    var selectedBlur: BlurSegment? { blurs.first { $0.id == selectedBlurID } }
    func blur(at t: Double) -> BlurSegment? { blurs.first { t >= $0.start && t < $0.end } }

    func addBlur(at playhead: Double) {
        endCoalescing(); snapshot()
        let block = makeDefaultBlock(at: playhead)
        let frac: CGFloat = 0.35
        let box = CGRect(x: (1 - frac) / 2, y: (1 - frac) / 2, width: frac, height: frac)
        let b = BlurSegment(start: block.start, end: block.end, box: box,
                            strength: RecorderDefaults.blurStrength,
                            roundness: RecorderDefaults.blurRoundness)
        blurs.append(b); blurs.sort { $0.start < $1.start }
        clearSelection(); selectedBlurID = b.id
    }

    func updateBlurTiming(for id: UUID, start: Double, end: Double, snapshotFirst: Bool) {
        guard let idx = blurs.firstIndex(where: { $0.id == id }) else { return }
        if snapshotFirst { snapshot() }
        var s = max(0, min(start, duration)), e = max(0, min(end, duration))
        if e <= s { e = min(duration, s + 0.1); if e <= s { s = max(0, e - 0.1) } }
        blurs[idx].start = s; blurs[idx].end = e
    }

    func updateBlurBox(for id: UUID, to box: CGRect) {
        guard let idx = blurs.firstIndex(where: { $0.id == id }) else { return }
        blurs[idx].box = clampFreeBox(box)
    }

    func setBlurStrength(for id: UUID, _ s: CGFloat) {
        guard let idx = blurs.firstIndex(where: { $0.id == id }) else { return }
        blurs[idx].strength = min(1, max(0.05, s))
        RecorderDefaults.blurStrength = blurs[idx].strength
    }
    func setBlurRoundness(for id: UUID, _ v: CGFloat) {
        guard let idx = blurs.firstIndex(where: { $0.id == id }) else { return }
        blurs[idx].roundness = min(0.5, max(0, v))
        RecorderDefaults.blurRoundness = blurs[idx].roundness
    }
    /// Copy the selected blur's look (strength / roundness) to every blur.
    func applyBlurLookToAll() {
        guard let b = selectedBlur else { return }
        snapshot()
        for i in blurs.indices { blurs[i].strength = b.strength; blurs[i].roundness = b.roundness }
    }

    func deleteSelectedBlur() {
        guard let id = selectedBlurID, blurs.contains(where: { $0.id == id }) else { return }
        endCoalescing(); snapshot()
        blurs.removeAll { $0.id == id }
        selectedBlurID = nil
    }

    /// Whether ANY editable element is currently selected.
    var hasSelection: Bool {
        selectedSegmentID != nil || selectedSpeedID != nil || selectedCutID != nil
            || selectedSpotlightID != nil || selectedBlurID != nil
    }

    /// Delete whichever element is selected (Delete / ⌫). Returns true if it removed one.
    @discardableResult
    func deleteAnySelected() -> Bool {
        if selectedSegmentID != nil { deleteSelected(); return true }
        if selectedSpeedID != nil { deleteSelectedSpeed(); return true }
        if selectedCutID != nil { deleteSelectedCut(); return true }
        if selectedSpotlightID != nil { deleteSelectedSpotlight(); return true }
        if selectedBlurID != nil { deleteSelectedBlur(); return true }
        return false
    }

    /// Clear any selection (Esc / click empty canvas).
    func clearSelection() {
        selectedSegmentID = nil; selectedSpeedID = nil; selectedCutID = nil
        selectedSpotlightID = nil; selectedBlurID = nil
    }

    // MARK: Mutually-exclusive selection (+ seek the element into view)

    /// A view observes this and seeks the player; nil means no pending seek.
    @Published var seekRequest: Double?

    func selectSegment(_ id: UUID)   { clearSelection(); selectedSegmentID = id;   seekIntoRangeIfNeeded() }
    func selectSpeed(_ id: UUID)     { clearSelection(); selectedSpeedID = id }
    func selectCut(_ id: UUID)       { clearSelection(); selectedCutID = id }
    func selectSpotlight(_ id: UUID) { clearSelection(); selectedSpotlightID = id; seekIntoRangeIfNeeded() }
    func selectBlur(_ id: UUID)      { clearSelection(); selectedBlurID = id;      seekIntoRangeIfNeeded() }

    /// If the selected element (one that has a preview box) isn't under the
    /// playhead, jump the playhead to its start so its box is visible/editable.
    private func seekIntoRangeIfNeeded() {
        let r: (Double, Double)?
        if let s = selectedSegment { r = (s.start, s.end) }
        else if let s = selectedSpotlight { r = (s.start, s.end) }
        else if let b = selectedBlur { r = (b.start, b.end) }
        else { r = nil }
        guard let r, playhead < r.0 || playhead >= r.1 else { return }
        seekRequest = r.0
    }

    /// Kept source ranges = the whole recording minus the cuts.
    func keptRanges() -> [(Double, Double)] {
        var kept: [(Double, Double)] = [(0, duration)]
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            var next: [(Double, Double)] = []
            for (a, b) in kept {
                let cs = max(a, cut.start), ce = min(b, cut.end)
                if cs >= ce { next.append((a, b)); continue }   // no overlap
                if cs > a { next.append((a, cs)) }
                if ce < b { next.append((ce, b)) }
            }
            kept = next
        }
        return kept.filter { $0.1 - $0.0 > 0.01 }
    }

    /// The edited-timeline pieces (kept ranges split by speed) — the single
    /// source of truth shared by the live preview composition and the export.
    func currentPieces() -> [EditPiece] {
        EditTimeline.pieces(
            keptRanges: keptRanges(),
            speedRanges: speedSegments.map { SpeedRange(start: $0.start, end: $0.end, factor: $0.factor) },
            globalSpeed: speed, sourceDuration: duration)
    }

    var hasEdits: Bool { !cuts.isEmpty || speed != 1.0 || !speedSegments.isEmpty }
    var outputDuration: Double { max(0.05, EditTimeline.outputDuration(currentPieces())) }
    func sourceToOutput(_ s: Double) -> Double { EditTimeline.sourceToOutput(s, currentPieces()) }
    func outputToSource(_ o: Double) -> Double { EditTimeline.outputToSource(o, currentPieces()) }

    // MARK: Cursor

    /// Cursor path with movement smoothing applied (cached per time-constant).
    /// An exponential filter — larger tau = smoother, more follow-through.
    func smoothedCursor() -> [CursorSample] {
        let tau = cursorMovement.cursorTau
        if let c = smoothedCache, abs(c.tau - tau) < 1e-4 { return c.samples }
        let out = Self.smoothPath(cursorSamples, tau: tau)
        smoothedCache = (tau, out)
        return out
    }

    private static func smoothPath(_ s: [CursorSample], tau: Double) -> [CursorSample] {
        guard s.count > 1, tau > 1e-4 else { return s }
        var out = s
        for i in 1..<s.count {
            let dt = max(1e-3, s[i].t - s[i - 1].t)
            let a = 1 - exp(-dt / tau)            // 0..1; higher = follows raw faster
            out[i].nx = out[i - 1].nx + (s[i].nx - out[i - 1].nx) * a
            out[i].ny = out[i - 1].ny + (s[i].ny - out[i - 1].ny) * a
        }
        return out
    }

    /// Interpolated cursor position (normalized top-left) at source time `t`.
    func cursorPosition(at t: Double) -> CGPoint? {
        guard showCursor else { return nil }
        let s = smoothedCursor()
        guard let first = s.first, let last = s.last else { return nil }
        if t <= first.t { return CGPoint(x: first.nx, y: first.ny) }
        if t >= last.t  { return CGPoint(x: last.nx, y: last.ny) }
        var lo = 0, hi = s.count - 1
        while lo + 1 < hi {
            let m = (lo + hi) / 2
            if s[m].t <= t { lo = m } else { hi = m }
        }
        let a = s[lo], b = s[hi]
        let span = b.t - a.t
        let f = span > 0 ? (t - a.t) / span : 0
        return CGPoint(x: a.nx + (b.nx - a.nx) * f, y: a.ny + (b.ny - a.ny) * f)
    }

    /// Cached synthetic-cursor CGImage for the preview at a given pixel height.
    func cursorCG(height: CGFloat) -> CGImage? {
        if let c = cursorCGCache, abs(c.h - height) < 1, c.style == cursorStyle { return c.cg }
        guard let cg = CursorGraphic.arrowCG(height: height, style: cursorStyle) else { return nil }
        cursorCGCache = (height, cursorStyle, cg)
        return cg
    }

    static let clickEffectDuration: Double = 0.5

    /// Active click effect at source time `t`: centre (normalized) + 0..1 progress.
    func activeClick(at t: Double) -> (center: CGPoint, progress: Double)? {
        guard clickEffect != .none, !clicks.isEmpty else { return nil }
        var best: CursorSample?
        for c in clicks where c.t <= t + 1e-4 {
            if best == nil || c.t > best!.t { best = c }
        }
        guard let c = best else { return nil }
        let dt = t - c.t
        guard dt >= 0, dt <= EditorState.clickEffectDuration else { return nil }
        return (CGPoint(x: c.nx, y: c.ny), dt / EditorState.clickEffectDuration)
    }

    /// Whether the cursor is shown at source time `t` (respects hide-when-idle).
    func cursorVisible(at t: Double) -> Bool {
        guard hideCursorWhenIdle else { return true }
        guard let last = lastMoveTime(atOrBefore: t) else { return true }   // before first move → show
        return (t - last) < EditorState.idleHideAfter
    }
    private func lastMoveTime(atOrBefore t: Double) -> Double? {
        guard !moveTimes.isEmpty, moveTimes[0] <= t else { return nil }
        var lo = 0, hi = moveTimes.count - 1, ans = 0
        while lo <= hi {
            let m = (lo + hi) / 2
            if moveTimes[m] <= t { ans = m; lo = m + 1 } else { hi = m - 1 }
        }
        return moveTimes[ans]
    }

    func renderOptions(outputURL: URL) -> RenderOptions {
        var top: NSColor = .black
        var bottom: NSColor = .black
        var pad = padding
        var solid: NSColor? = nil
        var image: NSImage? = nil
        switch background {
        case .gradient(let t, let b, _):
            top = t; bottom = b
        case .solid(let c):
            solid = c
        case .image(_, let url):
            image = NSImage(contentsOf: url)
            if image == nil { solid = EditorBackground.colorPresets[0] }  // missing file → fallback color
        case .hidden:
            pad = 0
        }
        let hidden = (background == .hidden)
        // Avatar movement + off-spans, mapped from SOURCE time → OUTPUT time so
        // they stay in sync after cuts/speed.
        let pieces = currentPieces()
        let camPathPoints: [CameraPathPoint]
        if cameraFollowsPath, !cameraPath.isEmpty {
            camPathPoints = cameraPath.map { k in
                CameraPathPoint(t: EditTimeline.sourceToOutput(k.t, pieces),
                                cx: k.center.x, cy: k.center.y, h: k.h)
            }.sorted { $0.t < $1.t }
        } else {
            camPathPoints = []
        }
        let camOffOut: [ClosedRange<Double>] = cameraOffSpans.map { span in
            let a = EditTimeline.sourceToOutput(span.0, pieces)
            let b = EditTimeline.sourceToOutput(span.1, pieces)
            return Swift.min(a, b)...Swift.max(a, b)
        }
        return RenderOptions(
            gradientTop: top,
            gradientBottom: bottom,
            paddingFraction: pad,
            cornerRadius: hidden ? 0 : cornerRadius,
            shadow: hidden ? false : shadow,
            outputURL: outputURL,
            backgroundImage: image,
            solidColor: solid,
            keptRanges: keptRanges().map { $0.0...$0.1 },
            speed: speed,
            speedRanges: speedSegments.map {
                SpeedRange(start: $0.start, end: $0.end, factor: $0.factor)
            },
            backgroundBlur: hidden ? 0 : backgroundBlur,
            cursor: showCursor ? smoothedCursor() : [],
            cursorScale: cursorScale,
            cursorStyle: cursorStyle,
            clickEffect: showCursor ? clickEffect : .none,
            clicks: showCursor ? clicks : [],
            cursorMoveTimes: (showCursor && hideCursorWhenIdle) ? moveTimes : [],
            hideCursorIdle: showCursor && hideCursorWhenIdle,
            idleHideAfter: EditorState.idleHideAfter,
            spotlights: spotlights.map { SpotlightRect(start: $0.start, end: $0.end, box: $0.box,
                                                        dim: $0.dim, roundness: $0.roundness) },
            blurs: blurs.map { BlurRect(start: $0.start, end: $0.end, box: $0.box,
                                        strength: $0.strength, roundness: $0.roundness) },
            cameraURL: (hasCamera && cameraVisible) ? cameraURL : nil,
            cameraCenter: cameraCenter,
            cameraHeightFrac: cameraHeightFrac,
            cameraCircle: cameraShape == .circle,
            cameraPath: camPathPoints,
            cameraOffSpans: camOffOut,
            cameraFullscreen: cameraLayout == .fullscreen
        )
    }

    // MARK: Box geometry helpers

    /// Clamp a candidate box so it: keeps equal normalized width & height (aspect
    /// lock — see ZoomBoxOverlay header), respects scale 1...4 (i.e. side in
    /// [0.25, 1.0]), and stays fully inside [0,1], anchored on its center.
    func clampAspectLockedBox(_ box: CGRect) -> CGRect {
        var side = max(box.width, box.height)
        side = min(1.0, max(0.25, side))      // scale 1...4

        let cx = box.midX
        let cy = box.midY
        var originX = cx - side / 2
        var originY = cy - side / 2

        originX = min(max(0, originX), 1 - side)
        originY = min(max(0, originY), 1 - side)

        return CGRect(x: originX, y: originY, width: side, height: side)
    }

    private func clamp01(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }

    /// Enforce strictly-increasing timestamps in [0, duration] with EXACTLY ONE
    /// keyframe at t == duration. The old code clamped nudged timestamps DOWN to
    /// `duration`, so several keyframes could pile up at the same t near the end
    /// (segment end + ramp-out + final rest), violating strict monotonicity. Here we
    /// nudge upward with no duration ceiling, then collapse the tail at/above
    /// duration into a single keyframe pinned to exactly duration — preserving the
    /// last (resting, scale-1) keyframe's scale + focus.
    private func dedupeMonotonic(_ kfs: [ZoomKeyframe]) -> [ZoomKeyframe] {
        guard !kfs.isEmpty else { return kfs }

        // 1) Strictly increasing, NO downward clamp to duration.
        var bumped: [ZoomKeyframe] = []
        var lastT = -1.0
        for kf in kfs {
            var t = kf.t
            if t <= lastT { t = lastT + 0.001 }
            bumped.append(ZoomKeyframe(t: t, scale: kf.scale, focusX: kf.focusX, focusY: kf.focusY))
            lastT = t
        }

        // 2) Collapse the tail at/above duration to a single keyframe pinned to
        //    duration, preserving the last keyframe's (resting) scale + focus.
        guard let cut = bumped.firstIndex(where: { $0.t >= duration }) else { return bumped }

        var out = Array(bumped[..<cut])
        let tail = bumped[bumped.count - 1]     // intended final resting keyframe
        if let prev = out.last, duration <= prev.t {
            // Degenerate (duration not strictly greater than the kept prefix):
            // replace the last kept keyframe with the resting tail at duration.
            out[out.count - 1] = ZoomKeyframe(t: duration, scale: tail.scale,
                                              focusX: tail.focusX, focusY: tail.focusY)
        } else {
            out.append(ZoomKeyframe(t: duration, scale: tail.scale,
                                    focusX: tail.focusX, focusY: tail.focusY))
        }
        return out
    }
}

// MARK: - Root view

struct EditorRootView: View {
    let movieURL: URL
    let track: InteractionTrack
    @ObservedObject var state: EditorState
    @ObservedObject var playerHolder: PlayerHolder

    @State private var isAddingZoom = false
    @State private var isExporting = false
    @State private var exportProgress = "Rendering…"
    @State private var exportError: String?

    var body: some View {
        HStack(spacing: 0) {
            // LEFT: preview + timeline + toolbar
            VStack(spacing: 0) {
                PreviewContainer(
                    player: playerHolder.player,
                    cameraPlayer: playerHolder.cameraPlayer,
                    state: state,
                    isAddingZoom: $isAddingZoom
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

                Divider()

                ZoomTimelineView(state: state, player: playerHolder.player)
                    .frame(height: 110)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                Divider()

                ToolbarView(
                    state: state,
                    track: track,
                    isAddingZoom: $isAddingZoom
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // RIGHT: inspector (editing properties) — contextual to the selection
            InspectorView(state: state, onExport: export)
                .frame(width: 300)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(Color.forgeAccent)     // brand red on all controls (buttons, sliders, pickers, toggles)
        .onDeleteCommand { state.deleteAnySelected() }   // Delete / ⌫ removes the selected element
        .onExitCommand { state.clearSelection() }        // Esc deselects
        .overlay {
            if isExporting {
                ExportOverlay(message: exportProgress)
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onAppear {
            observePlayhead(); rebuildPlayback()
            playerHolder.cameraPlayer?.seek(to: .zero)
        }
        .onDisappear { removePlayheadObserver() }
        .onChange(of: state.speed) { _, _ in state.bumpTimeline() }   // re-bake speed
        .onChange(of: state.timelineRevision) { _, _ in rebuildPlayback() }
        .onChange(of: state.isPlaying) { _, playing in syncCamera(playing: playing) }
        .onChange(of: state.playhead) { _, ph in driftSyncCamera(to: ph) }
    }

    /// Start/stop the webcam player in step with the main transport.
    private func syncCamera(playing: Bool) {
        guard let cam = playerHolder.cameraPlayer else { return }
        let t = CMTime(seconds: state.playhead, preferredTimescale: 600)
        if playing {
            cam.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { _ in cam.play() }
        } else {
            cam.pause()
            cam.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Keep the webcam frame aligned with the (source-time) playhead. While
    /// playing it free-runs and only re-seeks on drift; paused/scrubbing it
    /// follows the playhead with a cheap tolerant seek.
    private func driftSyncCamera(to ph: Double) {
        guard let cam = playerHolder.cameraPlayer else { return }
        let t = CMTime(seconds: max(0, ph), preferredTimescale: 600)
        if state.isPlaying {
            if abs(CMTimeGetSeconds(cam.currentTime()) - ph) > 0.3 {
                cam.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } else {
            cam.seek(to: t, toleranceBefore: .init(seconds: 0.08, preferredTimescale: 600),
                     toleranceAfter: .init(seconds: 0.08, preferredTimescale: 600))
        }
    }

    /// Rebuild the edited-timeline player item and re-seek to the current
    /// position. Cheap (a few pieces); only runs on structural edits, not drags.
    private func rebuildPlayback() {
        let pieces = state.currentPieces()
        playerHolder.loadEdited(pieces: pieces, sourceDuration: state.duration)
        let out = EditTimeline.sourceToOutput(min(state.playhead, state.duration), pieces)
        playerHolder.player.seek(to: CMTime(seconds: out, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
        if state.isPlaying { playerHolder.player.play() }
    }

    // MARK: Playhead sync (player -> state.playhead)

    private func observePlayhead() {
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        // Observer ownership lives in PlayerHolder so it is removed deterministically
        // in teardown() (window close) BEFORE the player item is dropped. Capture
        // `state` WEAKLY so a stray late tick can never pin EditorState alive — the
        // worst case degrades to a no-op rather than a leak.
        playerHolder.addPlayheadObserver(interval: interval) { [weak state, weak playerHolder] time in
            guard let state else { return }
            // Single-writer rule: while the user scrubs the timeline, the scrub
            // gesture owns `playhead`. Suppress observer writes so stale async
            // player time can't yank the playhead backward mid-drag.
            guard !state.isScrubbing else { return }
            // The player runs on the EDITED (output) timeline; convert to source
            // time for the playhead, zoom, and cursor. Cuts/speed are already
            // baked into the composition, so playback is continuous (no skips).
            let out = CMTimeGetSeconds(time)
            guard out.isFinite else { return }
            let outDur = state.outputDuration
            if state.isPlaying, out >= outDur - 0.03 {
                playerHolder?.player.pause()
                state.isPlaying = false
                state.playhead = state.outputToSource(outDur)
                return
            }
            state.playhead = min(state.duration, max(0, state.outputToSource(out)))
        }
    }

    private func removePlayheadObserver() {
        // Redundant guard — teardown() already removes it on window close. Both
        // paths are idempotent.
        playerHolder.removePlayheadObserver()
    }

    // MARK: Export

    private func export() {
        let base = movieURL.deletingPathExtension().lastPathComponent
        let outURL = movieURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(base)-edited.mp4")

        let keyframes = state.buildKeyframes()
        let options = state.renderOptions(outputURL: outURL)

        // Capture the editor window NOW (before Finder steals key focus on
        // success) so we can close it once the export finishes.
        let editorWindow = NSApp.keyWindow

        isExporting = true
        exportProgress = "Rendering…"
        playerHolder.player.pause()

        RecordingRenderer.render(movieURL: movieURL, keyframes: keyframes, options: options) { result in
            // completion is delivered on MAIN per RecordingRenderer's contract.
            isExporting = false
            switch result {
            case .success(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
                editorWindow?.close()   // dismiss the editor after a successful export
            case .failure(let error):
                exportError = error.localizedDescription
            }
        }
    }
}

// MARK: - Preview container (AVPlayerLayer + zoom-box overlay)

struct PreviewContainer: View {
    let player: AVPlayer
    var cameraPlayer: AVPlayer? = nil
    @ObservedObject var state: EditorState
    @Binding var isAddingZoom: Bool

    @State private var camCenterStart: CGPoint?
    @State private var camSizeStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let viewSize = geo.size
            // The whole preview is the "canvas". The video sits inset by the
            // padding fraction (matching the renderer), so changing background /
            // padding / corner / shadow updates the preview LIVE.
            let pad = max(0, state.padding) * min(viewSize.width, viewSize.height)
            let canvasW = max(1, viewSize.width - 2 * pad)
            let canvasH = max(1, viewSize.height - 2 * pad)
            let inner = Self.videoDisplayRect(in: CGSize(width: canvasW, height: canvasH),
                                              aspect: state.videoAspect)
            let videoRect = inner.offsetBy(dx: pad, dy: pad)

            // Live zoom: while PLAYING, scale+pan the video so the active zoom
            // segment's focus is centered — exactly what the export produces. When
            // paused/editing we show a flat (1×) frame so zoom boxes can be drawn
            // accurately. scaleEffect + offset are render-only, so the rounded clip
            // window stays fixed and the zoomed video pans inside it.
            let cam: (scale: CGFloat, fx: CGFloat, fy: CGFloat) =
                state.isPlaying ? state.camera(at: state.playhead) : (1, 0.5, 0.5)
            let ox = -cam.scale * (cam.fx - 0.5) * videoRect.width
            let oy = -cam.scale * (cam.fy - 0.5) * videoRect.height

            ZStack {
                // Live background (color / image / gradient) fills the canvas,
                // with optional blur (mainly for wallpapers).
                backgroundView
                    .frame(width: viewSize.width, height: viewSize.height)
                    .blur(radius: state.backgroundBlur)
                    .clipped()

                // Video + synthetic cursor (a CALayer above the video, inside the
                // zoom transform so it pans/scales with the video like the export).
                let render = cursorRender(in: CGSize(width: videoRect.width, height: videoRect.height))
                PlayerLayerView(player: player, render: render)
                    .frame(width: videoRect.width, height: videoRect.height)
                    .scaleEffect(cam.scale, anchor: .center)
                    .offset(x: ox, y: oy)
                    .clipShape(RoundedRectangle(cornerRadius: state.cornerRadius))
                    .shadow(color: state.shadow ? Color.black.opacity(0.45) : .clear,
                            radius: state.shadow ? 14 : 0, x: 0, y: 6)
                    .position(x: videoRect.midX, y: videoRect.midY)
                    .allowsHitTesting(false)

                // Box editing overlay — only when paused (flat frame).
                if !state.isPlaying {
                    ZoomBoxOverlay(
                        state: state,
                        isAddingZoom: $isAddingZoom,
                        videoRect: videoRect
                    )
                }

                // Spotlight (dim around a box). Active during playback; editable
                // when paused + selected.
                SpotlightOverlay(state: state, videoRect: videoRect)

                // Blur box editor (the blur itself renders in the player view).
                BlurOverlay(state: state, videoRect: videoRect)

                // Camera bubble — on TOP, in canvas space (not zoomed). Drag to
                // move, drag the corner grip to resize.
                if state.hasCamera, state.cameraVisible, state.cameraVisibleAt(state.playhead), let cam = cameraPlayer {
                    cameraBubble(cam: cam, viewSize: viewSize)
                        .allowsHitTesting(!isAddingZoom)
                }
            }
            .coordinateSpace(name: "forgePreview")   // stable frame for drag math
        }
    }

    /// Draggable + resizable webcam bubble, positioned in canvas space.
    @ViewBuilder
    private func cameraBubble(cam: AVPlayer, viewSize: CGSize) -> some View {
        if state.cameraLayout == .fullscreen {
            CameraPlayerView(player: cam, cornerRadius: 0)
                .frame(width: viewSize.width, height: viewSize.height)
                .position(x: viewSize.width / 2, y: viewSize.height / 2)
                .allowsHitTesting(false)
        } else {
        let g = state.cameraSample(at: state.playhead)   // follows the recorded path when active
        let cs = max(40, g.h * viewSize.height)
        let cx = g.center.x * viewSize.width
        let cy = g.center.y * viewSize.height
        let r = state.cameraShape == .circle ? cs / 2 : cs * 0.16

        ZStack(alignment: .bottomTrailing) {
            CameraPlayerView(player: cam, cornerRadius: r)
                .frame(width: cs, height: cs)

            // Resize grip.
            Circle()
                .fill(Color.white)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.forgeAccent, lineWidth: 2))
                .offset(x: 6, y: 6)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("forgePreview"))
                        .onChanged { v in
                            if camSizeStart == nil { state.pinCameraToCurrent(); camSizeStart = state.cameraHeightFrac }
                            let d = v.translation.height / viewSize.height
                            state.cameraHeightFrac = min(0.8, max(0.05, (camSizeStart ?? 0.17) + d * 2))
                        }
                        .onEnded { _ in camSizeStart = nil }
                )
        }
        .frame(width: cs, height: cs)
        .position(x: cx, y: cy)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("forgePreview"))
                .onChanged { v in
                    if camCenterStart == nil { state.pinCameraToCurrent(); camCenterStart = state.cameraCenter }
                    let s = camCenterStart ?? state.cameraCenter
                    state.cameraCenter = CGPoint(
                        x: min(1, max(0, s.x + v.translation.width / viewSize.width)),
                        y: min(1, max(0, s.y + v.translation.height / viewSize.height)))
                }
                .onEnded { _ in camCenterStart = nil }
        )
        }
    }

    /// Live background matching the export (color / image / gradient / hidden).
    @ViewBuilder private var backgroundView: some View {
        switch state.background {
        case .solid(let c):
            Color(nsColor: c)
        case .image(_, let url):
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        case .gradient(let t, let b, _):
            LinearGradient(colors: [Color(nsColor: t), Color(nsColor: b)],
                           startPoint: .top, endPoint: .bottom)
        case .hidden:
            Color.black
        }
    }

    /// Cursor + click-effect render info at the current playhead (view points,
    /// top-left). Respects hide-when-idle; the tip lands on the cursor position.
    private func cursorRender(in size: CGSize) -> CursorRender {
        guard size.height > 1 else { return .init() }
        var r = CursorRender()
        if state.cursorVisible(at: state.playhead),
           let cp = state.cursorPosition(at: state.playhead) {
            let h = max(8, size.height * CursorGraphic.heightFraction * state.cursorScale)
            if let cg = state.cursorCG(height: h) {
                let cw = h * CursorGraphic.aspect(for: state.cursorStyle), ch = h
                let anchor = CursorGraphic.tipAnchor(for: state.cursorStyle)
                r.cg = cg
                r.rect = CGRect(x: cp.x * size.width - anchor.x * cw,
                                y: cp.y * size.height - (1 - anchor.y) * ch,
                                width: cw, height: ch)
            }
        }
        if let ac = state.activeClick(at: state.playhead) {
            let maxR = size.height * 0.06
            let p = CGFloat(ac.progress)
            r.clickStyle = state.clickEffect
            r.clickRadius = maxR * (0.2 + 0.8 * p)
            r.clickOpacity = max(0, (p < 0.15 ? p / 0.15 : (1 - p) / 0.85) * 0.9)
            r.clickCenter = CGPoint(x: ac.center.x * size.width, y: ac.center.y * size.height)
        }
        // Region blur — selected (paused) or active (playing).
        let blurSeg = state.blur(at: state.playhead)   // only blur what's active now
        if let bl = blurSeg {
            let bw = bl.box.width * size.width, bh = bl.box.height * size.height
            r.blurRect = CGRect(x: bl.box.minX * size.width, y: bl.box.minY * size.height,
                                width: bw, height: bh)
            r.blurRadius = bl.strength * min(bw, bh) * 0.5
            r.blurCorner = bl.roundness * min(bw, bh)
        }
        return r
    }

    /// Aspect-fit (letterbox) rect for a video of the given aspect inside `viewSize`.
    static func videoDisplayRect(in viewSize: CGSize, aspect: CGFloat) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0, aspect > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let viewAspect = viewSize.width / viewSize.height
        var w: CGFloat
        var h: CGFloat
        if viewAspect > aspect {
            // View wider than video → pillarbox (height-limited).
            h = viewSize.height
            w = h * aspect
        } else {
            // View taller than video → letterbox (width-limited).
            w = viewSize.width
            h = w / aspect
        }
        let x = (viewSize.width - w) / 2
        let y = (viewSize.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Hosts an AVPlayerLayer so we control the exact frame the video occupies.
/// Everything the player view draws above the video (cursor + click effect),
/// in SwiftUI top-left view points.
struct CursorRender: Equatable {
    var cg: CGImage? = nil
    var rect: CGRect = .zero
    var clickStyle: ClickEffect = .none
    var clickCenter: CGPoint = .zero
    var clickRadius: CGFloat = 0
    var clickOpacity: CGFloat = 0
    /// Region blur (view points, top-left) + radius. radius 0 = none.
    var blurRect: CGRect = .zero
    var blurRadius: CGFloat = 0
    var blurCorner: CGFloat = 0
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    /// Cursor + click effect drawn as CALayers ABOVE the video. (A SwiftUI
    /// sibling would be hidden — a hosted AVPlayerLayer renders over SwiftUI
    /// siblings.) Coordinates are view points (top-left).
    var render: CursorRender = .init()

    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.apply(render)
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    private let cursorLayer = CALayer()
    private let clickLayer = CALayer()
    private let blurLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
        blurLayer.zPosition = 8              // blurs the video behind it
        blurLayer.masksToBounds = true
        blurLayer.isHidden = true
        layer?.addSublayer(blurLayer)
        clickLayer.zPosition = 9
        clickLayer.isHidden = true
        layer?.addSublayer(clickLayer)
        cursorLayer.contentsGravity = .resizeAspect
        cursorLayer.zPosition = 10           // above the video + click effect
        cursorLayer.isHidden = true
        layer?.addSublayer(cursorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    /// `render` is in SwiftUI top-left points; convert to bottom-left layer
    /// space. No implicit animation (snaps each tick).
    func apply(_ r: CursorRender) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Cursor
        if let cg = r.cg, r.rect.width > 1, r.rect.height > 1 {
            cursorLayer.contents = cg
            cursorLayer.frame = CGRect(x: r.rect.minX, y: bounds.height - r.rect.maxY,
                                       width: r.rect.width, height: r.rect.height)
            cursorLayer.isHidden = false
        } else {
            cursorLayer.isHidden = true
        }

        // Region blur (blurs the video behind the layer via backgroundFilters).
        if r.blurRadius > 0.5, r.blurRect.width > 1, r.blurRect.height > 1 {
            blurLayer.frame = CGRect(x: r.blurRect.minX, y: bounds.height - r.blurRect.maxY,
                                     width: r.blurRect.width, height: r.blurRect.height)
            blurLayer.cornerRadius = r.blurCorner
            if let f = CIFilter(name: "CIGaussianBlur") {
                f.setValue(r.blurRadius, forKey: kCIInputRadiusKey)
                blurLayer.backgroundFilters = [f]
            }
            blurLayer.isHidden = false
        } else {
            blurLayer.isHidden = true
        }

        // Click effect
        if r.clickStyle != .none, r.clickRadius > 0.5, r.clickOpacity > 0.01 {
            let d = r.clickRadius * 2
            clickLayer.frame = CGRect(x: r.clickCenter.x - r.clickRadius,
                                      y: (bounds.height - r.clickCenter.y) - r.clickRadius,
                                      width: d, height: d)
            clickLayer.cornerRadius = r.clickRadius
            clickLayer.opacity = Float(r.clickOpacity)
            switch r.clickStyle {
            case .ring:
                clickLayer.backgroundColor = NSColor.clear.cgColor
                clickLayer.borderColor = NSColor.white.cgColor
                clickLayer.borderWidth = max(2, bounds.height * 0.006)
            case .ripple:
                clickLayer.borderWidth = 0
                clickLayer.backgroundColor = NSColor.white.withAlphaComponent(0.30).cgColor
            case .spotlight:
                clickLayer.borderWidth = 0
                clickLayer.backgroundColor = NSColor.forgeAccent.withAlphaComponent(0.45).cgColor
            case .sparkle:
                // Preview proxy: a small white pop (the export draws the full burst).
                clickLayer.borderWidth = 0
                clickLayer.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            case .none: break
            }
            clickLayer.isHidden = false
        } else {
            clickLayer.isHidden = true
        }
    }
}

// MARK: - Camera overlay (webcam bubble)

/// Hosts the webcam AVPlayerLayer, masked to a circle/rounded rect.
struct CameraPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> CameraNSView {
        let v = CameraNSView()
        v.playerLayer.player = player
        return v
    }
    func updateNSView(_ v: CameraNSView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.setCorner(cornerRadius)
    }
}

final class CameraNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.masksToBounds = true
        layer?.addSublayer(playerLayer)
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 2
        layer?.masksToBounds = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
    func setCorner(_ r: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.cornerRadius = r
        layer?.cornerRadius = r
        CATransaction.commit()
    }
}

// MARK: - Zoom-box overlay (the load-bearing drag math)

struct ZoomBoxOverlay: View {
    @ObservedObject var state: EditorState
    @Binding var isAddingZoom: Bool
    let videoRect: CGRect      // letterboxed video rect in preview-view (point) space

    // Drag-to-create scratch state (preview points).
    @State private var createStart: CGPoint?
    @State private var createCurrent: CGPoint?

    // Existing-box drag/resize scratch state (normalized box captured at drag start).
    @State private var dragInitialBox: CGRect?

    enum Corner: Equatable { case tl, tr, bl, br }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Hit area for creating a new box (active only while adding zoom).
            Color.clear
                .contentShape(Rectangle())
                .gesture(createGesture)

            // Pending create rectangle.
            if let s = createStart, let c = createCurrent {
                let r = Self.aspectLockedPixelRect(from: s, to: c,
                                                   in: videoRect, aspect: state.videoAspect)
                Rectangle()
                    .strokeBorder(Color.forgeAccent, lineWidth: 2)
                    .background(Color.forgeAccent.opacity(0.12))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
            }

            // The selected segment's box — only when the playhead is inside its
            // range (so it's "in action" at the current time).
            if let seg = state.selectedSegment, state.playhead >= seg.start, state.playhead < seg.end {
                let pr = Self.normToPixel(seg.box, in: videoRect)
                selectedBoxView(segment: seg, pixelRect: pr)
            }
        }
        // Hide entirely until we have a real video rect.
        .opacity(videoRect.width > 1 ? 1 : 0)
    }

    // MARK: Create gesture

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("forgePreview"))
            .onChanged { value in
                guard isAddingZoom else { return }
                if createStart == nil { createStart = value.startLocation }
                createCurrent = value.location
            }
            .onEnded { value in
                guard isAddingZoom, let s = createStart else {
                    createStart = nil; createCurrent = nil; return
                }
                let r = Self.aspectLockedPixelRect(from: s, to: value.location,
                                                   in: videoRect, aspect: state.videoAspect)
                let norm = Self.pixelToNorm(r, in: videoRect)
                let block = state.makeDefaultBlock(at: state.playhead)
                let seg = ZoomSegment(start: block.start, end: block.end, box: norm)
                state.addSegment(seg)   // single undo snapshot + select

                createStart = nil
                createCurrent = nil
                isAddingZoom = false
            }
    }

    // MARK: Selected box view

    @ViewBuilder
    private func selectedBoxView(segment seg: ZoomSegment, pixelRect pr: CGRect) -> some View {
        let handle: CGFloat = 12

        ZStack(alignment: .topLeading) {
            // Body — drag to move.
            Rectangle()
                .strokeBorder(Color.forgeAccent, lineWidth: 2)
                .background(Color.forgeAccent.opacity(0.10))
                .frame(width: pr.width, height: pr.height)
                .contentShape(Rectangle())
                .gesture(moveGesture(for: seg))

            cornerHandle(.tl, pr: pr, size: handle, seg: seg)
            cornerHandle(.tr, pr: pr, size: handle, seg: seg)
            cornerHandle(.bl, pr: pr, size: handle, seg: seg)
            cornerHandle(.br, pr: pr, size: handle, seg: seg)
        }
        .offset(x: pr.minX, y: pr.minY)
        .allowsHitTesting(!isAddingZoom)
    }

    private func cornerHandle(_ corner: Corner, pr: CGRect, size: CGFloat, seg: ZoomSegment) -> some View {
        let pos: CGPoint
        switch corner {
        case .tl: pos = CGPoint(x: 0, y: 0)
        case .tr: pos = CGPoint(x: pr.width, y: 0)
        case .bl: pos = CGPoint(x: 0, y: pr.height)
        case .br: pos = CGPoint(x: pr.width, y: pr.height)
        }
        return Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.forgeAccent, lineWidth: 2))
            .frame(width: size, height: size)
            .position(x: pos.x, y: pos.y)
            .gesture(resizeGesture(for: seg, corner: corner))
    }

    // MARK: Move / resize gestures (operate in preview pixels, commit normalized)

    private func moveGesture(for seg: ZoomSegment) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("forgePreview"))
            .onChanged { value in
                if dragInitialBox == nil {
                    dragInitialBox = seg.box
                    state.beginEdit()   // one snapshot at drag start
                }
                guard let initial = dragInitialBox, videoRect.width > 0, videoRect.height > 0
                else { return }
                let dxNorm = value.translation.width / videoRect.width
                let dyNorm = value.translation.height / videoRect.height
                var moved = initial
                moved.origin.x += dxNorm
                moved.origin.y += dyNorm
                state.updateBox(for: seg.id, to: moved)
            }
            .onEnded { _ in dragInitialBox = nil }
    }

    private func resizeGesture(for seg: ZoomSegment, corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("forgePreview"))
            .onChanged { value in
                if dragInitialBox == nil {
                    dragInitialBox = seg.box
                    state.beginEdit()
                }
                guard let initial = dragInitialBox else { return }
                let newBox = Self.resizedAspectLockedBox(
                    initial: initial,
                    corner: corner,
                    translationPx: value.translation,
                    videoRect: videoRect
                )
                state.updateBox(for: seg.id, to: newBox)
            }
            .onEnded { _ in dragInitialBox = nil }
    }

    // =========================================================================
    // Coordinate math — preview pixels <-> normalized video coords (TOP-LEFT).
    //
    // `videoRect` is the letterboxed video rect inside the preview view, in the
    // same point space as gesture locations (SwiftUI top-left origin). A
    // normalized point (nx, ny) in [0,1] video space maps to the preview point:
    //
    //     px = videoRect.minX + nx * videoRect.width
    //     py = videoRect.minY + ny * videoRect.height
    //
    // and the inverse:
    //
    //     nx = (px - videoRect.minX) / videoRect.width
    //     ny = (py - videoRect.minY) / videoRect.height
    //
    // Aspect lock: a sub-rect whose NORMALIZED width == NORMALIZED height has the
    // same PIXEL aspect as the full frame — because the full frame's pixel aspect
    // is videoRect.width / videoRect.height and a w==h (normalized) sub-rect scales
    // both dimensions by the same factor. So "aspect-locked" simply means we keep
    // the normalized side equal in x and y. Then scale = 1 / side.
    // =========================================================================

    static func normToPixel(_ box: CGRect, in videoRect: CGRect) -> CGRect {
        CGRect(
            x: videoRect.minX + box.minX * videoRect.width,
            y: videoRect.minY + box.minY * videoRect.height,
            width: box.width * videoRect.width,
            height: box.height * videoRect.height
        )
    }

    static func pixelToNorm(_ rect: CGRect, in videoRect: CGRect) -> CGRect {
        guard videoRect.width > 0, videoRect.height > 0 else { return .zero }
        return CGRect(
            x: (rect.minX - videoRect.minX) / videoRect.width,
            y: (rect.minY - videoRect.minY) / videoRect.height,
            width: rect.width / videoRect.width,
            height: rect.height / videoRect.height
        )
    }

    /// Build an aspect-locked pixel rect from two drag points, clamped inside
    /// `videoRect`. The rect's pixel aspect equals the video's aspect, anchored at
    /// the start point and growing toward the current point. Because the rect has
    /// the video's pixel aspect, its NORMALIZED width and height come out equal.
    static func aspectLockedPixelRect(from start: CGPoint, to current: CGPoint,
                                      in videoRect: CGRect, aspect: CGFloat) -> CGRect {
        guard videoRect.width > 0, videoRect.height > 0, aspect > 0 else { return .zero }

        let sx = min(max(start.x, videoRect.minX), videoRect.maxX)
        let sy = min(max(start.y, videoRect.minY), videoRect.maxY)
        let cx = min(max(current.x, videoRect.minX), videoRect.maxX)
        let cy = min(max(current.y, videoRect.minY), videoRect.maxY)

        let dirX: CGFloat = (cx >= sx) ? 1 : -1
        let dirY: CGFloat = (cy >= sy) ? 1 : -1

        // Drive width from the dominant drag axis, derive the other from aspect.
        var w = abs(cx - sx)
        var h = w / aspect
        let hFromY = abs(cy - sy)
        if hFromY > h { h = hFromY; w = h * aspect }

        // Clamp so the rect stays inside videoRect from the anchor in each dir.
        let maxW = (dirX > 0) ? (videoRect.maxX - sx) : (sx - videoRect.minX)
        let maxH = (dirY > 0) ? (videoRect.maxY - sy) : (sy - videoRect.minY)
        if w > maxW { w = maxW; h = w / aspect }
        if h > maxH { h = maxH; w = h * aspect }

        // Minimum size = scale 4 → normalized side 0.25 → 0.25 * videoRect.width px.
        let minW = 0.25 * videoRect.width
        if w < minW {
            w = min(minW, maxW)
            h = w / aspect
            if h > maxH { h = maxH; w = h * aspect }
        }

        let originX = (dirX > 0) ? sx : sx - w
        let originY = (dirY > 0) ? sy : sy - h
        return CGRect(x: originX, y: originY, width: w, height: h)
    }

    /// Resize a normalized box by dragging one corner; the OPPOSITE corner is the
    /// fixed anchor. Kept aspect-locked (equal normalized side).
    ///
    /// Two fixes vs. the original:
    ///   1. The side is derived from the LARGER PIXEL displacement of the dragged
    ///      corner from the anchor (matching aspectLockedPixelRect's pixel-space
    ///      comparison), then converted to a normalized side via the width divisor.
    ///      The old code compared dxN (÷width) vs dyN (÷height) — incomparable units,
    ///      so on non-square videos the box tracked the wrong pointer axis.
    ///   2. The side is clamped to the scale 1...4 range [0.25, 1.0] HERE while still
    ///      rebuilt from the fixed anchor — so hitting the min-size floor keeps the
    ///      anchor corner put, instead of letting clampAspectLockedBox re-anchor on
    ///      the box center (which made BOTH corners jump at the floor).
    static func resizedAspectLockedBox(initial: CGRect, corner: Corner,
                                       translationPx: CGSize, videoRect: CGRect) -> CGRect {
        guard videoRect.width > 0, videoRect.height > 0 else { return initial }

        // Anchor = corner opposite the dragged one (stays fixed).
        let anchor: CGPoint
        switch corner {
        case .tl: anchor = CGPoint(x: initial.maxX, y: initial.maxY)
        case .tr: anchor = CGPoint(x: initial.minX, y: initial.maxY)
        case .bl: anchor = CGPoint(x: initial.maxX, y: initial.minY)
        case .br: anchor = CGPoint(x: initial.minX, y: initial.minY)
        }

        // The dragged corner's start position (normalized) and its post-drag
        // candidate, applying the drag delta in normalized space per axis.
        let dxN = translationPx.width / videoRect.width
        let dyN = translationPx.height / videoRect.height
        let startCorner: CGPoint
        switch corner {
        case .tl: startCorner = CGPoint(x: initial.minX, y: initial.minY)
        case .tr: startCorner = CGPoint(x: initial.maxX, y: initial.minY)
        case .bl: startCorner = CGPoint(x: initial.minX, y: initial.maxY)
        case .br: startCorner = CGPoint(x: initial.maxX, y: initial.maxY)
        }
        let movingX = startCorner.x + dxN
        let movingY = startCorner.y + dyN

        // Which side of the anchor the box extends toward.
        let signX: CGFloat = (movingX >= anchor.x) ? 1 : -1
        let signY: CGFloat = (movingY >= anchor.y) ? 1 : -1

        // Aspect lock: pick the side from the LARGER PIXEL displacement of the
        // dragged corner from the anchor (pixel-space comparison, matching
        // aspectLockedPixelRect). Convert to a normalized side via the width divisor
        // (a normalized-square maps to a videoRect-aspect pixel rect).
        let pxFromAnchorX = abs(movingX - anchor.x) * videoRect.width
        let pxFromAnchorY = abs(movingY - anchor.y) * videoRect.height
        let sidePx = max(pxFromAnchorX, pxFromAnchorY)
        var side = sidePx / videoRect.width

        // Clamp to scale 1...4 (side in [0.25, 1.0]) while STILL anchored on the
        // fixed corner — so the floor doesn't trigger a center re-anchor downstream.
        side = min(1.0, max(0.25, side))

        let x0 = (signX > 0) ? anchor.x : anchor.x - side
        let y0 = (signY > 0) ? anchor.y : anchor.y - side
        return CGRect(x: x0, y: y0, width: side, height: side)
    }
}

// MARK: - Spotlight overlay

/// Dims the video outside a box (the highlighted region). Active during
/// playback; when paused with a spotlight selected, the box is editable
/// (drag to move, corners to resize — free aspect).
struct SpotlightOverlay: View {
    @ObservedObject var state: EditorState
    let videoRect: CGRect
    @State private var dragInitial: CGRect?

    enum Corner { case tl, tr, bl, br }

    var body: some View {
        // Only the spotlight ACTIVE at the playhead renders; the box is editable
        // when paused and that active spotlight is the selected one.
        let seg = state.spotlight(at: state.playhead)
        let editing = !state.isPlaying && seg != nil && seg?.id == state.selectedSpotlightID
        if let seg, videoRect.width > 1 {
            let pr = ZoomBoxOverlay.normToPixel(seg.box, in: videoRect)
            let shortSide = min(pr.width, pr.height)
            let corner = seg.roundness * shortSide
            let featherPx = max(0, seg.feather * shortSide)
            // Extend the outer rect past the video so feather blur fades only the
            // HOLE edge, not the video's own border (we mask back to videoRect).
            let outer = videoRect.insetBy(dx: -featherPx * 2 - 2, dy: -featherPx * 2 - 2)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(outer)
                    p.addRoundedRect(in: pr, cornerSize: CGSize(width: corner, height: corner))
                }
                .fill(Color.black.opacity(seg.dim), style: FillStyle(eoFill: true))
                .blur(radius: featherPx)
                .mask(
                    Rectangle()
                        .frame(width: videoRect.width, height: videoRect.height)
                        .position(x: videoRect.midX, y: videoRect.midY)
                )
                .allowsHitTesting(false)

                if editing { boxEditor(seg: seg, pr: pr) }
            }
        }
    }

    @ViewBuilder
    private func boxEditor(seg: SpotlightSegment, pr: CGRect) -> some View {
        let handle: CGFloat = 12
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 2)
                .background(Color.white.opacity(0.06))
                .frame(width: pr.width, height: pr.height)
                .contentShape(Rectangle())
                .gesture(moveGesture(seg))
            corner(.tl, pr, handle, seg)
            corner(.tr, pr, handle, seg)
            corner(.bl, pr, handle, seg)
            corner(.br, pr, handle, seg)
        }
        .offset(x: pr.minX, y: pr.minY)
    }

    private func corner(_ c: Corner, _ pr: CGRect, _ size: CGFloat, _ seg: SpotlightSegment) -> some View {
        let pos: CGPoint
        switch c {
        case .tl: pos = CGPoint(x: 0, y: 0)
        case .tr: pos = CGPoint(x: pr.width, y: 0)
        case .bl: pos = CGPoint(x: 0, y: pr.height)
        case .br: pos = CGPoint(x: pr.width, y: pr.height)
        }
        return Circle().fill(.white).overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
            .frame(width: size, height: size)
            .position(x: pos.x, y: pos.y)
            .gesture(resizeGesture(seg, c))
    }

    private func moveGesture(_ seg: SpotlightSegment) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("forgePreview"))
            .onChanged { v in
                if dragInitial == nil { dragInitial = seg.box; state.beginEdit() }
                guard let i = dragInitial, videoRect.width > 0 else { return }
                var b = i
                b.origin.x += v.translation.width / videoRect.width
                b.origin.y += v.translation.height / videoRect.height
                state.updateSpotlightBox(for: seg.id, to: b)
            }
            .onEnded { _ in dragInitial = nil }
    }

    private func resizeGesture(_ seg: SpotlightSegment, _ c: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("forgePreview"))
            .onChanged { v in
                if dragInitial == nil { dragInitial = seg.box; state.beginEdit() }
                guard let i = dragInitial, videoRect.width > 0 else { return }
                let dx = v.translation.width / videoRect.width
                let dy = v.translation.height / videoRect.height
                var b = i
                switch c {
                case .tl: b.origin.x += dx; b.size.width -= dx; b.origin.y += dy; b.size.height -= dy
                case .tr: b.size.width += dx; b.origin.y += dy; b.size.height -= dy
                case .bl: b.origin.x += dx; b.size.width -= dx; b.size.height += dy
                case .br: b.size.width += dx; b.size.height += dy
                }
                state.updateSpotlightBox(for: seg.id, to: b)
            }
            .onEnded { _ in dragInitial = nil }
    }
}

// MARK: - Blur box editor

/// Editable box for the selected blur region (the blur itself is drawn by the
/// player view). Visible when paused with a blur selected.
struct BlurOverlay: View {
    @ObservedObject var state: EditorState
    let videoRect: CGRect
    @State private var dragInitial: CGRect?

    enum Corner { case tl, tr, bl, br }

    var body: some View {
        // Editable box only for the blur ACTIVE at the playhead + selected.
        let active = state.blur(at: state.playhead)
        if !state.isPlaying, let seg = active, seg.id == state.selectedBlurID, videoRect.width > 1 {
            let pr = ZoomBoxOverlay.normToPixel(seg.box, in: videoRect)
            let handle: CGFloat = 12
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: pr.width, height: pr.height)
                    .contentShape(Rectangle())
                    .gesture(moveGesture(seg))
                corner(.tl, pr, handle, seg)
                corner(.tr, pr, handle, seg)
                corner(.bl, pr, handle, seg)
                corner(.br, pr, handle, seg)
            }
            .offset(x: pr.minX, y: pr.minY)
        }
    }

    private func corner(_ c: Corner, _ pr: CGRect, _ size: CGFloat, _ seg: BlurSegment) -> some View {
        let pos: CGPoint
        switch c {
        case .tl: pos = CGPoint(x: 0, y: 0)
        case .tr: pos = CGPoint(x: pr.width, y: 0)
        case .bl: pos = CGPoint(x: 0, y: pr.height)
        case .br: pos = CGPoint(x: pr.width, y: pr.height)
        }
        return Circle().fill(.white).overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
            .frame(width: size, height: size)
            .position(x: pos.x, y: pos.y)
            .gesture(resizeGesture(seg, c))
    }

    private func moveGesture(_ seg: BlurSegment) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("forgePreview"))
            .onChanged { v in
                if dragInitial == nil { dragInitial = seg.box; state.beginEdit() }
                guard let i = dragInitial, videoRect.width > 0 else { return }
                var b = i
                b.origin.x += v.translation.width / videoRect.width
                b.origin.y += v.translation.height / videoRect.height
                state.updateBlurBox(for: seg.id, to: b)
            }
            .onEnded { _ in dragInitial = nil }
    }

    private func resizeGesture(_ seg: BlurSegment, _ c: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("forgePreview"))
            .onChanged { v in
                if dragInitial == nil { dragInitial = seg.box; state.beginEdit() }
                guard let i = dragInitial, videoRect.width > 0 else { return }
                let dx = v.translation.width / videoRect.width
                let dy = v.translation.height / videoRect.height
                var b = i
                switch c {
                case .tl: b.origin.x += dx; b.size.width -= dx; b.origin.y += dy; b.size.height -= dy
                case .tr: b.size.width += dx; b.origin.y += dy; b.size.height -= dy
                case .bl: b.origin.x += dx; b.size.width -= dx; b.size.height += dy
                case .br: b.size.width += dx; b.size.height += dy
                }
                state.updateBlurBox(for: seg.id, to: b)
            }
            .onEnded { _ in dragInitial = nil }
    }
}

// MARK: - Timeline

// Named ZoomTimelineView (not "TimelineView") so this module-level type does not
// shadow SwiftUI's `TimelineView`, which MenuBarView relies on. It is an internal
// subview of the editor and not part of the editor's external contract.
struct ZoomTimelineView: View {
    @ObservedObject var state: EditorState
    let player: AVPlayer

    @State private var dragInitial: (start: Double, end: Double)?
    @State private var dragInitialSpeed: (start: Double, end: Double)?
    @State private var dragInitialCut: (start: Double, end: Double)?
    @State private var dragInitialSpot: (start: Double, end: Double)?
    @State private var dragInitialBlur: (start: Double, end: Double)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            transportRow
                .onChange(of: state.seekRequest) { _, t in
                    if let t { seek(to: t); state.seekRequest = nil }   // reveal a selected element
                }

            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let dur = max(0.0001, state.duration)
                // Two lanes: zoom blocks on top, speed regions below.
                let zoomLaneH = height * 0.56
                let speedTop = zoomLaneH + 4
                let speedLaneH = max(12, height - speedTop - 2)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )

                    // Scrub layer (taps + drags seek). While scrubbing, the player's
                    // periodic observer is suppressed (state.isScrubbing) so it can't
                    // overwrite the just-set playhead with stale async player time.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    state.isScrubbing = true
                                    if state.isPlaying { pause() }
                                    seek(to: Double(v.location.x / max(1, width)) * dur)
                                }
                                .onEnded { _ in
                                    state.isScrubbing = false
                                }
                        )

                    // Zoom blocks (top lane).
                    ForEach(state.segments) { seg in
                        let x = CGFloat(seg.start / dur) * width
                        let w = max(8, CGFloat((seg.end - seg.start) / dur) * width)
                        segmentBlock(seg: seg, x: x, w: w, height: zoomLaneH, trackWidth: width, dur: dur)
                    }

                    // Speed regions (bottom lane).
                    ForEach(state.speedSegments) { seg in
                        let x = CGFloat(seg.start / dur) * width
                        let w = max(8, CGFloat((seg.end - seg.start) / dur) * width)
                        speedBlock(seg: seg, x: x, w: w, laneH: speedLaneH, top: speedTop,
                                   trackWidth: width, dur: dur)
                    }

                    // Spotlight regions (top lane, yellow).
                    ForEach(state.spotlights) { sp in
                        let x = CGFloat(sp.start / dur) * width
                        let w = max(8, CGFloat((sp.end - sp.start) / dur) * width)
                        spotlightBlock(seg: sp, x: x, w: w, height: zoomLaneH, trackWidth: width, dur: dur)
                    }

                    // Blur regions (top lane, cyan).
                    ForEach(state.blurs) { bl in
                        let x = CGFloat(bl.start / dur) * width
                        let w = max(8, CGFloat((bl.end - bl.start) / dur) * width)
                        blurBlock(seg: bl, x: x, w: w, height: zoomLaneH, trackWidth: width, dur: dur)
                    }

                    // Cut regions (removed spans, full height).
                    ForEach(state.cuts) { cut in
                        let x = CGFloat(cut.start / dur) * width
                        let w = max(6, CGFloat((cut.end - cut.start) / dur) * width)
                        cutBlock(cut: cut, x: x, w: w, height: height, trackWidth: width, dur: dur)
                    }

                    // Playhead.
                    let phx = CGFloat(state.playhead / dur) * width
                    Rectangle()
                        .fill(Color.forgeAccent)
                        .frame(width: 2, height: height)
                        .offset(x: max(0, min(width - 2, phx)))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: Transport

    private var transportRow: some View {
        HStack(spacing: 12) {
            Button { restart() } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.borderless)
            .help("Jump to start")

            Button { togglePlay() } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .help(state.isPlaying ? "Pause" : "Play")

            Text(timeString(state.playhead))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            if state.speed != 1.0 {
                Text(String(format: "%g×", state.speed))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.forgeAccent)
            }
            // Result length after cuts + speed, when it differs from the source.
            if state.hasEdits {
                Label(timeString(state.outputDuration), systemImage: "scissors")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.forgeAccent)
            }
            Text(timeString(state.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func togglePlay() { state.isPlaying ? pause() : play() }

    private func play() {
        // Restart from the beginning if we're at/after the edited output's end.
        if state.sourceToOutput(state.playhead) >= state.outputDuration - 0.03 {
            seek(to: state.outputToSource(0))
        }
        state.isPlaying = true
        player.play()                 // rate 1 — speed is baked into the composition
    }

    private func pause() {
        state.isPlaying = false
        player.pause()
    }

    private func restart() { seek(to: state.outputToSource(0)) }


    @ViewBuilder
    private func segmentBlock(seg: ZoomSegment, x: CGFloat, w: CGFloat,
                              height: CGFloat, trackWidth: CGFloat, dur: Double) -> some View {
        let isSelected = state.selectedSegmentID == seg.id
        let edge: CGFloat = 8

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.forgeAccent.opacity(0.55) : Color.forgeAccent.opacity(0.30))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.forgeAccent, lineWidth: isSelected ? 2 : 1)
                )
                .frame(width: w, height: height - 4)
                .contentShape(Rectangle())
                .onTapGesture { state.selectSegment(seg.id) }
                .gesture(bodyDrag(seg: seg, trackWidth: trackWidth, dur: dur))

            // Left edge resize.
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: edge, height: height - 4)
                .contentShape(Rectangle())
                .gesture(edgeDrag(seg: seg, left: true, trackWidth: trackWidth, dur: dur))

            // Right edge resize.
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: edge, height: height - 4)
                .contentShape(Rectangle())
                .offset(x: w - edge)
                .gesture(edgeDrag(seg: seg, left: false, trackWidth: trackWidth, dur: dur))

            Text(String(format: "%.1f×", seg.scale))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.leading, 6)
                .allowsHitTesting(false)
        }
        .frame(width: w, height: height - 4, alignment: .leading)
        .offset(x: x, y: 2)
    }

    private func bodyDrag(seg: ZoomSegment, trackWidth: CGFloat, dur: Double) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragInitial == nil {
                    dragInitial = (seg.start, seg.end)
                    state.beginEdit()
                    state.clearSelection(); state.selectedSegmentID = seg.id
                }
                guard let init0 = dragInitial else { return }
                let dt = Double(v.translation.width / max(1, trackWidth)) * dur
                let len = init0.end - init0.start
                var newStart = init0.start + dt
                newStart = max(0, min(newStart, state.duration - len))
                state.updateTiming(for: seg.id, start: newStart, end: newStart + len, snapshotFirst: false)
            }
            .onEnded { _ in dragInitial = nil }
    }

    private func edgeDrag(seg: ZoomSegment, left: Bool, trackWidth: CGFloat, dur: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragInitial == nil {
                    dragInitial = (seg.start, seg.end)
                    state.beginEdit()
                    state.clearSelection(); state.selectedSegmentID = seg.id
                }
                guard let init0 = dragInitial else { return }
                let dt = Double(v.translation.width / max(1, trackWidth)) * dur
                if left {
                    var s = init0.start + dt
                    s = max(0, min(s, init0.end - 0.1))
                    state.updateTiming(for: seg.id, start: s, end: init0.end, snapshotFirst: false)
                } else {
                    var e = init0.end + dt
                    e = min(state.duration, max(e, init0.start + 0.1))
                    state.updateTiming(for: seg.id, start: init0.start, end: e, snapshotFirst: false)
                }
            }
            .onEnded { _ in dragInitial = nil }
    }

    // MARK: Speed blocks (bottom lane)

    @ViewBuilder
    private func speedBlock(seg: SpeedSegment, x: CGFloat, w: CGFloat, laneH: CGFloat,
                            top: CGFloat, trackWidth: CGFloat, dur: Double) -> some View {
        let isSelected = state.selectedSpeedID == seg.id
        let color = Color(white: 0.55)
        let edge: CGFloat = 8

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? color.opacity(0.6) : color.opacity(0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Color.forgeAccent : color, lineWidth: isSelected ? 2 : 1)
                )
                .frame(width: w, height: laneH)
                .contentShape(Rectangle())
                .onTapGesture { state.selectSpeed(seg.id) }
                .gesture(speedBodyDrag(seg: seg, trackWidth: trackWidth, dur: dur))

            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: edge, height: laneH).contentShape(Rectangle())
                .gesture(speedEdgeDrag(seg: seg, left: true, trackWidth: trackWidth, dur: dur))
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: edge, height: laneH).contentShape(Rectangle())
                .offset(x: w - edge)
                .gesture(speedEdgeDrag(seg: seg, left: false, trackWidth: trackWidth, dur: dur))

            Text(String(format: "%g×", seg.factor))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.leading, 6)
                .allowsHitTesting(false)
        }
        .frame(width: w, height: laneH, alignment: .leading)
        .offset(x: x, y: top)
    }

    private func speedBodyDrag(seg: SpeedSegment, trackWidth: CGFloat, dur: Double) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragInitialSpeed == nil {
                    dragInitialSpeed = (seg.start, seg.end)
                    state.beginEdit()
                    state.clearSelection(); state.selectedSpeedID = seg.id
                }
                guard let init0 = dragInitialSpeed else { return }
                let dt = Double(v.translation.width / max(1, trackWidth)) * dur
                let len = init0.end - init0.start
                var ns = init0.start + dt
                ns = max(0, min(ns, state.duration - len))
                state.updateSpeedTiming(for: seg.id, start: ns, end: ns + len, snapshotFirst: false)
            }
            .onEnded { _ in dragInitialSpeed = nil; state.bumpTimeline() }
    }

    private func speedEdgeDrag(seg: SpeedSegment, left: Bool, trackWidth: CGFloat, dur: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragInitialSpeed == nil {
                    dragInitialSpeed = (seg.start, seg.end)
                    state.beginEdit()
                    state.clearSelection(); state.selectedSpeedID = seg.id
                }
                guard let init0 = dragInitialSpeed else { return }
                let dt = Double(v.translation.width / max(1, trackWidth)) * dur
                if left {
                    var s = init0.start + dt
                    s = max(0, min(s, init0.end - 0.1))
                    state.updateSpeedTiming(for: seg.id, start: s, end: init0.end, snapshotFirst: false)
                } else {
                    var e = init0.end + dt
                    e = min(state.duration, max(e, init0.start + 0.1))
                    state.updateSpeedTiming(for: seg.id, start: init0.start, end: e, snapshotFirst: false)
                }
            }
            .onEnded { _ in dragInitialSpeed = nil; state.bumpTimeline() }
    }

    // MARK: Spotlight blocks (top lane)

    @ViewBuilder
    private func spotlightBlock(seg: SpotlightSegment, x: CGFloat, w: CGFloat, height: CGFloat,
                                trackWidth: CGFloat, dur: Double) -> some View {
        let isSelected = state.selectedSpotlightID == seg.id
        let color = Color(white: 0.55)
        let edge: CGFloat = 8
        let h = height - 4
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? color.opacity(0.55) : color.opacity(0.30))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isSelected ? Color.forgeAccent : color, lineWidth: isSelected ? 2 : 1))
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .onTapGesture { state.selectSpotlight(seg.id) }
                .gesture(spotBodyDrag(seg: seg, trackWidth: trackWidth, dur: dur))
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: edge, height: h).contentShape(Rectangle())
                .gesture(spotEdgeDrag(seg: seg, left: true, trackWidth: trackWidth, dur: dur))
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: edge, height: h).contentShape(Rectangle())
                .offset(x: w - edge)
                .gesture(spotEdgeDrag(seg: seg, left: false, trackWidth: trackWidth, dur: dur))
            Image(systemName: "circle.dashed").font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black.opacity(0.7)).padding(.leading, 6).allowsHitTesting(false)
        }
        .frame(width: w, height: h, alignment: .leading)
        .offset(x: x, y: 2)
    }

    private func spotBodyDrag(seg: SpotlightSegment, trackWidth: CGFloat, dur: Double) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragInitialSpot == nil {
                    dragInitialSpot = (seg.start, seg.end); state.beginEdit()
                    state.clearSelection(); state.selectedSpotlightID = seg.id
                }
                guard let i = dragInitialSpot else { return }
                let dt = Double(v.translation.width / max(1, trackWidth)) * dur
                let len = i.end - i.start
                var ns = i.start + dt
                ns = max(0, min(ns, state.duration - len))
                state.updateSpotlightTiming(for: seg.id, start: ns, end: ns + len, snapshotFirst: false)
            }
            .onEnded { _ in dragInitialSpot = nil }
    }

    private func spotEdgeDrag(seg: SpotlightSegment, left: Bool, trackWidth: CGFloat, dur: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragInitialSpot == nil {
                    dragInitialSpot = (seg.start, seg.end); state.beginEdit()
                    state.clearSelection(); state.selectedSpotlightID = seg.id
                }
                guard let i = dragInitialSpot else { return }
                let dt = Double(v.translation.width / max(1, trackWidth)) * dur
                if left {
                    var s = i.start + dt; s = max(0, min(s, i.end - 0.1))
                    state.updateSpotlightTiming(for: seg.id, start: s, end: i.end, snapshotFirst: false)
                } else {
                    var e = i.end + dt; e = min(state.duration, max(e, i.start + 0.1))
                    state.updateSpotlightTiming(for: seg.id, start: i.start, end: e, snapshotFirst: false)
                }
            }
            .onEnded { _ in dragInitialSpot = nil }
    }

    // MARK: Blur blocks (top lane)

    @ViewBuilder
    private func blurBlock(seg: BlurSegment, x: CGFloat, w: CGFloat, height: CGFloat,
                           trackWidth: CGFloat, dur: Double) -> some View {
        let isSelected = state.selectedBlurID == seg.id
        let color = Color(white: 0.55)
        let edge: CGFloat = 8
        let h = height - 4
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? color.opacity(0.5) : color.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isSelected ? Color.forgeAccent : color, lineWidth: isSelected ? 2 : 1))
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .onTapGesture { state.selectBlur(seg.id) }
                .gesture(blurBodyDrag(seg: seg, trackWidth: trackWidth, dur: dur))
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: edge, height: h).contentShape(Rectangle())
                .gesture(blurEdgeDrag(seg: seg, left: true, trackWidth: trackWidth, dur: dur))
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: edge, height: h).contentShape(Rectangle())
                .offset(x: w - edge)
                .gesture(blurEdgeDrag(seg: seg, left: false, trackWidth: trackWidth, dur: dur))
            Image(systemName: "drop.fill").font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black.opacity(0.6)).padding(.leading, 6).allowsHitTesting(false)
        }
        .frame(width: w, height: h, alignment: .leading)
        .offset(x: x, y: 2)
    }

    private func blurBodyDrag(seg: BlurSegment, trackWidth: CGFloat, dur: Double) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragInitialBlur == nil {
                    dragInitialBlur = (seg.start, seg.end); state.beginEdit()
                    state.clearSelection(); state.selectedBlurID = seg.id
                }
                guard let i = dragInitialBlur else { return }
                let dt = Double(v.translation.width / max(1, trackWidth)) * dur
                let len = i.end - i.start
                var ns = i.start + dt
                ns = max(0, min(ns, state.duration - len))
                state.updateBlurTiming(for: seg.id, start: ns, end: ns + len, snapshotFirst: false)
            }
            .onEnded { _ in dragInitialBlur = nil }
    }

    private func blurEdgeDrag(seg: BlurSegment, left: Bool, trackWidth: CGFloat, dur: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragInitialBlur == nil {
                    dragInitialBlur = (seg.start, seg.end); state.beginEdit()
                    state.clearSelection(); state.selectedBlurID = seg.id
                }
                guard let i = dragInitialBlur else { return }
                let dt = Double(v.translation.width / max(1, trackWidth)) * dur
                if left {
                    var s = i.start + dt; s = max(0, min(s, i.end - 0.1))
                    state.updateBlurTiming(for: seg.id, start: s, end: i.end, snapshotFirst: false)
                } else {
                    var e = i.end + dt; e = min(state.duration, max(e, i.start + 0.1))
                    state.updateBlurTiming(for: seg.id, start: i.start, end: e, snapshotFirst: false)
                }
            }
            .onEnded { _ in dragInitialBlur = nil }
    }

    // MARK: Cut regions (removed spans)

    @ViewBuilder
    private func cutBlock(cut: CutRange, x: CGFloat, w: CGFloat, height: CGFloat,
                          trackWidth: CGFloat, dur: Double) -> some View {
        let isSelected = state.selectedCutID == cut.id
        let edge: CGFloat = 7

        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? Color.forgeAccent : Color(white: 0.62).opacity(0.9),
                                      style: StrokeStyle(lineWidth: isSelected ? 2 : 1.5, dash: [3]))
                )
                .frame(width: w, height: height)
                .contentShape(Rectangle())
                .onTapGesture { state.selectCut(cut.id) }
                .gesture(cutBodyDrag(cut: cut, trackWidth: trackWidth, dur: dur))

            Image(systemName: "scissors")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white).allowsHitTesting(false)

            HStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.001))
                    .frame(width: edge).contentShape(Rectangle())
                    .gesture(cutEdgeDrag(cut: cut, left: true, trackWidth: trackWidth, dur: dur))
                Spacer(minLength: 0)
                Rectangle().fill(Color.white.opacity(0.001))
                    .frame(width: edge).contentShape(Rectangle())
                    .gesture(cutEdgeDrag(cut: cut, left: false, trackWidth: trackWidth, dur: dur))
            }
            .frame(width: w, height: height)
        }
        .frame(width: w, height: height)
        .offset(x: x, y: 0)
    }

    private func cutBodyDrag(cut: CutRange, trackWidth: CGFloat, dur: Double) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragInitialCut == nil {
                    dragInitialCut = (cut.start, cut.end)
                    state.beginEdit()
                    state.clearSelection(); state.selectedCutID = cut.id
                }
                guard let init0 = dragInitialCut else { return }
                let dt = Double(v.translation.width / max(1, trackWidth)) * dur
                let len = init0.end - init0.start
                var ns = init0.start + dt
                ns = max(0, min(ns, state.duration - len))
                state.updateCutTiming(for: cut.id, start: ns, end: ns + len, snapshotFirst: false)
            }
            .onEnded { _ in dragInitialCut = nil; state.bumpTimeline() }
    }

    private func cutEdgeDrag(cut: CutRange, left: Bool, trackWidth: CGFloat, dur: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragInitialCut == nil {
                    dragInitialCut = (cut.start, cut.end)
                    state.beginEdit()
                    state.clearSelection(); state.selectedCutID = cut.id
                }
                guard let init0 = dragInitialCut else { return }
                let dt = Double(v.translation.width / max(1, trackWidth)) * dur
                if left {
                    var s = init0.start + dt
                    s = max(0, min(s, init0.end - 0.1))
                    state.updateCutTiming(for: cut.id, start: s, end: init0.end, snapshotFirst: false)
                } else {
                    var e = init0.end + dt
                    e = min(state.duration, max(e, init0.start + 0.1))
                    state.updateCutTiming(for: cut.id, start: init0.start, end: e, snapshotFirst: false)
                }
            }
            .onEnded { _ in dragInitialCut = nil; state.bumpTimeline() }
    }

    /// `t` is SOURCE time; the player runs on OUTPUT time, so map before seeking.
    private func seek(to t: Double) {
        let s = max(0, min(state.duration, t))
        state.playhead = s
        let out = state.sourceToOutput(s)
        player.seek(to: CMTime(seconds: out, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Toolbar

struct ToolbarView: View {
    @ObservedObject var state: EditorState
    let track: InteractionTrack
    @Binding var isAddingZoom: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isAddingZoom.toggle()
            } label: {
                Label(isAddingZoom ? "Drawing… drag on preview" : "Add Zoom",
                      systemImage: "plus.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .tint(isAddingZoom ? Color.forgeAccent.opacity(0.65) : Color.forgeAccent)
            .help("Drag a rectangle on the preview to define the zoom region")

            Button {
                isAddingZoom = false
                state.autoZoom(from: track)
            } label: {
                Label("Auto-zoom", systemImage: "wand.and.stars")
            }
            .help("Generate zoom segments from recorded clicks (you can then edit them)")

            Button {
                isAddingZoom = false
                state.addSpeedSegment(at: state.playhead)
            } label: {
                Label("Add Speed", systemImage: "speedometer")
            }
            .help("Add a speed region at the playhead, then set its rate in the inspector")

            Button {
                isAddingZoom = false
                state.addCut(at: state.playhead)
            } label: {
                Label("Add Cut", systemImage: "scissors")
            }
            .help("Cut out a span at the playhead; drag its edges to set the duration")

            Button {
                isAddingZoom = false
                state.addSpotlight(at: state.playhead)
            } label: {
                Label("Spotlight", systemImage: "circle.dashed")
            }
            .help("Highlight a region — dim everything else. Drag the box on the preview.")

            Button {
                isAddingZoom = false
                state.addBlur(at: state.playhead)
            } label: {
                Label("Blur", systemImage: "drop.fill")
            }
            .help("Blur/redact a region. Drag the box on the preview; set strength in the inspector.")

            Divider().frame(height: 18)

            Button(role: .destructive) {
                if state.selectedBlurID != nil { state.deleteSelectedBlur() }
                else if state.selectedSpotlightID != nil { state.deleteSelectedSpotlight() }
                else if state.selectedCutID != nil { state.deleteSelectedCut() }
                else if state.selectedSpeedID != nil { state.deleteSelectedSpeed() }
                else { state.deleteSelected() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(state.selectedSegmentID == nil && state.selectedSpeedID == nil
                      && state.selectedCutID == nil && state.selectedSpotlightID == nil
                      && state.selectedBlurID == nil)

            Button {
                state.resetTimeline()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .disabled(state.segments.isEmpty && state.speedSegments.isEmpty
                      && state.cuts.isEmpty && state.spotlights.isEmpty && state.blurs.isEmpty)

            Spacer()

            Button {
                state.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!state.canUndo)
            .help("Undo")

            Button {
                state.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!state.canRedo)
            .help("Redo")
        }
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @ObservedObject var state: EditorState
    let onExport: () -> Void

    enum BgTab: CaseIterable {
        case wallpaper, gradient, color
        var title: String {
            switch self {
            case .wallpaper: return "Wallpaper"
            case .gradient:  return "Gradient"
            case .color:     return "Color"
            }
        }
    }
    @State private var bgTab: BgTab = .wallpaper

    var body: some View {
      ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                if state.hasSelection {
                    Button { state.clearSelection() } label: {
                        Label("All settings", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(Color.forgeAccent)
                }

                if !state.hasSelection {
                section("Background") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("", selection: $bgTab) {
                            ForEach(BgTab.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        switch bgTab {
                        case .wallpaper: wallpaperTab
                        case .gradient:  gradientTab
                        case .color:     colorTab
                        }

                        labeledSlider("Background blur", value: $state.backgroundBlur,
                                      range: 0...40, fmt: "%.0f")

                        Button { state.background = .hidden } label: {
                            Label("No background", systemImage: "nosign")
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(state.background == .hidden ? Color.forgeAccent : .secondary)
                    }
                }

                Divider()

                section("Frame") {
                    VStack(alignment: .leading, spacing: 10) {
                        labeledSlider("Corner radius", value: $state.cornerRadius, range: 0...40, fmt: "%.0f")
                        labeledSlider("Padding", value: $state.padding, range: 0...0.2, fmt: "%.2f")
                        Toggle("Shadow", isOn: $state.shadow)
                    }
                }

                Divider()

                section("Cursor") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show cursor", isOn: $state.showCursor)
                        if state.showCursor {
                            labeledSlider("Cursor size", value: $state.cursorScale,
                                          range: 1.0...4.0, fmt: "%.1f×")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Style").font(.callout)
                                Picker("", selection: $state.cursorStyle) {
                                    ForEach(CursorStyle.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented).labelsHidden()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Click effect").font(.callout)
                                Picker("", selection: $state.clickEffect) {
                                    ForEach(ClickEffect.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented).labelsHidden()
                            }
                            Toggle("Hide cursor when idle", isOn: $state.hideCursorWhenIdle)
                        }
                        Text("The real cursor is hidden while recording; this draws an enlarged one. Click sound is coming next.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if state.hasCamera {
                    Divider()
                    section("Camera") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Show camera", isOn: $state.cameraVisible)
                            if state.cameraVisible {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Layout").font(.callout)
                                    Picker("", selection: $state.cameraLayout) {
                                        ForEach(CameraLayout.allCases) { Text($0.title).tag($0) }
                                    }
                                    .pickerStyle(.segmented).labelsHidden()
                                }
                                if state.cameraLayout == .bubble {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Shape").font(.callout)
                                        Picker("", selection: $state.cameraShape) {
                                            ForEach(CameraShape.allCases) { Text($0.title).tag($0) }
                                        }
                                        .pickerStyle(.segmented).labelsHidden()
                                    }
                                    if !state.cameraPath.isEmpty {
                                        Toggle("Follow recorded movement", isOn: Binding(
                                            get: { state.cameraFollowsPath },
                                            set: { on in
                                                if on { state.cameraFollowsPath = true }
                                                else { state.pinCameraToCurrent() }
                                            }))
                                    }
                                    labeledSlider("Size", value: Binding(
                                        get: { state.cameraSample(at: state.playhead).h },
                                        set: { state.pinCameraToCurrent(); state.cameraHeightFrac = $0 }),
                                        range: 0.05...0.8, fmt: "%.2f")
                                    Button("Reset position") { state.resetCameraPosition() }
                                        .controlSize(.small)
                                }
                            }
                            Text(state.cameraPath.isEmpty
                                 ? "Drag the bubble on the preview to move it; drag its corner to resize."
                                 : "Your avatar replays the movement you made while recording. Drag it here to pin it to a fixed spot instead.")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Divider()

                section("Motion") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Zoom & pan").font(.callout)
                            Picker("", selection: $state.zoomMovement) {
                                ForEach(MovementSpeed.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cursor").font(.callout)
                            Picker("", selection: $state.cursorMovement) {
                                ForEach(MovementSpeed.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                        Text("Slower = smoother, gentler glide. Motion blur is coming next.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                section("Playback") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Speed (whole recording)").font(.callout)
                            speedControl($state.speed)
                            Text("Type any value (e.g. 3) or use a preset. For part of the recording, select a Speed region on the timeline.")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cut").font(.callout)
                            Text("Use “Add Cut” to remove a span from anywhere — start, middle, or end. Drag a cut's edges to set its length. Playback and export skip it.")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                }   // end global panel (shown only when nothing is selected)

                Color.clear.frame(height: 0).id("selectionAnchor")

                if let sp = state.selectedSpeed {
                    section("Speed Region") {
                        VStack(alignment: .leading, spacing: 8) {
                            speedControl(Binding(
                                get: { sp.factor },
                                set: { state.setSpeedFactor(for: sp.id, $0) }
                            ))
                            Text(String(format: "%.1fs – %.1fs", sp.start, sp.end))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) { state.deleteSelectedSpeed() } label: {
                                Label("Delete region", systemImage: "trash")
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if let cut = state.selectedCut {
                    section("Cut") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Duration").font(.callout)
                                Spacer()
                                Text(String(format: "%.1fs", cut.end - cut.start))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Stepper(value: Binding(
                                get: { cut.end - cut.start },
                                set: { newLen in
                                    state.updateCutTiming(for: cut.id, start: cut.start,
                                                          end: cut.start + max(0.1, newLen),
                                                          snapshotFirst: true)
                                    state.bumpTimeline()
                                }
                            ), in: 0.1...max(0.2, state.duration - cut.start), step: 0.1) {
                                Text(String(format: "%.1fs – %.1fs", cut.start, cut.end))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Button(role: .destructive) { state.deleteSelectedCut() } label: {
                                Label("Remove cut", systemImage: "trash")
                            }
                            .controlSize(.small)
                            Text("This span is removed from the final video. Drag its edges on the timeline to adjust.")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let sp = state.selectedSpotlight {
                    section("Spotlight") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Start").frame(width: 46, alignment: .leading)
                                Stepper(value: Binding(get: { sp.start }, set: {
                                    state.updateSpotlightTiming(for: sp.id, start: $0, end: sp.end, snapshotFirst: true)
                                }), in: 0...max(0.1, sp.end - 0.1), step: 0.1) {
                                    Text(String(format: "%.1fs", sp.start)).monospacedDigit()
                                }
                            }
                            HStack {
                                Text("End").frame(width: 46, alignment: .leading)
                                Stepper(value: Binding(get: { sp.end }, set: {
                                    state.updateSpotlightTiming(for: sp.id, start: sp.start, end: $0, snapshotFirst: true)
                                }), in: min(state.duration, sp.start + 0.1)...state.duration, step: 0.1) {
                                    Text(String(format: "%.1fs", sp.end)).monospacedDigit()
                                }
                            }
                            pctSlider("Mask opacity", value: Binding(
                                get: { sp.dim }, set: { state.setSpotlightDim(for: sp.id, $0) }), range: 0...1)
                            pctSlider("Roundness", value: Binding(
                                get: { sp.roundness }, set: { state.setSpotlightRoundness(for: sp.id, $0) }), range: 0...0.5)
                            pctSlider("Feathering", value: Binding(
                                get: { sp.feather }, set: { state.setSpotlightFeather(for: sp.id, $0) }), range: 0...0.3)
                            HStack {
                                Button { state.applySpotlightLookToAll() } label: {
                                    Label("Apply to all", systemImage: "square.on.square")
                                }
                                .controlSize(.small)
                                Spacer()
                                Button(role: .destructive) { state.deleteSelectedSpotlight() } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                .controlSize(.small)
                            }
                            Text("Drag the box on the preview to set the highlighted region.")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let bl = state.selectedBlur {
                    section("Blur") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Start").frame(width: 46, alignment: .leading)
                                Stepper(value: Binding(get: { bl.start }, set: {
                                    state.updateBlurTiming(for: bl.id, start: $0, end: bl.end, snapshotFirst: true)
                                }), in: 0...max(0.1, bl.end - 0.1), step: 0.1) {
                                    Text(String(format: "%.1fs", bl.start)).monospacedDigit()
                                }
                            }
                            HStack {
                                Text("End").frame(width: 46, alignment: .leading)
                                Stepper(value: Binding(get: { bl.end }, set: {
                                    state.updateBlurTiming(for: bl.id, start: bl.start, end: $0, snapshotFirst: true)
                                }), in: min(state.duration, bl.start + 0.1)...state.duration, step: 0.1) {
                                    Text(String(format: "%.1fs", bl.end)).monospacedDigit()
                                }
                            }
                            pctSlider("Strength", value: Binding(
                                get: { bl.strength },
                                set: { state.setBlurStrength(for: bl.id, $0) }
                            ), range: 0.05...1.0)
                            pctSlider("Roundness", value: Binding(
                                get: { bl.roundness },
                                set: { state.setBlurRoundness(for: bl.id, $0) }
                            ), range: 0...0.5)
                            HStack {
                                Button { state.applyBlurLookToAll() } label: {
                                    Label("Apply to all", systemImage: "square.on.square")
                                }
                                .controlSize(.small)
                                Spacer()
                                Button(role: .destructive) { state.deleteSelectedBlur() } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                .controlSize(.small)
                            }
                            Text("Drag the box on the preview to set the region.")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let seg = state.selectedSegment {
                    section("Zoom") {
                        segmentInspector(seg)
                    }
                }

                Spacer(minLength: 12)

                Button(action: onExport) {
                    Label("Export Video", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(16)
        }
        .onChange(of: state.selectedSegmentID) { _, v in scrollToSelection(v, proxy) }
        .onChange(of: state.selectedSpeedID) { _, v in scrollToSelection(v, proxy) }
        .onChange(of: state.selectedCutID) { _, v in scrollToSelection(v, proxy) }
        .onChange(of: state.selectedSpotlightID) { _, v in scrollToSelection(v, proxy) }
        .onChange(of: state.selectedBlurID) { _, v in scrollToSelection(v, proxy) }
      }
    }

    /// Bring the selected element's editor into view when something is picked.
    private func scrollToSelection(_ id: UUID?, _ proxy: ScrollViewProxy) {
        guard id != nil else { return }
        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("selectionAnchor", anchor: .top) }
    }

    // MARK: Segment inspector

    @ViewBuilder
    private func segmentInspector(_ seg: ZoomSegment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Start").frame(width: 50, alignment: .leading)
                // Coalesce repeated steps into ONE undo entry via a per-segment,
                // per-field edit token, instead of snapshotting on every 0.1s step.
                Stepper(value: Binding(
                    get: { seg.start },
                    set: { newVal in
                        state.updateTiming(for: seg.id, start: newVal, end: seg.end,
                                           editToken: "start-\(seg.id)")
                    }
                ), in: 0...max(0.1, seg.end - 0.1), step: 0.1, onEditingChanged: { editing in
                    if !editing { state.endCoalescing() }
                }) {
                    Text(String(format: "%.1fs", seg.start)).monospacedDigit()
                }
            }
            HStack {
                Text("End").frame(width: 50, alignment: .leading)
                Stepper(value: Binding(
                    get: { seg.end },
                    set: { newVal in
                        state.updateTiming(for: seg.id, start: seg.start, end: newVal,
                                           editToken: "end-\(seg.id)")
                    }
                ), in: min(state.duration, seg.start + 0.1)...state.duration, step: 0.1,
                   onEditingChanged: { editing in
                    if !editing { state.endCoalescing() }
                }) {
                    Text(String(format: "%.1fs", seg.end)).monospacedDigit()
                }
            }

            Divider()

            Text(String(format: "Zoom: %.2f×", seg.scale))
                .font(.callout).bold()
            Text(String(format: "Box  x %.2f  y %.2f  side %.2f",
                        seg.box.minX, seg.box.minY, seg.box.width))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("Nudge").frame(width: 50, alignment: .leading)
                nudgeButton("arrow.left")  { nudge(seg, dx: -0.02, dy: 0) }
                nudgeButton("arrow.right") { nudge(seg, dx:  0.02, dy: 0) }
                nudgeButton("arrow.up")    { nudge(seg, dx: 0, dy: -0.02) }
                nudgeButton("arrow.down")  { nudge(seg, dx: 0, dy:  0.02) }
            }

            Text("Tip: drag the box on the preview to set the zoom area.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nudgeButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(.bordered)
    }

    private func nudge(_ seg: ZoomSegment, dx: CGFloat, dy: CGFloat) {
        var box = seg.box
        box.origin.x += dx
        box.origin.y += dy
        // Coalesce a burst of nudge clicks into one undo entry. A different control
        // or a drag closes this window (beginEdit / endCoalescing / different token).
        state.commitBox(for: seg.id, to: box, editToken: "nudge-\(seg.id)")
    }

    // MARK: Background tabs

    @ViewBuilder private var wallpaperTab: some View {
        if state.imageBackgrounds.isEmpty {
            Text("No wallpapers found. Drop images in Forge/Resources/RecordingBackgrounds/.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button { state.randomWallpaper() } label: {
                Label("Pick random wallpaper", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                ForEach(Array(state.imageBackgrounds.enumerated()), id: \.offset) { _, img in
                    backgroundSwatch(img)
                }
            }
        }
    }

    @ViewBuilder private var gradientTab: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
            ForEach(Array(EditorBackground.gradientPresets.enumerated()), id: \.offset) { _, g in
                backgroundSwatch(g)
            }
        }
    }

    @ViewBuilder private var colorTab: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
            ForEach(Array(EditorBackground.colorPresets.enumerated()), id: \.offset) { _, color in
                backgroundSwatch(.solid(color))
            }
        }
    }

    // MARK: Swatches

    private func backgroundSwatch(_ preset: EditorBackground) -> some View {
        let selected = state.background == preset
        return Button {
            state.background = preset
        } label: {
            swatchShape(for: preset)
                .overlay(selectionRing(selected))
        }
        .buttonStyle(.plain)
        .help(preset.displayName)
    }

    @ViewBuilder
    private func swatchShape(for preset: EditorBackground) -> some View {
        switch preset {
        case .gradient(let top, let bottom, _):
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(
                    colors: [Color(nsColor: top), Color(nsColor: bottom)],
                    startPoint: .top, endPoint: .bottom))
                .frame(height: 40)
        case .solid(let c):
            RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: c)).frame(height: 40)
        case .image(_, let url):
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.4)).frame(height: 40)
            }
        case .hidden:
            RoundedRectangle(cornerRadius: 8).fill(Color.clear).frame(height: 40)
        }
    }

    private func selectionRing(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.forgeAccent, lineWidth: selected ? 3 : 0)
    }

    // MARK: Layout helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func labeledSlider(_ label: String, value: Binding<CGFloat>,
                               range: ClosedRange<CGFloat>, fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = CGFloat($0) }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
        }
    }

    /// A slider whose read-out is shown as a 0–100 % of its range.
    private func pctSlider(_ label: String, value: Binding<CGFloat>,
                           range: ClosedRange<CGFloat>) -> some View {
        let span = max(0.0001, range.upperBound - range.lowerBound)
        let pct = Int((((value.wrappedValue - range.lowerBound) / span) * 100).rounded())
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text("\(pct)%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = CGFloat($0) }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
        }
    }

    /// Speed entry that accepts ANY value (type it, step it, or tap a preset).
    /// Uses discrete commits only — no continuous slider — so it never thrashes
    /// the timeline re-bake on every tick.
    @ViewBuilder
    private func speedControl(_ raw: Binding<Double>) -> some View {
        let value = Binding<Double>(
            get: { raw.wrappedValue },
            set: { raw.wrappedValue = min(10, max(0.1, $0.isFinite ? $0 : 1.0)) }
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                Text("×").foregroundStyle(.secondary)
                Stepper("",
                        onIncrement: { value.wrappedValue = min(10, (value.wrappedValue + 0.25)) },
                        onDecrement: { value.wrappedValue = max(0.1, (value.wrappedValue - 0.25)) })
                    .labelsHidden()
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach([0.5, 1.0, 2.0, 3.0, 4.0], id: \.self) { p in
                    Button(speedChipLabel(p)) { value.wrappedValue = p }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(abs(value.wrappedValue - p) < 0.001 ? Color.forgeAccent : Color.gray)
                }
            }
        }
    }
    private func speedChipLabel(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f×", v) : String(format: "%.1f×", v)
    }
}

// MARK: - Export overlay

struct ExportOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// TODO hooks (out of scope — intentionally not implemented):
//   - Trim / speed ramps on the timeline.
//   - Crop tool.
//   - Image backgrounds (.image(URL)) alongside gradient/solid/hidden.
//   - Aspect-ratio canvas presets (16:9, 1:1, 9:16).
//   - Cursor styling (size, highlight, click rings).
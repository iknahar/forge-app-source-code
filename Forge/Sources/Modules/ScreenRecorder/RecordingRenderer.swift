import AVFoundation
import AppKit
import QuartzCore
import CoreImage

// MARK: - Render options

/// A source-time range played at `factor`× (per-part speed). Ranges not covered
/// fall back to the global `RenderOptions.speed`.
struct SpeedRange {
    var start: Double
    var end: Double
    var factor: Double
}

/// One sampled cursor position: `t` source seconds, `(nx, ny)` normalized in the
/// video's space with a TOP-LEFT origin.
struct CursorSample {
    var t: Double
    var nx: Double
    var ny: Double
}

/// A spotlight: dim outside `box` over [start, end] (source seconds). `box` is
/// normalized in the video (top-left).
struct SpotlightRect {
    var start: Double
    var end: Double
    var box: CGRect
    var dim: CGFloat = 0.55       // surround opacity (mask opacity)
    var roundness: CGFloat = 0    // hole corner radius, fraction of short side (0...0.5)
}

/// A blur region over [start, end] (source seconds). `box` normalized top-left;
/// `strength` 0..1 scales the radius.
struct BlurRect {
    var start: Double
    var end: Double
    var box: CGRect
    var strength: CGFloat
    var roundness: CGFloat = 0.08 // corner radius, fraction of short side (0...0.5)
}

/// Styling + output configuration for the offline auto-zoom render pass
/// (the Phase 3b/3c "shared render"). The renderer pads the recorded video
/// inside a gradient background, rounds + optionally shadows the inset video,
/// and drives an auto-zoom-to-cursor camera from the `[ZoomKeyframe]` that
/// `ZoomPlanner` produces.
struct RenderOptions {
    var gradientTop: NSColor
    var gradientBottom: NSColor
    /// Border around the video as a fraction of `min(canvasW, canvasH)`, e.g. 0.06.
    var paddingFraction: CGFloat
    /// Corner radius (points) applied to the inset video layer.
    var cornerRadius: CGFloat
    var shadow: Bool
    /// `.mp4` destination. Any existing file at this URL is overwritten.
    var outputURL: URL
    /// If set, drawn (aspect-fill) as the background instead of the gradient.
    var backgroundImage: NSImage? = nil
    /// If set (and no image), fills the background with this solid color
    /// instead of the gradient. (gradient fields are the final fallback.)
    var solidColor: NSColor? = nil

    // ── Trim + cuts + speed (in SOURCE seconds) ─────────────────────────────
    /// Kept source ranges = trim minus cuts, in order. Empty → keep the whole
    /// recording. These are concatenated to form the output.
    var keptRanges: [ClosedRange<Double>] = []
    /// Global playback-speed multiplier (>0). 1 = unchanged. 2 = twice as fast.
    var speed: Double = 1.0
    /// Per-part speed regions (source-time); override `speed` where they cover.
    var speedRanges: [SpeedRange] = []
    /// Background blur in preview points; scaled to render pixels. 0 = none.
    var backgroundBlur: CGFloat = 0

    // ── Synthetic cursor ─────────────────────────────────────────────────────
    /// Cursor path (source-time, normalized top-left). Empty → no cursor drawn.
    var cursor: [CursorSample] = []
    /// Cursor size multiplier over the base (~3% of video height).
    var cursorScale: CGFloat = 2.0
    var cursorStyle: CursorStyle = .dark
    var clickEffect: ClickEffect = .none
    /// Click positions (source-time, normalized) for click effects.
    var clicks: [CursorSample] = []
    /// Cursor movement times (source-time) + idle hiding.
    var cursorMoveTimes: [Double] = []
    var hideCursorIdle: Bool = false
    var idleHideAfter: Double = 2.5

    /// Spotlight regions (source-time; box normalized top-left).
    var spotlights: [SpotlightRect] = []
    /// Blur/redact regions (source-time).
    var blurs: [BlurRect] = []

    // ── Camera overlay (webcam bubble; composited in a 2nd pass) ─────────────
    var cameraURL: URL? = nil
    /// Bubble centre normalized in the canvas (top-left origin).
    var cameraCenter: CGPoint = CGPoint(x: 0.83, y: 0.79)
    /// Bubble height as a fraction of the canvas height (square bubble).
    var cameraHeightFrac: CGFloat = 0.26
    var cameraCircle: Bool = true
    /// Recorded avatar movement, in OUTPUT seconds (already mapped through the
    /// edit timeline). Empty = static at cameraCenter/cameraHeightFrac.
    var cameraPath: [CameraPathPoint] = []
    /// OUTPUT-time spans where the avatar is omitted (camera toggled off live).
    var cameraOffSpans: [ClosedRange<Double>] = []
    /// Camera fills the whole canvas instead of a bubble.
    var cameraFullscreen: Bool = false
}

/// One avatar keyframe for export, in OUTPUT seconds, normalized canvas coords
/// (top-left origin). `h` is height as a fraction of canvas height.
struct CameraPathPoint {
    var t: Double
    var cx: CGFloat
    var cy: CGFloat
    var h: CGFloat
}

// MARK: - Renderer

enum RecordingRenderer {

    enum RenderError: Error {
        case noVideoTrack
        case couldNotCreateExportSession
        case exportFailed(Error?)
        case cancelled
    }

    static func render(movieURL: URL,
                       keyframes: [ZoomKeyframe],
                       options: RenderOptions,
                       completion: @escaping (Result<URL, Error>) -> Void) {

        // Always hand the outcome back on the main queue.
        func finish(_ result: Result<URL, Error>) {
            DispatchQueue.main.async { completion(result) }
        }

        let sourceAsset = AVURLAsset(url: movieURL)

        guard let videoTrack = sourceAsset.tracks(withMediaType: .video).first else {
            finish(.failure(RenderError.noVideoTrack))
            return
        }

        // ── Upright display size ─────────────────────────────────────────────
        // `naturalSize` is in the track's storage orientation. `preferredTransform`
        // rotates/flips storage → display. Apply it to the natural rect and take
        // the absolute extents to get the upright on-screen size we render into.
        // abs() keeps the size positive even when the transform has negative
        // scale components (mirrored / rotated tracks). Orientation is unchanged
        // by trim/speed, so this comes from the SOURCE track.
        let naturalSize = videoTrack.naturalSize
        let preferredTransform = videoTrack.preferredTransform
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(width: abs(displayRect.width),
                                height: abs(displayRect.height))

        guard renderSize.width > 0, renderSize.height > 0 else {
            finish(.failure(RenderError.noVideoTrack))
            return
        }

        // ── Trim/cut + speed → playback asset (shared with the live preview) ──
        // The output is the KEPT source ranges (recording minus cuts) split at
        // speed boundaries into pieces and concatenated; `EditTimeline` builds
        // the exact same timeline the editor plays. Zoom + cursor are authored
        // in SOURCE time and remapped onto the output via sourceToOutput.
        let srcDur = CMTimeGetSeconds(sourceAsset.duration)
        let keptRangesIn: [(Double, Double)] = options.keptRanges.isEmpty
            ? [(0, srcDur)]
            : options.keptRanges.map { ($0.lowerBound, $0.upperBound) }
        let pieces = EditTimeline.pieces(keptRanges: keptRangesIn,
                                         speedRanges: options.speedRanges,
                                         globalSpeed: options.speed,
                                         sourceDuration: srcDur)
        guard !pieces.isEmpty else { finish(.failure(RenderError.noVideoTrack)); return }
        func mapTime(_ s: Double) -> Double { EditTimeline.sourceToOutput(s, pieces) }

        let playbackAsset: AVAsset
        let playbackVideoTrack: AVAssetTrack
        if EditTimeline.isIdentity(pieces, sourceDuration: srcDur) {
            playbackAsset = sourceAsset
            playbackVideoTrack = videoTrack
        } else if let (comp, cv) = EditTimeline.composition(source: sourceAsset, pieces: pieces) {
            playbackAsset = comp
            playbackVideoTrack = cv
        } else {
            finish(.failure(RenderError.noVideoTrack)); return
        }

        let totalDuration = CMTimeGetSeconds(playbackAsset.duration)

        // Remap zoom keyframes + cursor samples onto the output timeline.
        let keyframes = keyframes.map {
            ZoomKeyframe(t: mapTime($0.t), scale: $0.scale, focusX: $0.focusX, focusY: $0.focusY)
        }
        let cursorMapped: [(t: Double, nx: Double, ny: Double)] =
            options.cursor.map { (mapTime($0.t), $0.nx, $0.ny) }

        // ── Frame rate ───────────────────────────────────────────────────────
        var fps = videoTrack.nominalFrameRate
        if !fps.isFinite || fps <= 0 { fps = 60 }
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(round(fps)))

        // ── Inset video slot ─────────────────────────────────────────────────
        // Inset the video on all four sides by `padding` so the gradient shows
        // around it. Clamp so a large paddingFraction can never invert the slot.
        let minDim = min(renderSize.width, renderSize.height)
        let rawPadding = max(0, options.paddingFraction) * minDim
        let maxPadX = max(0, (renderSize.width - 2) / 2)
        let maxPadY = max(0, (renderSize.height - 2) / 2)
        let padding = min(rawPadding, maxPadX, maxPadY)

        let slot = CGRect(x: padding,
                          y: padding,
                          width: renderSize.width - 2 * padding,
                          height: renderSize.height - 2 * padding)

        let cornerRadius = max(0, options.cornerRadius)

        // ── Layer tree ───────────────────────────────────────────────────────
        // parentLayer
        //   ├─ backgroundLayer  (gradient, fills the whole canvas)
        //   ├─ shadowContainer  (optional — unclipped, casts the drop shadow)
        //   └─ videoLayer       (post-processed video; cornerRadius + masksToBounds)
        //
        // A drop shadow needs a SEPARATE container layer because masksToBounds on
        // the video layer (required for the rounded corners) also clips its own
        // shadow to nothing. The container is unclipped, shares the slot frame,
        // and casts a shadow with the same rounded silhouette; the video layer
        // sits on top. The video layer is added directly to the parent (not
        // nested in the container) so the zoom coordinate math stays in parent
        // space — both layers occupy the identical slot rect, so they line up.
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = false  // CALayer default: BOTTOM-LEFT origin.
        parentLayer.masksToBounds = true

        // Background: image > solid color > gradient (fallback). The image is
        // aspect-FILLED to cover the whole canvas.
        let backgroundLayer: CALayer
        if let img = options.backgroundImage,
           let cg0 = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // Pre-blur the wallpaper with Core Image (reliable offline; CALayer
            // filters aren't honoured by the animation-tool render). Scale the
            // preview-point radius up to render pixels for rough visual parity.
            let cg: CGImage
            if options.backgroundBlur > 0.5 {
                let px = options.backgroundBlur * (renderSize.width / 800)
                cg = blurredImage(cg0, radius: px) ?? cg0
            } else {
                cg = cg0
            }
            let imgLayer = CALayer()
            imgLayer.contents = cg
            imgLayer.contentsGravity = .resizeAspectFill
            imgLayer.masksToBounds = true
            backgroundLayer = imgLayer
        } else if let solid = options.solidColor {
            let solidLayer = CALayer()
            solidLayer.backgroundColor = solid.cgColor
            backgroundLayer = solidLayer
        } else {
            let grad = CAGradientLayer()
            grad.colors = [options.gradientTop.cgColor, options.gradientBottom.cgColor]
            // Unit coords in the layer's (bottom-left) geometry → y=1 is the
            // visual TOP, so gradientTop sits at the top of the canvas.
            grad.startPoint = CGPoint(x: 0.5, y: 1.0)
            grad.endPoint = CGPoint(x: 0.5, y: 0.0)
            backgroundLayer = grad
        }
        backgroundLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.addSublayer(backgroundLayer)

        if options.shadow {
            let shadowContainer = CALayer()
            shadowContainer.frame = slot
            // Opaque fill so the rounded silhouette reads as a solid shadow caster.
            shadowContainer.backgroundColor = NSColor.black.cgColor
            shadowContainer.cornerRadius = cornerRadius
            shadowContainer.masksToBounds = false
            shadowContainer.shadowColor = NSColor.black.cgColor
            shadowContainer.shadowOpacity = 0.45
            shadowContainer.shadowRadius = max(8, minDim * 0.015)
            // Bottom-left geometry: a negative dy nudges the shadow downward.
            shadowContainer.shadowOffset = CGSize(width: 0, height: -minDim * 0.006)
            shadowContainer.shadowPath = CGPath(roundedRect: shadowContainer.bounds,
                                                cornerWidth: cornerRadius,
                                                cornerHeight: cornerRadius,
                                                transform: nil)
            parentLayer.addSublayer(shadowContainer)
        }

        // The layer that AVVideoCompositionCoreAnimationTool fills with the
        // decoded (and preferredTransform-corrected) video frames. We give it
        // bounds = slot size and place its center at the slot center; the zoom
        // animation drives `transform.scale` + `position` from there.
        let videoLayer = CALayer()
        videoLayer.bounds = CGRect(origin: .zero, size: slot.size)
        videoLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)  // scale about own center
        videoLayer.position = CGPoint(x: slot.midX, y: slot.midY)
        videoLayer.cornerRadius = cornerRadius
        videoLayer.masksToBounds = true
        videoLayer.contentsGravity = .resizeAspectFill
        parentLayer.addSublayer(videoLayer)

        // ── Auto-zoom animation ──────────────────────────────────────────────
        applyZoomAnimation(to: videoLayer,
                           slot: slot,
                           keyframes: keyframes,
                           totalDuration: totalDuration)

        // ── Click effects (under the cursor; zoom with the content) ───────────
        if options.clickEffect != .none, !options.clicks.isEmpty {
            let clicksMapped = options.clicks.map { (t: mapTime($0.t), nx: $0.nx, ny: $0.ny) }
            applyClickEffects(to: videoLayer, slot: slot, clicks: clicksMapped,
                              effect: options.clickEffect, totalDuration: totalDuration)
        }

        // ── Synthetic cursor ─────────────────────────────────────────────────
        // A sublayer of videoLayer (so it zooms/pans WITH the content). Sized as
        // a fraction of the video height × the user's cursor scale.
        if !cursorMapped.isEmpty,
           let curCG = CursorGraphic.arrowCG(
                height: max(8, slot.height * CursorGraphic.heightFraction * options.cursorScale),
                style: options.cursorStyle) {
            let cursorLayer = CALayer()
            cursorLayer.contents = curCG
            cursorLayer.bounds = CGRect(x: 0, y: 0,
                                        width: CGFloat(curCG.width), height: CGFloat(curCG.height))
            cursorLayer.anchorPoint = CursorGraphic.tipAnchor(for: options.cursorStyle)
            cursorLayer.contentsGravity = .resizeAspect
            videoLayer.addSublayer(cursorLayer)
            applyCursorAnimation(to: cursorLayer, slot: slot,
                                 samples: cursorMapped, totalDuration: totalDuration)
            // Hide-when-idle: opacity keyframes from the (mapped) movement times.
            if options.hideCursorIdle, !options.cursorMoveTimes.isEmpty {
                applyIdleOpacity(to: cursorLayer,
                                 moveTimesOut: options.cursorMoveTimes.map { mapTime($0) },
                                 idleAfter: options.idleHideAfter, totalDuration: totalDuration)
            }
        }

        // ── Spotlights (dim the slot outside a box; not zoom-coupled) ─────────
        for sp in options.spotlights {
            let dim = CALayer()
            dim.frame = slot
            dim.backgroundColor = NSColor.black.cgColor
            dim.opacity = 0
            // box in slot coords (flip y to bottom-left).
            let b = CGRect(x: clamp01(sp.box.minX) * slot.width,
                           y: (1 - clamp01(sp.box.maxY)) * slot.height,
                           width: clamp01(sp.box.width) * slot.width,
                           height: clamp01(sp.box.height) * slot.height)
            let mask = CAShapeLayer()
            mask.frame = CGRect(origin: .zero, size: slot.size)
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: slot.size))
            let corner = sp.roundness * min(b.width, b.height)
            path.addRoundedRect(in: b, cornerWidth: corner, cornerHeight: corner)
            mask.path = path
            mask.fillRule = .evenOdd          // dim the ring, clear the box
            dim.mask = mask
            parentLayer.addSublayer(dim)
            applySpotlightOpacity(to: dim, start: mapTime(sp.start), end: mapTime(sp.end),
                                  totalDuration: totalDuration, peak: Double(sp.dim))
        }

        // ── Region blur / redact (backgroundFilters over the slot) ───────────
        for bl in options.blurs {
            let b = CGRect(x: clamp01(bl.box.minX) * slot.width,
                           y: (1 - clamp01(bl.box.maxY)) * slot.height,
                           width: clamp01(bl.box.width) * slot.width,
                           height: clamp01(bl.box.height) * slot.height)
            guard b.width > 1, b.height > 1 else { continue }
            let blur = CALayer()
            blur.frame = b.offsetBy(dx: slot.minX, dy: slot.minY)
            blur.masksToBounds = true
            blur.cornerRadius = bl.roundness * min(b.width, b.height)
            blur.opacity = 0
            if let f = CIFilter(name: "CIGaussianBlur") {
                f.setValue(bl.strength * min(b.width, b.height) * 0.5, forKey: kCIInputRadiusKey)
                blur.backgroundFilters = [f]
            }
            parentLayer.addSublayer(blur)
            applySpotlightOpacity(to: blur, start: mapTime(bl.start), end: mapTime(bl.end),
                                  totalDuration: totalDuration, peak: 1.0)
        }

        // ── Video composition ────────────────────────────────────────────────
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = frameDuration

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: playbackAsset.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: playbackVideoTrack)
        // Apply the track's preferredTransform so frames are upright inside the
        // videoLayer (which has the upright slot size as its bounds).
        layerInstruction.setTransform(preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        // ── Export ───────────────────────────────────────────────────────────
        guard let export = AVAssetExportSession(
            asset: playbackAsset, presetName: AVAssetExportPresetHighestQuality) else {
            finish(.failure(RenderError.couldNotCreateExportSession))
            return
        }

        // With a camera, render the cosmetic pass to a temp file, then overlay
        // the webcam in a 2nd pass; otherwise write straight to the output.
        let camera = options.cameraURL
        let stage1URL = camera != nil
            ? options.outputURL.deletingPathExtension().appendingPathExtension("stage1.mp4")
            : options.outputURL

        if FileManager.default.fileExists(atPath: stage1URL.path) {
            try? FileManager.default.removeItem(at: stage1URL)
        }

        export.videoComposition = composition
        export.outputURL = stage1URL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.audioTimePitchAlgorithm = .spectral   // preserve pitch at non-1× speed
        // Audio passes through automatically: with no audioMix set, the export
        // session carries the asset's original audio track(s) into the output.

        export.exportAsynchronously {
            switch export.status {
            case .completed:
                if let cam = camera {
                    // Pass 2: overlay the webcam bubble. Falls back to the
                    // cosmetic result if the overlay fails (export never breaks).
                    CameraOverlayCompositor.overlay(
                        intermediateURL: stage1URL, cameraURL: cam, pieces: pieces,
                        renderSize: renderSize, frameDuration: frameDuration,
                        cameraCenter: options.cameraCenter,
                        cameraHeightFrac: options.cameraHeightFrac,
                        circle: options.cameraCircle, path: options.cameraPath,
                        offSpans: options.cameraOffSpans,
                        fullscreen: options.cameraFullscreen,
                        outputURL: options.outputURL) { ok in
                        if ok {
                            try? FileManager.default.removeItem(at: stage1URL)
                        } else {
                            try? FileManager.default.removeItem(at: options.outputURL)
                            try? FileManager.default.moveItem(at: stage1URL, to: options.outputURL)
                        }
                        finish(.success(options.outputURL))
                    }
                } else {
                    finish(.success(options.outputURL))
                }
            case .cancelled:
                finish(.failure(RenderError.cancelled))
            default:
                finish(.failure(RenderError.exportFailed(export.error)))
            }
        }
    }

    // MARK: - Auto-zoom

    /// Attaches a `transform.scale` + `position` keyframe animation to
    /// `videoLayer` so that, at every keyframe, the video is scaled by
    /// `keyframe.scale` and the focus point `(focusX, focusY)` is centered
    /// within the slot.
    ///
    /// No-ops cleanly for 0 keyframes (just bg + framed video at 1×) and applies
    /// a static resting transform for a single keyframe.
    private static func applyZoomAnimation(to videoLayer: CALayer,
                                           slot: CGRect,
                                           keyframes: [ZoomKeyframe],
                                           totalDuration: Double) {

        let w = slot.width
        let h = slot.height
        guard w > 0, h > 0, totalDuration.isFinite, totalDuration > 0 else { return }

        // Sanitize: drop any keyframe with a non-finite field; clamp focus to
        // 0..1 and time to 0..totalDuration. scale < 1 (zoom OUT) is permitted per
        // spec — only guard against 0 / negative / NaN, which would collapse or
        // invert the layer.
        let cleaned: [ZoomKeyframe] = keyframes.compactMap { kf in
            guard kf.t.isFinite, kf.scale.isFinite, kf.focusX.isFinite, kf.focusY.isFinite
            else { return nil }
            let s = max(0.01, kf.scale)
            let fx = clamp01(kf.focusX)
            let fy = clamp01(kf.focusY)
            let t = min(max(kf.t, 0), totalDuration)
            return ZoomKeyframe(t: t, scale: s, focusX: fx, focusY: fy)
        }.sorted { $0.t < $1.t }

        // 0 keyframes → no animation; the layer rests at 1× centered in the slot.
        guard !cleaned.isEmpty else { return }

        // ── The load-bearing transform math ──────────────────────────────────
        //
        // CALayer geometry is BOTTOM-LEFT origin. videoLayer.bounds = (0,0,w,h)
        // and the decoded video fills those bounds (resizeAspectFill, upright).
        //
        // ZoomKeyframe.focusX/Y are normalized 0..1 in the VIDEO's space with a
        // TOP-LEFT origin. x maps straight through; y MUST be flipped:
        //
        //     focusInLayer.x = focusX * w
        //     focusInLayer.y = (1 - focusY) * h        // top-left → bottom-left
        //
        // anchorPoint is (0.5, 0.5), so setting `transform = scale(s)` scales the
        // layer's content about its own center (w/2, h/2), and `position` places
        // that center within the parent. A bounds point P renders at:
        //
        //     screen(P) = position + s · (P − center)
        //
        // We want the FOCUS point to land at the slot center, so solve for
        // `position` with P = focusInLayer and screen(P) = slotCenter:
        //
        //     slotCenter = position + s · (focusInLayer − center)
        //  ⇒  position   = slotCenter − s · (focusInLayer − center)
        //
        // Driving `transform.scale` + `position` together (kept in lockstep via a
        // shared keyTimes array) yields exactly this at every keyframe, with
        // linear interpolation + ease-in-ease-out timing between them.
        let centerX = w / 2
        let centerY = h / 2
        func position(for kf: ZoomKeyframe) -> CGPoint {
            let focusX = kf.focusX * w
            let focusY = (1 - kf.focusY) * h          // Y-FLIP: top-left → bottom-left
            return CGPoint(x: slot.midX - kf.scale * (focusX - centerX),
                           y: slot.midY - kf.scale * (focusY - centerY))
        }

        // Single keyframe → a static (non-animated) resting transform.
        if cleaned.count == 1 {
            let kf = cleaned[0]
            videoLayer.transform = CATransform3DMakeScale(kf.scale, kf.scale, 1)
            videoLayer.position = position(for: kf)
            return
        }

        // ── Normalized, strictly-increasing keyTimes in [0, 1] ────────────────
        // CAKeyframeAnimation requires keyTimes that are monotonically increasing.
        // Driven by AVVideoCompositionCoreAnimationTool, the safest contract is to
        // start at 0 and end at 1 with .forwards fill holding the ends.
        var keyTimes: [NSNumber] = []
        var scaleValues: [NSNumber] = []
        var positionValues: [NSValue] = []

        var lastT = -1.0
        let epsilon = 1e-6
        for (i, kf) in cleaned.enumerated() {
            var nt = kf.t / totalDuration
            if !nt.isFinite { nt = lastT < 0 ? 0 : lastT + epsilon }
            nt = min(max(nt, 0.0), 1.0)
            if i == 0 { nt = 0 }                                  // anchor start
            if i == cleaned.count - 1 { nt = 1 }                  // anchor end
            if nt <= lastT { nt = min(1.0, lastT + epsilon) }     // strictly increasing
            keyTimes.append(NSNumber(value: nt))
            scaleValues.append(NSNumber(value: Double(kf.scale)))
            positionValues.append(NSValue(point: position(for: kf)))
            lastT = nt
        }

        // Smoother motion: a Catmull-Rom spline through the keyframes
        // (.cubic) instead of straight-line (.linear) interpolation, so the
        // zoom glides in/out and pans along a curve rather than snapping
        // between points. `.cubic` does its own smoothing, so per-interval
        // timingFunctions are dropped (they only apply to .linear/.discrete).
        // calculationMode is set AFTER values/keyTimes (required for cubic).
        let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnim.values = scaleValues
        scaleAnim.keyTimes = keyTimes
        scaleAnim.calculationMode = .cubic
        configure(scaleAnim, duration: totalDuration)

        let posAnim = CAKeyframeAnimation(keyPath: "position")
        posAnim.values = positionValues
        posAnim.keyTimes = keyTimes
        posAnim.calculationMode = .cubic
        configure(posAnim, duration: totalDuration)

        // Resting state = first keyframe, so frame 0 is correct before the first
        // animation sample is evaluated (and after, .forwards holds the last).
        videoLayer.transform = CATransform3DMakeScale(cleaned[0].scale, cleaned[0].scale, 1)
        videoLayer.position = position(for: cleaned[0])

        videoLayer.add(scaleAnim, forKey: "forge.zoom.scale")
        videoLayer.add(posAnim, forKey: "forge.zoom.position")
    }

    private static func configure(_ anim: CAKeyframeAnimation, duration: Double) {
        // AVCoreAnimationBeginTimeAtZero (NOT literal 0) is mandatory for layers
        // driven by AVVideoCompositionCoreAnimationTool — a beginTime of 0 is read
        // as "now" and the animation is silently dropped from the render.
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration = duration
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        anim.isAdditive = false
    }

    /// Drive the synthetic cursor layer's `position` from the (output-time)
    /// samples. `(nx, ny)` is normalized TOP-LEFT in the video; the layer lives
    /// in slot space (bottom-left), so y is flipped. Linear interpolation (no
    /// cubic overshoot — a cursor shouldn't curve past its samples).
    private static func applyCursorAnimation(to layer: CALayer, slot: CGRect,
                                             samples: [(t: Double, nx: Double, ny: Double)],
                                             totalDuration: Double) {
        let w = slot.width, h = slot.height
        guard !samples.isEmpty, totalDuration.isFinite, totalDuration > 0 else { return }
        func pos(_ s: (t: Double, nx: Double, ny: Double)) -> CGPoint {
            CGPoint(x: clamp01(CGFloat(s.nx)) * w, y: (1 - clamp01(CGFloat(s.ny))) * h)
        }
        let sorted = samples.filter { $0.t.isFinite }.sorted { $0.t < $1.t }
        guard let first = sorted.first else { return }
        if sorted.count == 1 { layer.position = pos(first); return }

        var keyTimes: [NSNumber] = []
        var values: [NSValue] = []
        var lastT = -1.0
        let eps = 1e-6
        for (i, s) in sorted.enumerated() {
            var nt = s.t / totalDuration
            if !nt.isFinite { nt = lastT < 0 ? 0 : lastT + eps }
            nt = min(max(nt, 0), 1)
            if i == 0 { nt = 0 }
            if i == sorted.count - 1 { nt = 1 }
            if nt <= lastT { nt = min(1, lastT + eps) }
            keyTimes.append(NSNumber(value: nt))
            values.append(NSValue(point: pos(s)))
            lastT = nt
        }
        let anim = CAKeyframeAnimation(keyPath: "position")
        anim.values = values
        anim.keyTimes = keyTimes
        anim.calculationMode = .linear
        configure(anim, duration: totalDuration)
        layer.position = pos(first)
        layer.add(anim, forKey: "forge.cursor.position")
    }

    /// One expanding/fading circle per click, timed to the click's output time.
    private static func applyClickEffects(to videoLayer: CALayer, slot: CGRect,
                                          clicks: [(t: Double, nx: Double, ny: Double)],
                                          effect: ClickEffect, totalDuration: Double) {
        guard totalDuration > 0 else { return }
        let w = slot.width, h = slot.height
        let maxR = max(10, h * 0.06)
        let dur = 0.5
        for c in clicks {
            guard c.t.isFinite, c.t >= 0, c.t < totalDuration else { continue }
            let cx = clamp01(CGFloat(c.nx)) * w
            let cy = (1 - clamp01(CGFloat(c.ny))) * h
            if effect == .sparkle {
                addSparkle(to: videoLayer, center: CGPoint(x: cx, y: cy),
                           reach: maxR * 2.2, dot: max(3, h * 0.012), at: c.t, dur: dur)
                continue
            }
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: maxR * 2, height: maxR * 2)
            layer.position = CGPoint(x: cx, y: cy)
            layer.cornerRadius = maxR
            switch effect {
            case .ring:
                layer.borderColor = NSColor.white.cgColor
                layer.borderWidth = max(2, h * 0.006)
            case .ripple:
                layer.backgroundColor = NSColor.white.withAlphaComponent(0.30).cgColor
            case .spotlight:
                layer.backgroundColor = NSColor.forgeAccent.withAlphaComponent(0.45).cgColor
            case .sparkle, .none:
                continue
            }
            layer.opacity = 0
            videoLayer.addSublayer(layer)

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.2, 1.0]; scale.keyTimes = [0, 1]; scale.calculationMode = .linear
            let op = CAKeyframeAnimation(keyPath: "opacity")
            op.values = [0.0, 0.9, 0.0]; op.keyTimes = [0, 0.15, 1.0]; op.calculationMode = .linear
            for a in [scale, op] {
                a.beginTime = AVCoreAnimationBeginTimeAtZero + c.t
                a.duration = dur
                a.fillMode = .forwards
                a.isRemovedOnCompletion = false
            }
            layer.add(scale, forKey: "forge.click.scale")
            layer.add(op, forKey: "forge.click.opacity")
        }
    }

    /// A burst of small dots fanning outward from a click point (sparkle effect).
    /// Uses layered circle CALayers + keyframe animations (CAEmitterLayer is not
    /// honoured by the animation-tool render).
    private static func addSparkle(to parent: CALayer, center: CGPoint, reach: CGFloat,
                                   dot: CGFloat, at t: Double, dur: Double) {
        let n = 8
        for i in 0..<n {
            let ang = CGFloat(i) / CGFloat(n) * 2 * .pi
            let p = CALayer()
            p.bounds = CGRect(x: 0, y: 0, width: dot * 2, height: dot * 2)
            p.cornerRadius = dot
            p.backgroundColor = NSColor.white.cgColor
            p.position = center
            p.opacity = 0
            parent.addSublayer(p)
            let end = CGPoint(x: center.x + cos(ang) * reach, y: center.y + sin(ang) * reach)
            let pos = CAKeyframeAnimation(keyPath: "position")
            pos.values = [NSValue(point: center), NSValue(point: end)]
            pos.keyTimes = [0, 1]; pos.calculationMode = .cubic
            let sc = CAKeyframeAnimation(keyPath: "transform.scale")
            sc.values = [1.2, 0.2]; sc.keyTimes = [0, 1]
            let op = CAKeyframeAnimation(keyPath: "opacity")
            op.values = [0.0, 1.0, 0.0]; op.keyTimes = [0, 0.12, 1.0]
            for a in [pos, sc, op] {
                a.beginTime = AVCoreAnimationBeginTimeAtZero + t
                a.duration = dur
                a.fillMode = .forwards
                a.isRemovedOnCompletion = false
            }
            p.add(pos, forKey: "forge.sparkle.pos")
            p.add(sc, forKey: "forge.sparkle.scale")
            p.add(op, forKey: "forge.sparkle.opacity")
        }
    }

    /// Fade an overlay in/out across [start, end] (output time).
    private static func applySpotlightOpacity(to layer: CALayer, start: Double, end: Double,
                                              totalDuration: Double, peak: Double = 0.55) {
        guard totalDuration > 0, end > start else { return }
        let dur = end - start
        let fade = min(0.2, dur * 0.25)
        let op = CAKeyframeAnimation(keyPath: "opacity")
        op.values = [0.0, peak, peak, 0.0]
        op.keyTimes = [0, NSNumber(value: fade / dur), NSNumber(value: 1 - fade / dur), 1]
        op.calculationMode = .linear
        op.beginTime = AVCoreAnimationBeginTimeAtZero + start
        op.duration = dur
        op.fillMode = .forwards
        op.isRemovedOnCompletion = false
        layer.add(op, forKey: "forge.spotlight.opacity")
    }

    /// Opacity keyframes that fade the cursor out after `idleAfter` seconds of
    /// no movement. Sampled at a coarse step (linear interp gives the fades).
    private static func applyIdleOpacity(to layer: CALayer, moveTimesOut: [Double],
                                         idleAfter: Double, totalDuration: Double) {
        guard totalDuration > 0 else { return }
        let moves = moveTimesOut.filter { $0.isFinite }.sorted()
        func lastMove(_ t: Double) -> Double? {
            var lo = 0, hi = moves.count - 1, ans = -1
            while lo <= hi { let m = (lo + hi) / 2; if moves[m] <= t { ans = m; lo = m + 1 } else { hi = m - 1 } }
            return ans >= 0 ? moves[ans] : nil
        }
        var values: [NSNumber] = []
        var keyTimes: [NSNumber] = []
        var t = 0.0, lastNT = -1.0
        let step = 0.2
        while t <= totalDuration + 1e-6 {
            let vis: Double = lastMove(t).map { (t - $0) < idleAfter ? 1 : 0 } ?? 1
            var nt = min(1.0, t / totalDuration)
            if nt <= lastNT { nt = min(1, lastNT + 1e-6) }
            keyTimes.append(NSNumber(value: nt)); values.append(NSNumber(value: vis)); lastNT = nt
            t += step
        }
        guard values.count > 1 else { return }
        let op = CAKeyframeAnimation(keyPath: "opacity")
        op.values = values; op.keyTimes = keyTimes; op.calculationMode = .linear
        op.beginTime = AVCoreAnimationBeginTimeAtZero
        op.duration = totalDuration
        op.fillMode = .forwards; op.isRemovedOnCompletion = false
        layer.add(op, forKey: "forge.cursor.idle")
    }

    private static func clamp01(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }

    /// Gaussian-blur a CGImage. `clampedToExtent` avoids the transparent halo a
    /// raw CIGaussianBlur leaves at the edges (so the blurred wallpaper still
    /// fills the canvas). Returns nil on failure (caller falls back to sharp).
    private static func blurredImage(_ cg: CGImage, radius: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: ci.clampedToExtent(),
            kCIInputRadiusKey: max(0, radius),
        ]), let out = filter.outputImage else { return nil }
        let ctx = CIContext(options: nil)
        return ctx.createCGImage(out, from: ci.extent)
    }
}

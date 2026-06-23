import AVFoundation
import CoreImage
import AppKit

// MARK: - Instruction

/// Carries the two source track IDs + the bubble geometry (render pixels,
/// bottom-left origin) for the camera overlay pass.
final class CameraOverlayInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange = .invalid
    var enablePostProcessing: Bool = true
    var containsTweening: Bool = false
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    var bgTrackID: CMPersistentTrackID = 1
    var camTrackID: CMPersistentTrackID = 2
    var bubble: CGRect = .zero        // static fallback (used when `path` is empty)
    var corner: CGFloat = 0
    var path: [CameraPathPoint] = []  // OUTPUT-time, normalized — animates the bubble
    var circle: Bool = true
    var offSpans: [ClosedRange<Double>] = []   // OUTPUT-time spans with NO avatar
    var fullscreen: Bool = false      // camera fills the whole canvas

    func avatarHidden(at t: Double) -> Bool { offSpans.contains { $0.contains(t) } }

    /// Bubble rect (render pixels, bottom-left origin) + corner radius at output
    /// time `t`. Interpolates `path`; falls back to the static `bubble`.
    func geometry(at t: Double, renderSize: CGSize) -> (CGRect, CGFloat) {
        if fullscreen { return (CGRect(origin: .zero, size: renderSize), 0) }
        guard !path.isEmpty else { return (bubble, corner) }
        let cx: CGFloat, cy: CGFloat, h: CGFloat
        if t <= path.first!.t { let p = path.first!; cx = p.cx; cy = p.cy; h = p.h }
        else if t >= path.last!.t { let p = path.last!; cx = p.cx; cy = p.cy; h = p.h }
        else {
            var lo = path[0]; var hi = path[0]
            for p in path { if p.t >= t { hi = p; break }; lo = p }
            let span = hi.t - lo.t
            let u = span > 1e-6 ? CGFloat((t - lo.t) / span) : 0
            cx = lo.cx + (hi.cx - lo.cx) * u
            cy = lo.cy + (hi.cy - lo.cy) * u
            h  = lo.h  + (hi.h  - lo.h)  * u
        }
        let size = max(2, h * renderSize.height)
        let cxPx = cx * renderSize.width
        let cyTop = cy * renderSize.height
        let rect = CGRect(x: cxPx - size / 2,
                          y: renderSize.height - (cyTop + size / 2),
                          width: size, height: size)
        return (rect, circle ? size / 2 : size * 0.16)
    }
}

// MARK: - Compositor

/// Overlays the webcam (masked to a circle/rounded rect) onto the already
/// cosmetically-rendered screen frame. Registered as a custom compositor for
/// the Phase-3 export pass.
final class CameraOverlayCompositor: NSObject, AVVideoCompositing {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var renderSize: CGSize = .zero
    private var maskCache: (w: Int, h: Int, corner: CGFloat, image: CIImage)?

    var sourcePixelBufferAttributes: [String: Any]? =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderSize = newRenderContext.size
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instr = request.videoCompositionInstruction as? CameraOverlayInstruction,
                  let dest = request.renderContext.newPixelBuffer(),
                  let bgBuf = request.sourceFrame(byTrackID: instr.bgTrackID) else {
                request.finish(with: NSError(domain: "ForgeCamera", code: 1))
                return
            }
            let bg = CIImage(cvPixelBuffer: bgBuf)
            var out = bg
            let now = request.compositionTime.seconds
            let (bubble, corner) = instr.geometry(at: now, renderSize: renderSize)
            // White ring around the bubble (not in fullscreen). Matches the preview.
            let ring: CGFloat = instr.fullscreen ? 0 : max(2, bubble.width * 0.02)
            if !instr.avatarHidden(at: now), let camBuf = request.sourceFrame(byTrackID: instr.camTrackID) {
                let cam = CIImage(cvPixelBuffer: camBuf)
                if let masked = maskedCamera(cam, bubble: bubble, corner: corner, ring: ring) {
                    out = masked.composited(over: bg)
                }
            }
            ciContext.render(out, to: dest,
                             bounds: CGRect(origin: .zero, size: renderSize),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
            request.finish(withComposedVideoFrame: dest)
        }
    }

    // MARK: CoreImage helpers

    /// Scale the camera to fill the bubble square, crop, mask to the shape, and
    /// position it at the bubble rect.
    private func maskedCamera(_ cam: CIImage, bubble: CGRect, corner: CGFloat, ring: CGFloat = 0) -> CIImage? {
        guard bubble.width > 1, bubble.height > 1 else { return nil }
        let e = cam.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let scale = bubble.width / min(e.width, e.height)        // aspect-fill
        var img = cam.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Centre the scaled image on the bubble, then crop to the bubble.
        let se = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: bubble.midX - se.midX,
                                                    y: bubble.midY - se.midY))
        img = img.cropped(to: bubble)

        let mask = maskImage(width: Int(bubble.width.rounded()),
                             height: Int(bubble.height.rounded()), corner: corner)
            .transformed(by: CGAffineTransform(translationX: bubble.minX, y: bubble.minY))

        let masked = img.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
        guard ring > 0.5 else { return masked }
        let ringImg = ringImage(width: Int(bubble.width.rounded()),
                                height: Int(bubble.height.rounded()), corner: corner, lineWidth: ring)
            .transformed(by: CGAffineTransform(translationX: bubble.minX, y: bubble.minY))
        return ringImg.composited(over: masked)
    }

    private var ringCache: (w: Int, h: Int, corner: CGFloat, line: CGFloat, image: CIImage)?
    private func ringImage(width: Int, height: Int, corner: CGFloat, lineWidth: CGFloat) -> CIImage {
        if let c = ringCache, c.w == width, c.h == height, abs(c.corner - corner) < 0.5,
           abs(c.line - lineWidth) < 0.5 { return c.image }
        let img: CIImage
        if let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height),
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(lineWidth)
            let inset = lineWidth / 2
            let rect = CGRect(x: inset, y: inset,
                              width: CGFloat(width) - lineWidth, height: CGFloat(height) - lineWidth)
            let c = max(0, corner - inset)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: c, cornerHeight: c, transform: nil))
            ctx.strokePath()
            img = ctx.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
        } else {
            img = CIImage.empty()
        }
        ringCache = (width, height, corner, lineWidth, img)
        return img
    }

    private func maskImage(width: Int, height: Int, corner: CGFloat) -> CIImage {
        if let c = maskCache, c.w == width, c.h == height, abs(c.corner - corner) < 0.5 { return c.image }
        let img: CIImage
        if let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height),
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(NSColor.white.cgColor)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.fillPath()
            img = ctx.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
        } else {
            img = CIImage.empty()
        }
        maskCache = (width, height, corner, img)
        return img
    }

    // MARK: - Pass 2 entry point

    /// Overlay `cameraURL` (edited to match `pieces`) onto the already-rendered
    /// `intermediateURL`, writing `outputURL`. Completion is on a background
    /// queue; `false` means the caller should fall back to the intermediate.
    static func overlay(intermediateURL: URL, cameraURL: URL, pieces: [EditPiece],
                        renderSize: CGSize, frameDuration: CMTime,
                        cameraCenter: CGPoint, cameraHeightFrac: CGFloat, circle: Bool,
                        path: [CameraPathPoint] = [],
                        offSpans: [ClosedRange<Double>] = [],
                        fullscreen: Bool = false,
                        outputURL: URL, completion: @escaping (Bool) -> Void) {
        let interAsset = AVURLAsset(url: intermediateURL)
        let camAsset = AVURLAsset(url: cameraURL)
        guard let interV = interAsset.tracks(withMediaType: .video).first,
              let camV = camAsset.tracks(withMediaType: .video).first else { completion(false); return }

        let comp = AVMutableComposition()
        guard let tA = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 1),
              let tB = comp.addMutableTrack(withMediaType: .video, preferredTrackID: 2) else {
            completion(false); return
        }
        let ts = interAsset.duration.timescale
        try? tA.insertTimeRange(CMTimeRange(start: .zero, duration: interAsset.duration), of: interV, at: .zero)
        EditTimeline.insertEdited(pieces: pieces, of: camV, into: tB, timescale: ts)
        // Carry every audio track (system audio + microphone) through pass 2.
        for interA in interAsset.tracks(withMediaType: .audio) {
            if let aT = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? aT.insertTimeRange(CMTimeRange(start: .zero, duration: interAsset.duration), of: interA, at: .zero)
            }
        }

        // Bubble rect in render pixels (CoreImage bottom-left origin).
        let size = cameraHeightFrac * renderSize.height
        let cx = cameraCenter.x * renderSize.width
        let cyTop = cameraCenter.y * renderSize.height
        let bubble = CGRect(x: cx - size / 2,
                            y: renderSize.height - (cyTop + size / 2),
                            width: size, height: size)
        let corner: CGFloat = circle ? size / 2 : size * 0.16

        let instr = CameraOverlayInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        instr.requiredSourceTrackIDs = [NSNumber(value: 1), NSNumber(value: 2)]
        instr.bgTrackID = 1; instr.camTrackID = 2
        instr.bubble = bubble; instr.corner = corner
        instr.path = path; instr.circle = circle; instr.offSpans = offSpans
        instr.fullscreen = fullscreen
        instr.containsTweening = !path.isEmpty   // per-frame interpolation when animating

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = CameraOverlayCompositor.self
        vc.renderSize = renderSize
        vc.frameDuration = frameDuration
        vc.instructions = [instr]

        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            completion(false); return
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        export.videoComposition = vc
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.exportAsynchronously {
            completion(export.status == .completed)
        }
    }
}

import AVFoundation

/// One constant-speed slice of the edited output. `[s0, s1]` is a SOURCE-time
/// range (kept content), played at `factor`× starting at `outStart` in OUTPUT
/// time. Cuts are simply the gaps between pieces — they're never emitted.
struct EditPiece {
    var s0: Double
    var s1: Double
    var factor: Double
    var outStart: Double      // output-time start (after prior pieces, scaled)
}

/// Shared timeline math for the recorder editor. Both the live preview and the
/// export build the SAME edited timeline from this — so what you scrub is what
/// you get. Cuts (removed spans), trim, and per-part speed all reduce to a list
/// of `EditPiece`s; concatenating their source ranges (scaled) IS the output.
enum EditTimeline {

    /// Build constant-factor pieces from kept source ranges + speed regions.
    /// `keptRanges` is the recording minus cuts (and minus trim, if any).
    static func pieces(keptRanges: [(Double, Double)],
                       speedRanges: [SpeedRange],
                       globalSpeed: Double,
                       sourceDuration: Double) -> [EditPiece] {
        let gs = (globalSpeed.isFinite && globalSpeed > 0.05) ? globalSpeed : 1.0
        func factor(at t: Double) -> Double {
            for r in speedRanges where t >= r.start && t < r.end {
                return (r.factor.isFinite && r.factor > 0.05) ? r.factor : 1.0
            }
            return gs
        }
        let kept = keptRanges
            .map { (max(0, $0.0), min(sourceDuration, $0.1)) }
            .filter { $0.1 - $0.0 > 0.01 }
            .sorted { $0.0 < $1.0 }

        var result: [EditPiece] = []
        var outAcc = 0.0
        for (a, b) in kept {
            var bps: [Double] = [a, b]
            for r in speedRanges {
                if r.start > a, r.start < b { bps.append(r.start) }
                if r.end > a,   r.end < b   { bps.append(r.end) }
            }
            bps = Array(Set(bps)).sorted()
            for i in 0..<max(0, bps.count - 1) {
                let x = bps[i], y = bps[i + 1]
                guard y - x > 1e-4 else { continue }
                let f = factor(at: (x + y) / 2)
                result.append(EditPiece(s0: x, s1: y, factor: f, outStart: outAcc))
                outAcc += (y - x) / f
            }
        }
        return result
    }

    /// True when the pieces are just the whole source at 1× (no edits) — callers
    /// can then skip building a composition and use the source asset directly.
    static func isIdentity(_ pieces: [EditPiece], sourceDuration: Double) -> Bool {
        guard pieces.count == 1, let p = pieces.first else { return false }
        return abs(p.s0) < 1e-3 && abs(p.s1 - sourceDuration) < 1e-3 && abs(p.factor - 1) < 1e-3
    }

    /// Concatenate the pieces' source ranges into an AVMutableComposition
    /// (video + audio), scaling each non-1× piece. Returns the composition and
    /// its video track, or nil if there's nothing to build.
    static func composition(source: AVAsset, pieces: [EditPiece]) -> (AVMutableComposition, AVAssetTrack)? {
        guard let vTrack = source.tracks(withMediaType: .video).first, !pieces.isEmpty else { return nil }
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let scale = source.duration.timescale
        // Carry EVERY source audio track (e.g. system audio + microphone) so a
        // voice-over recorded on its own track survives editing and export.
        let srcAudio = source.tracks(withMediaType: .audio)
        let compAudio: [AVMutableCompositionTrack] = srcAudio.compactMap { _ in
            comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        // 1) Concatenate kept ranges (cuts are the gaps we never insert).
        var insertAt = CMTime.zero
        var compStarts: [Double] = []
        var accLen = 0.0
        for p in pieces {
            let r = CMTimeRange(start: CMTime(seconds: p.s0, preferredTimescale: scale),
                                duration: CMTime(seconds: p.s1 - p.s0, preferredTimescale: scale))
            do { try cv.insertTimeRange(r, of: vTrack, at: insertAt) } catch { return nil }
            for (sa, ca) in zip(srcAudio, compAudio) { try? ca.insertTimeRange(r, of: sa, at: insertAt) }
            compStarts.append(accLen)
            accLen += p.s1 - p.s0
            insertAt = CMTime(seconds: accLen, preferredTimescale: scale)
        }
        cv.preferredTransform = vTrack.preferredTransform

        // 2) Scale non-1× pieces LAST→FIRST (so earlier comp starts hold).
        for i in stride(from: pieces.count - 1, through: 0, by: -1) {
            let p = pieces[i]
            guard abs(p.factor - 1) > 1e-3 else { continue }
            let len = p.s1 - p.s0
            let r = CMTimeRange(start: CMTime(seconds: compStarts[i], preferredTimescale: scale),
                                duration: CMTime(seconds: len, preferredTimescale: scale))
            for tr in comp.tracks {
                tr.scaleTimeRange(r, toDuration: CMTime(seconds: len / p.factor, preferredTimescale: scale))
            }
        }
        return (comp, cv)
    }

    /// Insert the kept pieces of `src` into `dst` (output time), scaling per
    /// piece. Used to align a SECOND track (the webcam) with the edited screen.
    /// Ranges past the source's duration are clamped; positions advance by the
    /// full piece length so the track stays aligned even if `src` is shorter.
    static func insertEdited(pieces: [EditPiece], of src: AVAssetTrack,
                             into dst: AVMutableCompositionTrack, timescale: CMTimeScale) {
        let srcDur = CMTimeGetSeconds(src.timeRange.duration)
        var compStarts: [Double] = []
        var acc = 0.0
        for p in pieces {
            let s0 = min(p.s0, srcDur), s1 = min(p.s1, srcDur)
            if s1 - s0 > 0.001 {
                let r = CMTimeRange(start: CMTime(seconds: s0, preferredTimescale: timescale),
                                    duration: CMTime(seconds: s1 - s0, preferredTimescale: timescale))
                try? dst.insertTimeRange(r, of: src, at: CMTime(seconds: acc, preferredTimescale: timescale))
            }
            compStarts.append(acc)
            acc += p.s1 - p.s0
        }
        for i in stride(from: pieces.count - 1, through: 0, by: -1) {
            let p = pieces[i]
            guard abs(p.factor - 1) > 1e-3 else { continue }
            let len = p.s1 - p.s0
            let r = CMTimeRange(start: CMTime(seconds: compStarts[i], preferredTimescale: timescale),
                                duration: CMTime(seconds: len, preferredTimescale: timescale))
            dst.scaleTimeRange(r, toDuration: CMTime(seconds: len / p.factor, preferredTimescale: timescale))
        }
    }

    static func outputDuration(_ pieces: [EditPiece]) -> Double {
        guard let last = pieces.last else { return 0 }
        return last.outStart + (last.s1 - last.s0) / last.factor
    }

    /// SOURCE time → OUTPUT time (a source time inside a cut maps to the cut edge).
    static func sourceToOutput(_ s: Double, _ pieces: [EditPiece]) -> Double {
        guard !pieces.isEmpty else { return s }
        for p in pieces {
            if s < p.s0 { return p.outStart }                       // inside a cut / before
            if s < p.s1 { return p.outStart + (s - p.s0) / p.factor }
        }
        return outputDuration(pieces)
    }

    /// OUTPUT time → SOURCE time (for placing the source-time playhead).
    static func outputToSource(_ o: Double, _ pieces: [EditPiece]) -> Double {
        guard let last = pieces.last else { return o }
        for p in pieces {
            let segOut = (p.s1 - p.s0) / p.factor
            if o < p.outStart + segOut {
                return p.s0 + max(0, o - p.outStart) * p.factor
            }
        }
        return last.s1
    }
}

import CoreGraphics

/// A point on the auto-zoom "camera" path. `scale` 1.0 = full frame; >1 zooms
/// in. `focusX/Y` are normalized 0…1 in the **video's** space (top-left origin).
struct ZoomKeyframe: Equatable, Codable {
    let t: Double          // seconds (active time, matches the retimed video)
    let scale: CGFloat
    let focusX: CGFloat
    let focusY: CGFloat
}

/// Turns a recorded `InteractionTrack` into an auto-zoom camera path: ease in
/// toward clusters of clicks, pan between them, then ease back out on idle.
/// Pure + deterministic so it's unit-testable against a `.forgerec.json`.
///
/// This is the *default* path the editor (Phase 3c) will let the user tweak —
/// add / move / resize zoom segments, change level + focus.
enum ZoomPlanner {

    struct Options {
        var zoomScale: CGFloat = 1.7   // how far in a click zooms
        var rampIn: Double = 0.45      // ease-in seconds before a click
        var hold: Double = 1.6         // stay zoomed this long after the last click in a cluster
        var rampOut: Double = 0.6      // ease-out seconds back to full frame
        var clusterGap: Double = 1.6   // clicks closer than this merge into one segment
    }

    static func plan(from track: InteractionTrack, options: Options = Options()) -> [ZoomKeyframe] {
        let w = track.screenWidth, h = track.screenHeight
        guard w > 0, h > 0, track.duration > 0 else { return [] }

        // mouseLocation is bottom-left origin → flip Y into top-left video space.
        func norm(_ e: InteractionEvent) -> (CGFloat, CGFloat) {
            (clamp01(CGFloat(e.x / w)), clamp01(CGFloat(1 - e.y / h)))
        }

        let clicks = track.events.filter { $0.kind == .leftClick || $0.kind == .rightClick }

        // No clicks → no zoom; hold the full frame the whole time.
        guard !clicks.isEmpty else {
            return [ZoomKeyframe(t: 0, scale: 1, focusX: 0.5, focusY: 0.5),
                    ZoomKeyframe(t: track.duration, scale: 1, focusX: 0.5, focusY: 0.5)]
        }

        var kfs: [ZoomKeyframe] = [ZoomKeyframe(t: 0, scale: 1, focusX: 0.5, focusY: 0.5)]

        var i = 0
        while i < clicks.count {
            // Group consecutive clicks that are close in time into one segment.
            var j = i
            while j + 1 < clicks.count, clicks[j + 1].t - clicks[j].t < options.clusterGap { j += 1 }

            let (fx, fy) = norm(clicks[i])
            let (lfx, lfy) = norm(clicks[j])

            let zoomInStart = max(0, clicks[i].t - options.rampIn)
            kfs.append(ZoomKeyframe(t: zoomInStart, scale: 1, focusX: fx, focusY: fy))
            kfs.append(ZoomKeyframe(t: clicks[i].t, scale: options.zoomScale, focusX: fx, focusY: fy))
            // Pan to the last click of the cluster while staying zoomed.
            if j > i {
                kfs.append(ZoomKeyframe(t: clicks[j].t, scale: options.zoomScale, focusX: lfx, focusY: lfy))
            }

            // Ease back out unless another cluster starts before the hold ends.
            let outStart = clicks[j].t + options.hold
            let nextStart = (j + 1 < clicks.count) ? clicks[j + 1].t - options.rampIn : .infinity
            if outStart < nextStart {
                let outEnd = min(track.duration, outStart + options.rampOut)
                kfs.append(ZoomKeyframe(t: min(track.duration, outStart),
                                        scale: options.zoomScale, focusX: lfx, focusY: lfy))
                kfs.append(ZoomKeyframe(t: outEnd, scale: 1, focusX: 0.5, focusY: 0.5))
            }
            i = j + 1
        }

        if let last = kfs.last, last.t < track.duration {
            kfs.append(ZoomKeyframe(t: track.duration, scale: last.scale,
                                    focusX: last.focusX, focusY: last.focusY))
        }

        // Strictly-increasing times (CAKeyframeAnimation requires it): nudge dupes.
        return dedupeMonotonic(kfs.sorted { $0.t < $1.t }, duration: track.duration)
    }

    // MARK: - helpers

    private static func clamp01(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }

    private static func dedupeMonotonic(_ kfs: [ZoomKeyframe], duration: Double) -> [ZoomKeyframe] {
        var out: [ZoomKeyframe] = []
        var lastT = -1.0
        for kf in kfs {
            var t = kf.t
            if t <= lastT { t = min(duration, lastT + 0.001) }
            out.append(ZoomKeyframe(t: t, scale: kf.scale, focusX: kf.focusX, focusY: kf.focusY))
            lastT = t
        }
        return out
    }
}

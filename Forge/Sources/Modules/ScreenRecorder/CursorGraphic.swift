import AppKit

/// Pointer look. Arrow styles share the classic shape with different fills;
/// `dot` is a filled presentation disc (hotspot at its centre).
enum CursorStyle: String, CaseIterable, Identifiable {
    case dark, light, accent, dot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .accent: return "Accent"
        case .dot: return "Dot"
        }
    }
}

/// Visual feedback drawn at click events.
enum ClickEffect: String, CaseIterable, Identifiable {
    case none, ring, ripple, spotlight, sparkle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .ring: return "Ring"
        case .ripple: return "Ripple"
        case .spotlight: return "Spotlight"
        case .sparkle: return "Sparkle"
        }
    }
}

/// Synthetic mouse pointer used by the recorder's editor + export.
///
/// We record with the real system cursor hidden (`SCStreamConfiguration
/// .showsCursor = false`) and draw our own enlarged pointer from the captured
/// interaction track — the only way to make it bigger than the OS default.
/// Rendered into a CGContext at EXACT pixel dimensions (NSImage `lockFocus`
/// silently 2×'s on Retina).
enum CursorGraphic {

    /// Cursor height as a fraction of the video height (× the user's scale).
    static let heightFraction: CGFloat = 0.03

    /// Arrow polygon in a top-left design space (tip at 0,0), units ≈ points.
    private static let points: [CGPoint] = [
        CGPoint(x: 0,    y: 0),
        CGPoint(x: 0,    y: 16.5),
        CGPoint(x: 4.2,  y: 12.7),
        CGPoint(x: 7.0,  y: 19.0),
        CGPoint(x: 9.2,  y: 18.0),
        CGPoint(x: 6.3,  y: 11.9),
        CGPoint(x: 12.0, y: 11.9),
    ]
    private static let designW: CGFloat = 12
    private static let designH: CGFloat = 19
    private static let pad: CGFloat = 3            // room for the outline

    /// Image aspect (width / height) for a style.
    static func aspect(for style: CursorStyle) -> CGFloat {
        style == .dot ? 1 : (designW + 2 * pad) / (designH + 2 * pad)
    }

    /// Anchor (bottom-left fractions) of the cursor hotspot for a style.
    static func tipAnchor(for style: CursorStyle) -> CGPoint {
        if style == .dot { return CGPoint(x: 0.5, y: 0.5) }      // centre
        return CGPoint(x: pad / (designW + 2 * pad),
                       y: (designH + pad) / (designH + 2 * pad))
    }

    private static func colors(_ style: CursorStyle) -> (fill: NSColor, stroke: NSColor) {
        switch style {
        case .dark:   return (.black, .white)
        case .light:  return (.white, NSColor(white: 0.15, alpha: 1))
        case .accent: return (.forgeAccent, .white)
        case .dot:    return (NSColor.forgeAccent.withAlphaComponent(0.85), .white)
        }
    }

    /// Renders the pointer as a CGImage exactly `height` pixels tall.
    static func arrowCG(height: CGFloat, style: CursorStyle = .dark) -> CGImage? {
        let h = max(8, height)
        let (fill, stroke) = colors(style)

        if style == .dot {
            let px = max(1, Int(h.rounded()))
            guard let ctx = bitmap(px, px) else { return nil }
            let inset = h * 0.14
            let rect = CGRect(x: inset, y: inset, width: h - 2 * inset, height: h - 2 * inset)
            ctx.setFillColor(fill.cgColor); ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(max(1.5, h * 0.06))
            ctx.strokeEllipse(in: rect)
            return ctx.makeImage()
        }

        let s = h / (designH + 2 * pad)
        let pxW = max(1, Int(((designW + 2 * pad) * s).rounded()))
        let pxH = max(1, Int(h.rounded()))
        guard let ctx = bitmap(pxW, pxH) else { return nil }

        func cv(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x + pad) * s, y: CGFloat(pxH) - (p.y + pad) * s)
        }
        let path = CGMutablePath()
        path.move(to: cv(points[0]))
        for p in points.dropFirst() { path.addLine(to: cv(p)) }
        path.closeSubpath()

        ctx.setLineJoin(.round)
        ctx.addPath(path); ctx.setLineWidth(max(1.5, 2.4 * s))
        ctx.setStrokeColor(stroke.cgColor); ctx.strokePath()
        ctx.addPath(path); ctx.setFillColor(fill.cgColor); ctx.fillPath()
        return ctx.makeImage()
    }

    private static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

import AppKit
import SwiftUI

/// Magnified loupe view for the Color Picker.
/// Shows an 8x magnified region around the cursor with crosshair,
/// pixel grid lines, and color info label.
final class ColorLoupeView: NSView {

    // MARK: - Properties

    var onPick: ((NSColor, NSPoint) -> Void)?
    var onCancel: (() -> Void)?
    var outputFormat: ColorFormat = .hex

    private var mouseLocation: NSPoint = .zero
    private var zoomLevel: CGFloat = 8.0
    private var currentColor: NSColor = .black

    /// While true the loupe is frozen on its "✓ Copied …" confirmation
    /// (set the instant the user clicks to pick) and ignores further
    /// mouse-move / pick input until the owner dismisses it. Gives the
    /// user a clear "yes, it copied" beat instead of the picker vanishing
    /// the moment they click.
    private var showingCopied = false
    private var copiedValue = ""

    private let loupeSize: CGFloat = 160
    private let infoHeight: CGFloat = 48
    private let gridLineWidth: CGFloat = 0.5

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Mouse Tracking

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }

    func updatePosition(_ point: NSPoint) {
        // Frozen on the copied confirmation — ignore movement so the
        // banner stays put while the user reads it.
        guard !showingCopied else { return }
        mouseLocation = point
        captureColorAtMouse()
        needsDisplay = true
    }

    func adjustZoom(delta: CGFloat) {
        guard !showingCopied else { return }
        zoomLevel = max(2, min(16, zoomLevel + (delta > 0 ? 1 : -1)))
        needsDisplay = true
    }

    func pickAtCurrentPosition() {
        // Block double-picks while the copied banner is showing.
        guard !showingCopied else { return }
        onPick?(currentColor, mouseLocation)
    }

    /// Switch the info bar into its green "✓ Copied <value>" state and
    /// freeze the loupe. The owner (ColorPickerModule) holds it here for
    /// a beat, then tears the overlay down.
    func flashCopied(_ value: String) {
        showingCopied = true
        copiedValue = value
        needsDisplay = true
    }

    // MARK: - Color Capture

    private func captureColorAtMouse() {
        // Convert to screen coordinates
        guard let window = self.window else { return }
        let screenPoint = window.convertPoint(toScreen: mouseLocation)

        // Capture a 1x1 pixel at the mouse location
        let captureRect = CGRect(
            x: screenPoint.x,
            y: NSScreen.main!.frame.height - screenPoint.y, // Flip Y for CGImage
            width: 1,
            height: 1
        )

        if let image = CGWindowListCreateImage(
            captureRect,
            .optionOnScreenBelowWindow,
            CGWindowID(window.windowNumber),
            [.bestResolution]
        ) {
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let color = bitmap.colorAt(x: 0, y: 0) {
                currentColor = color
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Clear background (transparent)
        context.clear(bounds)

        // Draw the magnified loupe
        drawLoupe(context: context)
    }

    private func drawLoupe(context: CGContext) {
        guard let window = self.window, let screen = NSScreen.main else { return }

        let screenPoint = window.convertPoint(toScreen: mouseLocation)
        let captureSize = loupeSize / zoomLevel

        // Capture the region around the cursor
        let captureRect = CGRect(
            x: screenPoint.x - captureSize / 2,
            y: screen.frame.height - screenPoint.y - captureSize / 2,
            width: captureSize,
            height: captureSize
        )

        if let image = CGWindowListCreateImage(
            captureRect,
            .optionOnScreenBelowWindow,
            CGWindowID(window.windowNumber),
            [.bestResolution]
        ) {
            // Loupe frame position (offset from cursor)
            let loupeRect = NSRect(
                x: mouseLocation.x + 20,
                y: mouseLocation.y - loupeSize - infoHeight - 20,
                width: loupeSize,
                height: loupeSize + infoHeight
            )

            // Keep loupe on screen
            var adjustedRect = loupeRect
            if adjustedRect.maxX > bounds.width {
                adjustedRect.origin.x = mouseLocation.x - loupeSize - 20
            }
            if adjustedRect.minY < 0 {
                adjustedRect.origin.y = mouseLocation.y + 20
            }

            context.saveGState()

            // Draw loupe shadow
            let shadowRect = adjustedRect.insetBy(dx: -2, dy: -2)
            context.setShadow(offset: CGSize(width: 0, height: -4), blur: 16, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            context.setFillColor(NSColor.white.cgColor)
            let roundedPath = CGPath(roundedRect: shadowRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
            context.addPath(roundedPath)
            context.fillPath()

            context.setShadow(offset: .zero, blur: 0)

            // Clip to rounded rect
            let clipPath = CGPath(roundedRect: adjustedRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
            context.addPath(clipPath)
            context.clip()

            // Draw magnified image
            let imageRect = NSRect(
                x: adjustedRect.origin.x,
                y: adjustedRect.origin.y + infoHeight,
                width: loupeSize,
                height: loupeSize
            )
            context.interpolationQuality = .none // Pixel-perfect
            context.draw(image, in: imageRect)

            // Draw pixel grid
            let pixelSize = loupeSize / captureSize
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
            context.setLineWidth(gridLineWidth)

            let gridStart = imageRect.origin
            var x = gridStart.x
            while x <= imageRect.maxX {
                context.move(to: CGPoint(x: x, y: imageRect.minY))
                context.addLine(to: CGPoint(x: x, y: imageRect.maxY))
                x += pixelSize
            }
            var y = gridStart.y
            while y <= imageRect.maxY {
                context.move(to: CGPoint(x: imageRect.minX, y: y))
                context.addLine(to: CGPoint(x: imageRect.maxX, y: y))
                y += pixelSize
            }
            context.strokePath()

            // Draw crosshair at center pixel
            let centerX = imageRect.midX
            let centerY = imageRect.midY
            let crossSize = pixelSize

            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2)
            context.stroke(CGRect(
                x: centerX - crossSize / 2,
                y: centerY - crossSize / 2,
                width: crossSize,
                height: crossSize
            ))
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(1)
            context.stroke(CGRect(
                x: centerX - crossSize / 2 - 0.5,
                y: centerY - crossSize / 2 - 0.5,
                width: crossSize + 1,
                height: crossSize + 1
            ))

            // Draw info bar at bottom
            let infoRect = NSRect(
                x: adjustedRect.origin.x,
                y: adjustedRect.origin.y,
                width: loupeSize,
                height: infoHeight
            )

            context.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 0.95).cgColor)
            context.fill(infoRect)

            // Draw color swatch. Its outline turns green during the
            // copied confirmation as an extra "it worked" cue.
            let swatchRect = NSRect(x: infoRect.minX + 10, y: infoRect.minY + 10, width: 28, height: 28)
            context.setFillColor(currentColor.cgColor)
            context.fillEllipse(in: swatchRect)
            context.setStrokeColor(
                (showingCopied ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.3)).cgColor
            )
            context.setLineWidth(showingCopied ? 2 : 1)
            context.strokeEllipse(in: swatchRect)

            let rgb = currentColor.usingColorSpace(.sRGB) ?? currentColor
            let hexString = String(format: "#%02X%02X%02X",
                                   Int(rgb.redComponent * 255),
                                   Int(rgb.greenComponent * 255),
                                   Int(rgb.blueComponent * 255))

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let subAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.65)
            ]

            if showingCopied {
                // Confirmation state: "✓ Copied" (green) over the copied value.
                let copiedAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.systemGreen
                ]
                NSAttributedString(string: "✓ Copied", attributes: copiedAttributes)
                    .draw(at: NSPoint(x: infoRect.minX + 46, y: infoRect.minY + 24))
                NSAttributedString(string: copiedValue, attributes: subAttributes)
                    .draw(at: NSPoint(x: infoRect.minX + 46, y: infoRect.minY + 8))
            } else {
                // Live state: hex (the value that gets copied) over the
                // nearest named color so the user knows what they're on.
                NSAttributedString(string: hexString, attributes: titleAttributes)
                    .draw(at: NSPoint(x: infoRect.minX + 46, y: infoRect.minY + 24))
                NSAttributedString(string: ColorNames.nearestName(to: currentColor), attributes: subAttributes)
                    .draw(at: NSPoint(x: infoRect.minX + 46, y: infoRect.minY + 8))
            }

            context.restoreGState()
        }

        // Draw small crosshair at actual cursor position
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)

        let cursorLen: CGFloat = 12
        let gap: CGFloat = 4
        // Horizontal lines
        context.move(to: CGPoint(x: mouseLocation.x - cursorLen, y: mouseLocation.y))
        context.addLine(to: CGPoint(x: mouseLocation.x - gap, y: mouseLocation.y))
        context.move(to: CGPoint(x: mouseLocation.x + gap, y: mouseLocation.y))
        context.addLine(to: CGPoint(x: mouseLocation.x + cursorLen, y: mouseLocation.y))
        // Vertical lines
        context.move(to: CGPoint(x: mouseLocation.x, y: mouseLocation.y - cursorLen))
        context.addLine(to: CGPoint(x: mouseLocation.x, y: mouseLocation.y - gap))
        context.move(to: CGPoint(x: mouseLocation.x, y: mouseLocation.y + gap))
        context.addLine(to: CGPoint(x: mouseLocation.x, y: mouseLocation.y + cursorLen))
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Nearest named color

/// Maps an arbitrary picked color to the closest human-readable name
/// from the CSS/X11 named-color set. Used by the loupe so the user sees
/// "Tomato" or "Steel Blue" next to the raw hex while sampling.
///
/// Matching uses the "redmean" weighted-RGB distance — a cheap, well-known
/// approximation of perceptual difference that's noticeably better than
/// plain Euclidean RGB (it weights red/blue error by where the color sits
/// on the red axis, matching how the eye trades off those channels). Good
/// enough for a friendly label; we're not colour-grading film.
enum ColorNames {

    /// (display name, r, g, b) with components in 0...255.
    private static let table: [(name: String, r: Double, g: Double, b: Double)] = [
        ("Black", 0, 0, 0), ("White", 255, 255, 255),
        ("Gray", 128, 128, 128), ("Dark Gray", 64, 64, 64),
        ("Light Gray", 200, 200, 200), ("Silver", 192, 192, 192),
        ("Dim Gray", 105, 105, 105), ("Slate Gray", 112, 128, 144),
        ("Red", 255, 0, 0), ("Dark Red", 139, 0, 0),
        ("Firebrick", 178, 34, 34), ("Crimson", 220, 20, 60),
        ("Vermillion", 227, 66, 52), ("Tomato", 255, 99, 71),
        ("Coral", 255, 127, 80), ("Salmon", 250, 128, 114),
        ("Indian Red", 205, 92, 92), ("Maroon", 128, 0, 0),
        ("Orange", 255, 165, 0), ("Dark Orange", 255, 140, 0),
        ("Orange Red", 255, 69, 0), ("Gold", 255, 215, 0),
        ("Amber", 255, 191, 0), ("Goldenrod", 218, 165, 32),
        ("Yellow", 255, 255, 0), ("Khaki", 240, 230, 140),
        ("Dark Khaki", 189, 183, 107), ("Olive", 128, 128, 0),
        ("Beige", 245, 245, 220), ("Ivory", 255, 255, 240),
        ("Wheat", 245, 222, 179), ("Tan", 210, 180, 140),
        ("Sandy Brown", 244, 164, 96), ("Peru", 205, 133, 63),
        ("Chocolate", 210, 105, 30), ("Brown", 165, 42, 42),
        ("Sienna", 160, 82, 45), ("Saddle Brown", 139, 69, 19),
        ("Green", 0, 128, 0), ("Lime", 0, 255, 0),
        ("Lime Green", 50, 205, 50), ("Forest Green", 34, 139, 34),
        ("Dark Green", 0, 100, 0), ("Sea Green", 46, 139, 87),
        ("Medium Sea Green", 60, 179, 113), ("Spring Green", 0, 255, 127),
        ("Olive Drab", 107, 142, 35), ("Yellow Green", 154, 205, 50),
        ("Chartreuse", 127, 255, 0), ("Pale Green", 152, 251, 152),
        ("Teal", 0, 128, 128), ("Dark Cyan", 0, 139, 139),
        ("Cyan", 0, 255, 255), ("Aqua", 0, 255, 255),
        ("Turquoise", 64, 224, 208), ("Medium Turquoise", 72, 209, 204),
        ("Aquamarine", 127, 255, 212), ("Cadet Blue", 95, 158, 160),
        ("Light Blue", 173, 216, 230), ("Sky Blue", 135, 206, 235),
        ("Light Sky Blue", 135, 206, 250), ("Deep Sky Blue", 0, 191, 255),
        ("Dodger Blue", 30, 144, 255), ("Cornflower Blue", 100, 149, 237),
        ("Steel Blue", 70, 130, 180), ("Royal Blue", 65, 105, 225),
        ("Blue", 0, 0, 255), ("Medium Blue", 0, 0, 205),
        ("Dark Blue", 0, 0, 139), ("Navy", 0, 0, 128),
        ("Midnight Blue", 25, 25, 112), ("Slate Blue", 106, 90, 205),
        ("Indigo", 75, 0, 130), ("Purple", 128, 0, 128),
        ("Dark Violet", 148, 0, 211), ("Blue Violet", 138, 43, 226),
        ("Medium Purple", 147, 112, 219), ("Violet", 238, 130, 238),
        ("Orchid", 218, 112, 214), ("Magenta", 255, 0, 255),
        ("Fuchsia", 255, 0, 255), ("Medium Orchid", 186, 85, 211),
        ("Plum", 221, 160, 221), ("Thistle", 216, 191, 216),
        ("Lavender", 230, 230, 250), ("Pink", 255, 192, 203),
        ("Light Pink", 255, 182, 193), ("Hot Pink", 255, 105, 180),
        ("Deep Pink", 255, 20, 147), ("Pale Violet Red", 219, 112, 147),
        ("Rose", 255, 228, 225), ("Mint Cream", 245, 255, 250),
        ("Azure", 240, 255, 255), ("Alice Blue", 240, 248, 255),
        ("Snow", 255, 250, 250), ("Linen", 250, 240, 230),
        ("Sea Shell", 255, 245, 238), ("Honeydew", 240, 255, 240),
    ]

    static func nearestName(to color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Double(rgb.redComponent) * 255
        let g = Double(rgb.greenComponent) * 255
        let b = Double(rgb.blueComponent) * 255

        var bestName = "—"
        var bestDistance = Double.greatestFiniteMagnitude
        for entry in table {
            let rmean = (r + entry.r) / 2
            let dr = r - entry.r
            let dg = g - entry.g
            let db = b - entry.b
            // Redmean weighted distance (squared — no need for sqrt to rank).
            let dist = (2 + rmean / 256) * dr * dr
                     + 4 * dg * dg
                     + (2 + (255 - rmean) / 256) * db * db
            if dist < bestDistance {
                bestDistance = dist
                bestName = entry.name
            }
        }
        return bestName
    }
}

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
        mouseLocation = point
        captureColorAtMouse()
        needsDisplay = true
    }

    func adjustZoom(delta: CGFloat) {
        zoomLevel = max(2, min(16, zoomLevel + (delta > 0 ? 1 : -1)))
        needsDisplay = true
    }

    func pickAtCurrentPosition() {
        onPick?(currentColor, mouseLocation)
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

            // Draw color swatch
            let swatchRect = NSRect(x: infoRect.minX + 10, y: infoRect.minY + 10, width: 28, height: 28)
            context.setFillColor(currentColor.cgColor)
            context.fillEllipse(in: swatchRect)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: swatchRect)

            // Draw color text
            let rgb = currentColor.usingColorSpace(.sRGB) ?? currentColor
            let hexString = String(format: "#%02X%02X%02X",
                                   Int(rgb.redComponent * 255),
                                   Int(rgb.greenComponent * 255),
                                   Int(rgb.blueComponent * 255))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let subAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.6)
            ]

            let hexStr = NSAttributedString(string: hexString, attributes: attributes)
            hexStr.draw(at: NSPoint(x: infoRect.minX + 46, y: infoRect.minY + 24))

            let rgbStr = NSAttributedString(
                string: String(format: "rgb(%d, %d, %d)",
                               Int(rgb.redComponent * 255),
                               Int(rgb.greenComponent * 255),
                               Int(rgb.blueComponent * 255)),
                attributes: subAttributes
            )
            rgbStr.draw(at: NSPoint(x: infoRect.minX + 46, y: infoRect.minY + 8))

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

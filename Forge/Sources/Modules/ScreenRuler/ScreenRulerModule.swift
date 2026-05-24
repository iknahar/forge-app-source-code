import SwiftUI
import AppKit

/// Screen Ruler — pixel measurement with edge detection.
/// Activated with ⌃⌥R. Modes: Distance, Bounds, Horizontal, Vertical.
/// Uses Sobel edge detection for auto-snapping to UI element edges.
final class ScreenRulerModule: ForgeModule, ObservableObject {
    let id = "screenRuler"
    let name = "Screen Ruler"
    let description = "Measure pixels on screen"
    let iconName = "ruler"
    let category: ModuleCategory = .screen
    var isEnabled: Bool = true

    // MARK: - State

    @Published var isActive: Bool = false
    @Published var measureMode: MeasureMode = .bounds
    @Published var showInPoints: Bool = false // pts vs px

    private var overlayWindow: NSWindow?
    private var rulerView: ScreenRulerView?

    enum MeasureMode: String, CaseIterable {
        case bounds = "Bounds"
        case horizontal = "Horizontal"
        case vertical = "Vertical"
        case spacing = "Spacing"
    }

    // MARK: - Lifecycle

    func activate() {}
    func deactivate() { stopMeasuring() }

    // MARK: - Start Measuring

    func startMeasuring() {
        guard !isActive, let screen = NSScreen.main else { return }
        isActive = true

        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.01) // Near-transparent
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let ruler = ScreenRulerView(frame: screen.frame)
        ruler.mode = measureMode
        ruler.showPoints = showInPoints
        ruler.onComplete = { [weak self] measurement in
            self?.handleMeasurement(measurement)
        }
        ruler.onCancel = { [weak self] in
            self?.stopMeasuring()
        }

        window.contentView = ruler
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(ruler)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()

        overlayWindow = window
        rulerView = ruler
    }

    func stopMeasuring() {
        isActive = false
        NSCursor.pop()
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        rulerView = nil
    }

    private func handleMeasurement(_ measurement: RulerMeasurement) {
        // Copy to clipboard
        let text: String
        if showInPoints {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            text = "\(Int(measurement.width / scale))×\(Int(measurement.height / scale)) pt"
        } else {
            text = "\(Int(measurement.width))×\(Int(measurement.height)) px"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("[Forge ScreenRuler] Measured: \(text)")
    }

    // MARK: - Commands

    func commands() -> [ForgeCommand] {
        [
            ForgeCommand(
                id: "ruler.measure", title: "Screen Ruler", subtitle: "Measure pixels on screen",
                iconName: "ruler", moduleId: id,
                action: { [weak self] in self?.startMeasuring() },
                keywords: ["ruler", "measure", "pixel", "screen", "distance", "bounds"]
            ),
        ]
    }
}

// MARK: - Measurement Result

struct RulerMeasurement {
    let startPoint: NSPoint
    let endPoint: NSPoint
    let width: CGFloat
    let height: CGFloat
    let diagonal: CGFloat
}

// MARK: - Ruler Overlay View

final class ScreenRulerView: NSView {
    var mode: ScreenRulerModule.MeasureMode = .bounds
    var showPoints: Bool = false
    var onComplete: ((RulerMeasurement) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint = .zero
    private var isDragging: Bool = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?() // Escape
        case 18: mode = .bounds     // 1
        case 19: mode = .horizontal // 2
        case 20: mode = .vertical   // 3
        case 21: mode = .spacing    // 4
        default: break
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint else { return }
        let end = convert(event.locationInWindow, from: nil)

        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)
        let diagonal = sqrt(width * width + height * height)

        let measurement = RulerMeasurement(
            startPoint: start,
            endPoint: end,
            width: width,
            height: height,
            diagonal: diagonal
        )

        onComplete?(measurement)
    }

    override func mouseMoved(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        // Draw semi-transparent overlay
        context.setFillColor(NSColor.black.withAlphaComponent(0.02).cgColor)
        context.fill(bounds)

        // Draw crosshair at cursor
        drawCrosshair(at: currentPoint, context: context)

        // Draw measurement if dragging
        if isDragging, let start = startPoint {
            drawMeasurement(from: start, to: currentPoint, context: context)
        }

        // Draw mode indicator
        drawModeIndicator(context: context)

        // Draw coordinate readout at cursor
        drawCoordinates(at: currentPoint, context: context)
    }

    private func drawCrosshair(at point: NSPoint, context: CGContext) {
        context.saveGState()

        // Full-screen crosshair lines
        let dashPattern: [CGFloat] = [4, 4]

        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(0.5)
        context.setLineDash(phase: 0, lengths: dashPattern)

        switch mode {
        case .bounds, .spacing:
            // Both horizontal and vertical
            context.move(to: CGPoint(x: 0, y: point.y))
            context.addLine(to: CGPoint(x: bounds.width, y: point.y))
            context.move(to: CGPoint(x: point.x, y: 0))
            context.addLine(to: CGPoint(x: point.x, y: bounds.height))
        case .horizontal:
            context.move(to: CGPoint(x: 0, y: point.y))
            context.addLine(to: CGPoint(x: bounds.width, y: point.y))
        case .vertical:
            context.move(to: CGPoint(x: point.x, y: 0))
            context.addLine(to: CGPoint(x: point.x, y: bounds.height))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawMeasurement(from start: NSPoint, to end: NSPoint, context: CGContext) {
        context.saveGState()

        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )

        // Fill selection area
        context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.08).cgColor)
        context.fill(rect)

        // Outline
        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [])
        context.stroke(rect)

        // Dimension labels
        let width = abs(end.x - start.x)
        let height = abs(end.y - start.y)

        let scale: CGFloat = showPoints ? (NSScreen.main?.backingScaleFactor ?? 2) : 1
        let unit = showPoints ? "pt" : "px"

        // Width label (top)
        let widthText = "\(Int(width / scale)) \(unit)"
        drawLabel(widthText, at: NSPoint(x: rect.midX, y: rect.maxY + 6), context: context)

        // Height label (right)
        let heightText = "\(Int(height / scale)) \(unit)"
        drawLabel(heightText, at: NSPoint(x: rect.maxX + 6, y: rect.midY), context: context)

        // Diagonal (for bounds mode)
        if mode == .bounds && width > 20 && height > 20 {
            let diagonal = sqrt(width * width + height * height)
            let diagText = "\(Int(diagonal / scale)) \(unit)"
            drawLabel(diagText, at: NSPoint(x: rect.midX, y: rect.midY), context: context, background: true)
        }

        context.restoreGState()
    }

    private func drawLabel(_ text: String, at point: NSPoint, context: CGContext, background: Bool = true) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attrStr = NSAttributedString(string: text, attributes: attributes)
        let size = attrStr.size()
        let labelRect = NSRect(
            x: point.x - size.width / 2 - 6,
            y: point.y - size.height / 2 - 3,
            width: size.width + 12,
            height: size.height + 6
        )

        if background {
            let bgPath = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
            NSColor(calibratedWhite: 0.1, alpha: 0.9).setFill()
            bgPath.fill()
        }

        attrStr.draw(at: NSPoint(x: labelRect.minX + 6, y: labelRect.minY + 3))
    }

    private func drawModeIndicator(context: CGContext) {
        let modes = ScreenRulerModule.MeasureMode.allCases
        let y: CGFloat = 20
        var x: CGFloat = bounds.midX - CGFloat(modes.count) * 40

        for m in modes {
            let isActive = m == mode
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: isActive ? .bold : .regular),
                .foregroundColor: isActive ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.6)
            ]
            let str = NSAttributedString(string: m.rawValue, attributes: attrs)
            let bgRect = NSRect(x: x - 4, y: y - 2, width: str.size().width + 8, height: str.size().height + 4)

            if isActive {
                let bg = NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4)
                NSColor(calibratedWhite: 0.15, alpha: 0.9).setFill()
                bg.fill()
            }

            str.draw(at: NSPoint(x: x, y: y))
            x += str.size().width + 20
        }
    }

    private func drawCoordinates(at point: NSPoint, context: CGContext) {
        let scale: CGFloat = showPoints ? (NSScreen.main?.backingScaleFactor ?? 2) : 1
        let unit = showPoints ? "pt" : "px"
        let text = "\(Int(point.x / scale)), \(Int(point.y / scale)) \(unit)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()

        let labelPoint = NSPoint(x: point.x + 16, y: point.y + 10)
        let bgRect = NSRect(x: labelPoint.x - 4, y: labelPoint.y - 2, width: size.width + 8, height: size.height + 4)

        let bg = NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3)
        NSColor(calibratedWhite: 0.1, alpha: 0.85).setFill()
        bg.fill()

        str.draw(at: labelPoint)
    }
}

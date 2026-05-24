import SwiftUI
import AppKit

/// ZoomIt — screen zoom, live annotation, and break timer.
/// Activated with ⌃⌥Z. Scroll to zoom in/out, draw annotations,
/// press T for break timer countdown.
final class ZoomItModule: ForgeModule, ObservableObject {
    let id = "zoomIt"
    let name = "ZoomIt"
    let description = "Zoom, annotate, and present your screen"
    let iconName = "plus.magnifyingglass"
    let category: ModuleCategory = .screen
    var isEnabled: Bool = true

    // MARK: - State

    @Published var isZoomed: Bool = false
    @Published var isAnnotating: Bool = false
    @Published var isTimerRunning: Bool = false
    @Published var timerSeconds: Int = 300 // 5-minute default
    @Published var timerRemaining: Int = 0
    @Published var zoomLevel: CGFloat = 1.0
    @Published var annotationColor: NSColor = .systemRed
    @Published var penWidth: CGFloat = 3.0

    private var overlayWindow: NSWindow?
    private var zoomView: ZoomItOverlayView?
    private var timerWindow: NSWindow?
    private var timerCountdown: Timer?
    private var capturedImage: CGImage?

    let maxZoom: CGFloat = 6.0
    let minZoom: CGFloat = 1.0          // 1.0 = true zoom-out (image fills screen 1:1)
    let zoomStep: CGFloat = 0.25

    // MARK: - Lifecycle

    func activate() {}
    func deactivate() {
        stopZoom()
        stopTimer()
    }

    // MARK: - Zoom

    func startZoom() {
        guard !isZoomed, let screen = NSScreen.main else { return }

        // Capture the current screen
        guard let image = CGWindowListCreateImage(
            screen.frame,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else { return }

        capturedImage = image
        isZoomed = true
        zoomLevel = 2.0

        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = ZoomItOverlayView(frame: screen.frame)
        view.capturedImage = image
        view.zoomLevel = zoomLevel
        view.annotationColor = annotationColor
        view.penWidth = penWidth
        view.onZoomChanged = { [weak self] delta in
            self?.adjustZoom(delta: delta)
        }
        view.onZoomReset = { [weak self] in
            self?.resetZoom()
        }
        view.onToggleAnnotation = { [weak self] in
            self?.toggleAnnotation()
        }
        view.onClearAnnotations = { [weak self] in
            self?.zoomView?.clearAnnotations()
        }
        view.onColorChanged = { [weak self] color in
            self?.annotationColor = color
            self?.zoomView?.annotationColor = color
            self?.zoomView?.needsDisplay = true
        }
        view.onWidthChanged = { [weak self] width in
            self?.penWidth = width
            self?.zoomView?.penWidth = width
            self?.zoomView?.needsDisplay = true
        }
        view.onExit = { [weak self] in
            self?.stopZoom()
        }

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)         // ensure view receives keyDown
        NSApp.activate(ignoringOtherApps: true)

        overlayWindow = window
        zoomView = view
    }

    func stopZoom() {
        isZoomed = false
        isAnnotating = false
        zoomLevel = 1.0
        capturedImage = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        zoomView = nil
    }

    private func adjustZoom(delta: CGFloat) {
        let newZoom = zoomLevel + (delta > 0 ? zoomStep : -zoomStep)
        zoomLevel = max(minZoom, min(maxZoom, newZoom))
        zoomView?.zoomLevel = zoomLevel
        zoomView?.clampPanOffset()             // re-clamp so pan stays valid
        zoomView?.needsDisplay = true
    }

    private func resetZoom() {
        zoomLevel = 1.0
        zoomView?.zoomLevel = 1.0
        zoomView?.clampPanOffset()
        zoomView?.needsDisplay = true
    }

    private func toggleAnnotation() {
        isAnnotating.toggle()
        zoomView?.isAnnotating = isAnnotating
        if isAnnotating {
            NSCursor.crosshair.push()
        } else {
            NSCursor.pop()
        }
    }

    // MARK: - Break Timer

    func startTimer() {
        guard !isTimerRunning, let screen = NSScreen.main else { return }
        isTimerRunning = true
        timerRemaining = timerSeconds

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = NSColor.black
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let timerView = BreakTimerView(frame: screen.frame)
        timerView.totalSeconds = timerSeconds
        timerView.remainingSeconds = timerRemaining
        timerView.onCancel = { [weak self] in
            self?.stopTimer()
        }

        window.contentView = timerView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        timerWindow = window

        timerCountdown = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.timerRemaining -= 1
            (self.timerWindow?.contentView as? BreakTimerView)?.remainingSeconds = self.timerRemaining
            self.timerWindow?.contentView?.needsDisplay = true

            if self.timerRemaining <= 0 {
                self.stopTimer()
            }
        }
    }

    func stopTimer() {
        isTimerRunning = false
        timerCountdown?.invalidate()
        timerCountdown = nil
        timerWindow?.orderOut(nil)
        timerWindow = nil
    }

    // MARK: - Commands

    func commands() -> [ForgeCommand] {
        [
            ForgeCommand(
                id: "zoomit.zoom", title: "ZoomIt — Zoom Screen", subtitle: "Magnify screen region",
                iconName: "plus.magnifyingglass", moduleId: id,
                action: { [weak self] in self?.startZoom() },
                keywords: ["zoom", "magnify", "screen", "present", "enlarge"]
            ),
            ForgeCommand(
                id: "zoomit.timer", title: "ZoomIt — Break Timer", subtitle: "Fullscreen countdown timer",
                iconName: "timer", moduleId: id,
                action: { [weak self] in self?.startTimer() },
                keywords: ["timer", "break", "countdown", "rest", "pause"]
            ),
        ]
    }
}

// MARK: - Zoom Overlay View

final class ZoomItOverlayView: NSView {
    var capturedImage: CGImage?
    var zoomLevel: CGFloat = 2.0
    var isAnnotating: Bool = false
    var annotationColor: NSColor = .systemRed
    var penWidth: CGFloat = 3.0

    var onZoomChanged: ((CGFloat) -> Void)?
    var onZoomReset: (() -> Void)?
    var onToggleAnnotation: (() -> Void)?
    var onClearAnnotations: (() -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onWidthChanged: ((CGFloat) -> Void)?
    var onExit: (() -> Void)?

    /// Hit-test rects for the floating visual toolbar. Recomputed each draw.
    private struct ToolbarHit {
        let rect: NSRect
        let action: ToolbarAction
    }
    private enum ToolbarAction {
        case color(NSColor)
        case thickness(CGFloat)
        case toggleAnnotation
        case clear
        case exit
    }
    private var toolbarHits: [ToolbarHit] = []

    static let toolbarColors: [NSColor] = [
        NSColor(srgbRed: 0.906, green: 0.16, blue: 0.012, alpha: 1),   // red (Forge accent)
        NSColor(srgbRed: 1.00,  green: 0.62, blue: 0.04,  alpha: 1),   // orange
        NSColor(srgbRed: 1.00,  green: 0.84, blue: 0.04,  alpha: 1),   // yellow
        NSColor(srgbRed: 0.20,  green: 0.78, blue: 0.35,  alpha: 1),   // green
        NSColor(srgbRed: 0.04,  green: 0.52, blue: 1.00,  alpha: 1),   // blue
        NSColor(srgbRed: 0.75,  green: 0.35, blue: 0.95,  alpha: 1),   // purple
        NSColor.white,
        NSColor(white: 0.10, alpha: 1),                                // near-black
    ]
    static let toolbarThicknesses: [CGFloat] = [2, 4, 6, 10]

    private var panOffset: CGPoint = .zero
    private var lastMouseLocation: NSPoint = .zero
    private var isPanning: Bool = false

    // Annotation
    private var annotations: [[NSPoint]] = []
    private var annotationColors: [NSColor] = []
    private var annotationWidths: [CGFloat] = []
    private var currentStroke: [NSPoint] = []
    private var isDrawing: Bool = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onExit?()                          // Escape
        case 0:  onToggleAnnotation?()              // A — toggle annotation
        case 8:  onClearAnnotations?()              // C — clear annotations

        // Zoom in / out via keyboard (= or + and -)
        case 24, 69:                                // = / + key — zoom in
            onZoomChanged?(+1)
        case 27, 78:                                // - key (main row) / minus on numpad — zoom out
            onZoomChanged?(-1)
        case 29:                                    // 0 — reset to 1×
            onZoomReset?()

        // Arrow keys — pan
        case 123:                                   // ← left
            panBy(dx:  60, dy:    0)
        case 124:                                   // → right
            panBy(dx: -60, dy:    0)
        case 125:                                   // ↓ down
            panBy(dx:   0, dy:   60)
        case 126:                                   // ↑ up
            panBy(dx:   0, dy:  -60)

        // Color shortcuts
        case 15:                                    // R — red
            annotationColor = .systemRed
            onColorChanged?(.systemRed)
        case 5:                                     // G — green
            annotationColor = .systemGreen
            onColorChanged?(.systemGreen)
        case 11:                                    // B — blue
            annotationColor = .systemBlue
            onColorChanged?(.systemBlue)
        case 16:                                    // Y — yellow
            annotationColor = .systemYellow
            onColorChanged?(.systemYellow)
        case 46:                                    // M — magenta/white
            annotationColor = .white
            onColorChanged?(.white)
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        onZoomChanged?(event.scrollingDeltaY)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check toolbar first — clicks on toolbar shouldn't pan/draw
        for hit in toolbarHits where hit.rect.contains(point) {
            switch hit.action {
            case .color(let c):
                annotationColor = c
                onColorChanged?(c)
            case .thickness(let w):
                penWidth = w
                onWidthChanged?(w)
            case .toggleAnnotation:
                onToggleAnnotation?()
            case .clear:
                onClearAnnotations?()
            case .exit:
                onExit?()
            }
            needsDisplay = true
            return
        }

        if isAnnotating {
            isDrawing = true
            currentStroke = [point]
        } else {
            isPanning = true
            lastMouseLocation = point
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isDrawing {
            currentStroke.append(point)
            needsDisplay = true
        } else if isPanning {
            let dx = point.x - lastMouseLocation.x
            let dy = point.y - lastMouseLocation.y
            panBy(dx: dx, dy: dy)
            lastMouseLocation = point
        }
    }

    /// Shift `panOffset` and clamp so the zoomed image never goes fully off-screen.
    func panBy(dx: CGFloat, dy: CGFloat) {
        panOffset.x += dx
        panOffset.y += dy
        clampPanOffset()
        needsDisplay = true
    }

    /// Reset pan when zoom changes so the visible region stays inside the image.
    func clampPanOffset() {
        guard let image = capturedImage, zoomLevel > 1 else {
            // At 1× zoom there's nothing to pan
            panOffset = .zero
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let imageW = CGFloat(image.width) / scale
        let imageH = CGFloat(image.height) / scale
        let zoomedW = imageW * zoomLevel
        let zoomedH = imageH * zoomLevel
        // Max pan: half the difference between zoomed image and view.
        let limitX = max(0, (zoomedW - bounds.width)  / 2)
        let limitY = max(0, (zoomedH - bounds.height) / 2)
        panOffset.x = max(-limitX, min(limitX, panOffset.x))
        panOffset.y = max(-limitY, min(limitY, panOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        if isDrawing && !currentStroke.isEmpty {
            annotations.append(currentStroke)
            annotationColors.append(annotationColor)
            annotationWidths.append(penWidth)
            currentStroke = []
            isDrawing = false
        }
        isPanning = false
    }

    func clearAnnotations() {
        annotations.removeAll()
        annotationColors.removeAll()
        annotationWidths.removeAll()
        currentStroke.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let image = capturedImage else { return }

        context.clear(bounds)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        // Calculate zoomed rect centered with pan offset
        let imageWidth = CGFloat(image.width) / (NSScreen.main?.backingScaleFactor ?? 2)
        let imageHeight = CGFloat(image.height) / (NSScreen.main?.backingScaleFactor ?? 2)

        let zoomedWidth = imageWidth * zoomLevel
        let zoomedHeight = imageHeight * zoomLevel

        let drawRect = CGRect(
            x: bounds.midX - zoomedWidth / 2 + panOffset.x,
            y: bounds.midY - zoomedHeight / 2 + panOffset.y,
            width: zoomedWidth,
            height: zoomedHeight
        )

        // Draw the captured screen zoomed
        context.interpolationQuality = .high
        context.draw(image, in: drawRect)

        // Draw annotations
        for (index, stroke) in annotations.enumerated() {
            drawStroke(stroke, color: annotationColors[index], width: annotationWidths[index], context: context)
        }

        // Draw current stroke
        if !currentStroke.isEmpty {
            drawStroke(currentStroke, color: annotationColor, width: penWidth, context: context)
        }

        // Draw toolbar hint
        drawToolbar(context: context)
    }

    private func drawStroke(_ points: [NSPoint], color: NSColor, width: CGFloat, context: CGContext) {
        guard points.count > 1 else { return }

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.move(to: points[0])
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
        context.restoreGState()
    }

    /// Visual floating toolbar — color pills, thickness sizes, action icons.
    /// All items are clickable; keyboard shortcuts still work.
    private func drawToolbar(context: CGContext) {
        toolbarHits.removeAll()

        // Layout constants
        let colorDiameter: CGFloat = 22
        let colorSpacing: CGFloat = 10
        let groupGap: CGFloat = 18
        let thicknessButtonW: CGFloat = 30
        let thicknessButtonH: CGFloat = 28
        let iconButtonSize: CGFloat = 30
        let padding: CGFloat = 16
        let toolbarHeight: CGFloat = 56

        let numColors = Self.toolbarColors.count
        let numThick  = Self.toolbarThicknesses.count
        let numIcons  = 3   // annotate, clear, exit

        let colorsWidth = CGFloat(numColors) * colorDiameter + CGFloat(numColors - 1) * colorSpacing
        let thickWidth  = CGFloat(numThick) * thicknessButtonW + CGFloat(numThick - 1) * 6
        let iconsWidth  = CGFloat(numIcons) * iconButtonSize + CGFloat(numIcons - 1) * 6

        let toolbarWidth = padding * 2 + colorsWidth + groupGap + 1 + groupGap + thickWidth + groupGap + 1 + groupGap + iconsWidth
        let toolbarX = bounds.midX - toolbarWidth / 2
        let toolbarY = bounds.height - toolbarHeight - 28

        // Background pill
        let bgRect = NSRect(x: toolbarX, y: toolbarY, width: toolbarWidth, height: toolbarHeight)
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 16, yRadius: 16)
        NSColor(calibratedWhite: 0.10, alpha: 0.92).setFill()
        bgPath.fill()
        NSColor.white.withAlphaComponent(0.08).setStroke()
        bgPath.lineWidth = 1
        bgPath.stroke()

        var cursorX = toolbarX + padding

        // 1. Color pills
        let colorY = toolbarY + (toolbarHeight - colorDiameter) / 2
        for color in Self.toolbarColors {
            let rect = NSRect(x: cursorX, y: colorY, width: colorDiameter, height: colorDiameter)
            let isActive = color.isClose(to: annotationColor)
            drawColorPill(rect: rect, color: color, isActive: isActive)
            toolbarHits.append(ToolbarHit(rect: rect, action: .color(color)))
            cursorX += colorDiameter + colorSpacing
        }

        // Divider
        cursorX += groupGap - colorSpacing
        drawDivider(x: cursorX, toolbarY: toolbarY, height: toolbarHeight)
        cursorX += 1 + groupGap

        // 2. Thickness pills (visualized as dots with increasing diameter)
        let thickY = toolbarY + (toolbarHeight - thicknessButtonH) / 2
        for w in Self.toolbarThicknesses {
            let rect = NSRect(x: cursorX, y: thickY, width: thicknessButtonW, height: thicknessButtonH)
            let isActive = abs(penWidth - w) < 0.1
            drawThicknessButton(rect: rect, thickness: w, isActive: isActive)
            toolbarHits.append(ToolbarHit(rect: rect, action: .thickness(w)))
            cursorX += thicknessButtonW + 6
        }

        // Divider
        cursorX += groupGap - 6
        drawDivider(x: cursorX, toolbarY: toolbarY, height: toolbarHeight)
        cursorX += 1 + groupGap

        // 3. Action icons
        let iconY = toolbarY + (toolbarHeight - iconButtonSize) / 2
        drawIconButton(
            rect: NSRect(x: cursorX, y: iconY, width: iconButtonSize, height: iconButtonSize),
            symbol: isAnnotating ? "pencil.tip" : "pencil",
            isActive: isAnnotating,
            action: .toggleAnnotation
        )
        cursorX += iconButtonSize + 6
        drawIconButton(
            rect: NSRect(x: cursorX, y: iconY, width: iconButtonSize, height: iconButtonSize),
            symbol: "trash",
            isActive: false,
            action: .clear
        )
        cursorX += iconButtonSize + 6
        drawIconButton(
            rect: NSRect(x: cursorX, y: iconY, width: iconButtonSize, height: iconButtonSize),
            symbol: "xmark",
            isActive: false,
            action: .exit
        )

        // Bottom hint
        let hintFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: hintFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.45)
        ]
        let hint = NSAttributedString(
            string: "Scroll to zoom · drag to pan · arrows pan · A draw · 0 reset",
            attributes: hintAttrs
        )
        let hintSize = hint.size()
        hint.draw(at: NSPoint(x: bounds.midX - hintSize.width / 2, y: toolbarY - 18))
    }

    private func drawColorPill(rect: NSRect, color: NSColor, isActive: Bool) {
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: isActive ? 0 : 2, dy: isActive ? 0 : 2))
        color.setFill()
        path.fill()

        if isActive {
            // White outer ring + inner border
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 2
            path.stroke()
        } else {
            // Subtle dark inner border so light pills (yellow/white) read on the dark bg
            NSColor.black.withAlphaComponent(0.20).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    private func drawThicknessButton(rect: NSRect, thickness: CGFloat, isActive: Bool) {
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        if isActive {
            NSColor.white.withAlphaComponent(0.15).setFill()
            bgPath.fill()
        }
        // Draw a horizontal line of `thickness` to visualize
        let lineY = rect.midY
        let lineRect = NSRect(
            x: rect.midX - 9,
            y: lineY - thickness / 2,
            width: 18,
            height: thickness
        )
        let linePath = NSBezierPath(roundedRect: lineRect, xRadius: thickness / 2, yRadius: thickness / 2)
        (isActive ? annotationColor : NSColor.white.withAlphaComponent(0.78)).setFill()
        linePath.fill()
    }

    private func drawIconButton(rect: NSRect, symbol: String, isActive: Bool, action: ToolbarAction) {
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        if isActive {
            annotationColor.withAlphaComponent(0.25).setFill()
            bgPath.fill()
        }
        let tint: NSColor = isActive ? annotationColor : NSColor.white.withAlphaComponent(0.85)
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(
                x: rect.midX - img.size.width / 2,
                y: rect.midY - img.size.height / 2,
                width: img.size.width,
                height: img.size.height
            ))
        }
        toolbarHits.append(ToolbarHit(rect: rect, action: action))
    }

    private func drawDivider(x: CGFloat, toolbarY: CGFloat, height: CGFloat) {
        let line = NSRect(x: x, y: toolbarY + 12, width: 1, height: height - 24)
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: line).fill()
    }
}

private extension NSColor {
    func isClose(to other: NSColor, epsilon: CGFloat = 0.02) -> Bool {
        guard
            let a = usingColorSpace(.deviceRGB),
            let b = other.usingColorSpace(.deviceRGB)
        else { return self == other }
        return abs(a.redComponent   - b.redComponent)   < epsilon
            && abs(a.greenComponent - b.greenComponent) < epsilon
            && abs(a.blueComponent  - b.blueComponent)  < epsilon
    }
}

// MARK: - Break Timer View

final class BreakTimerView: NSView {
    var totalSeconds: Int = 300
    var remainingSeconds: Int = 300
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Escape
    }

    override func mouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        // Full black background
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 140

        // Draw progress ring
        let progress = CGFloat(remainingSeconds) / CGFloat(max(totalSeconds, 1))

        // Background ring
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
        context.setLineWidth(6)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        context.strokePath()

        // Progress ring
        let startAngle: CGFloat = .pi / 2
        let endAngle = startAngle + (.pi * 2 * progress)

        context.setStrokeColor(NSColor.systemOrange.cgColor)
        context.setLineWidth(6)
        context.setLineCap(.round)
        context.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        context.strokePath()
        context.restoreGState()

        // Draw time text
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        let timeText = String(format: "%d:%02d", minutes, seconds)

        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 72, weight: .ultraLight),
            .foregroundColor: NSColor.white
        ]
        let timeStr = NSAttributedString(string: timeText, attributes: timeAttrs)
        let timeSize = timeStr.size()
        timeStr.draw(at: NSPoint(x: center.x - timeSize.width / 2, y: center.y - timeSize.height / 2))

        // Draw subtitle
        let subText = "Press Esc or click to dismiss"
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.4)
        ]
        let subStr = NSAttributedString(string: subText, attributes: subAttrs)
        let subSize = subStr.size()
        subStr.draw(at: NSPoint(x: center.x - subSize.width / 2, y: center.y - radius - 50))
    }
}

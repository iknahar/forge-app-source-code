import SwiftUI
import AppKit
import Vision

/// Text Extractor — OCR using Apple Vision framework.
/// Activated with ⌃⌥T. Select a screen region, extracts text via
/// VNRecognizeTextRequest, copies to clipboard.
final class TextExtractorModule: ForgeModule, ObservableObject {
    let id = "textExtractor"
    let name = "Text Extractor"
    let description = "Copy text from anywhere via OCR"
    let iconName = "text.viewfinder"
    let category: ModuleCategory = .screen
    var isEnabled: Bool = true

    // MARK: - State

    @Published var isActive: Bool = false
    @Published var recognizedText: String = ""
    @Published var recognitionLanguages: [String] = ["en-US"]
    @Published var lastExtractionCount: Int = 0

    private var overlayWindow: NSWindow?

    // MARK: - Lifecycle

    func activate() {}
    func deactivate() { stopExtracting() }

    // MARK: - Start Extraction

    func startExtracting() {
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
        window.backgroundColor = NSColor.black.withAlphaComponent(0.2)
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let selector = RegionSelectorView(frame: screen.frame)
        selector.onRegionSelected = { [weak self] rect in
            self?.extractText(from: rect)
        }
        selector.onCancel = { [weak self] in
            self?.stopExtracting()
        }

        window.contentView = selector
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(selector)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()

        overlayWindow = window
    }

    func stopExtracting() {
        isActive = false
        NSCursor.pop()
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }

    // MARK: - OCR

    private func extractText(from rect: CGRect) {
        guard let screen = NSScreen.main else {
            stopExtracting()
            return
        }

        // Convert from view coordinates to screen coordinates
        let screenRect = CGRect(
            x: rect.origin.x,
            y: screen.frame.height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )

        // Capture screen region (excluding our overlay)
        guard let image = CGWindowListCreateImage(
            screenRect,
            .optionOnScreenBelowWindow,
            CGWindowID(overlayWindow?.windowNumber ?? 0),
            [.bestResolution]
        ) else {
            stopExtracting()
            return
        }

        // Run OCR with Vision
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let results = request.results as? [VNRecognizedTextObservation] else {
                self?.handleOCRResult("", error: error)
                return
            }

            // Sort by vertical position (top to bottom), then horizontal
            let sorted = results.sorted { a, b in
                let aY = 1 - a.boundingBox.midY // Flip Y
                let bY = 1 - b.boundingBox.midY
                if abs(aY - bY) < 0.02 { // Same line
                    return a.boundingBox.minX < b.boundingBox.minX
                }
                return aY < bY
            }

            var lines: [String] = []
            var currentLineY: CGFloat = -1
            var currentLine = ""

            for observation in sorted {
                guard let text = observation.topCandidates(1).first?.string else { continue }
                let y = 1 - observation.boundingBox.midY

                if currentLineY < 0 || abs(y - currentLineY) > 0.02 {
                    // New line
                    if !currentLine.isEmpty {
                        lines.append(currentLine)
                    }
                    currentLine = text
                    currentLineY = y
                } else {
                    // Same line, append with space
                    currentLine += " " + text
                }
            }
            if !currentLine.isEmpty {
                lines.append(currentLine)
            }

            let fullText = lines.joined(separator: "\n")
            self?.handleOCRResult(fullText, error: nil)
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.handleOCRResult("", error: error)
                }
            }
        }
    }

    private func handleOCRResult(_ text: String, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.stopExtracting()

            if let error = error {
                print("[Forge TextExtractor] OCR error: \(error.localizedDescription)")
                return
            }

            guard !text.isEmpty else {
                print("[Forge TextExtractor] No text found in selection")
                return
            }

            self?.recognizedText = text
            self?.lastExtractionCount = text.count

            // Copy to clipboard
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

            print("[Forge TextExtractor] Extracted \(text.count) characters")
        }
    }

    // MARK: - Commands

}

// MARK: - Region Selector View

final class RegionSelectorView: NSView {
    var onRegionSelected: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint = .zero
    private var isDragging = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
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

        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )

        if rect.width > 10 && rect.height > 10 {
            onRegionSelected?(rect)
        } else {
            onCancel?()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        // Dim background
        context.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        context.fill(bounds)

        if isDragging, let start = startPoint {
            let rect = CGRect(
                x: min(start.x, currentPoint.x),
                y: min(start.y, currentPoint.y),
                width: abs(currentPoint.x - start.x),
                height: abs(currentPoint.y - start.y)
            )

            // Clear selected region
            context.clear(rect)

            // Border
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(2)
            context.stroke(rect)

            // Dimension label
            let text = "\(Int(rect.width))×\(Int(rect.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let size = str.size()
            let labelRect = NSRect(
                x: rect.midX - size.width / 2 - 6,
                y: rect.minY - size.height - 10,
                width: size.width + 12,
                height: size.height + 6
            )
            let bg = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
            NSColor(calibratedWhite: 0.1, alpha: 0.9).setFill()
            bg.fill()
            str.draw(at: NSPoint(x: labelRect.minX + 6, y: labelRect.minY + 3))
        }

        // Instructions
        let instruction = isDragging ? "Release to extract text" : "Click and drag to select a region · Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8)
        ]
        let str = NSAttributedString(string: instruction, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.height - 60))
    }
}

import SwiftUI
import AppKit

/// FancyZones — custom window snap zone layouts.
/// Activated with ⌃⌥F to open the zone editor. Hold Shift during
/// window drag to show zone overlay and snap windows into zones.
final class FancyZonesModule: ForgeModule, ObservableObject {
    let id = "fancyZones"
    let name = "FancyZones"
    let description = "Custom window snap zones"
    let iconName = "rectangle.split.3x3"
    let category: ModuleCategory = .windows
    var isEnabled: Bool = true

    // MARK: - State

    @Published var isEditorActive: Bool = false
    @Published var isOverlayShowing: Bool = false
    @Published var activeLayoutIndex: Int = 0
    @Published var layouts: [ZoneLayoutConfig] = ZoneLayoutConfig.defaults

    private var editorWindow: NSWindow?
    private var overlayWindow: NSWindow?
    private var dragMonitor: Any?

    // MARK: - Lifecycle

    func activate() {
        loadLayouts()
        // NOTE: drag monitor is intentionally NOT wired up — the
        // previous implementation triggered the overlay on ANY Shift
        // press (typing capital letters, ⇧⌘N, etc.) and the snap-on-
        // drop logic isn't built yet, so the overlay appeared
        // constantly without doing anything. The editor (opened via
        // ⌃⌥F or the Tools-tab button) is still the user-facing way
        // to manage layouts. Re-enable `setupDragMonitor()` once the
        // actual window-snapping behavior is implemented and the
        // trigger correctly disambiguates "Shift typed" from
        // "Shift held during a window drag" via the Accessibility
        // API (kAXMovedNotification, etc.).
        // setupDragMonitor()
    }

    func deactivate() {
        closeEditor()
        hideOverlay()
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
    }

    // MARK: - Drag Monitor (currently disabled — see activate() comment)

    private func setupDragMonitor() {
        // Original implementation — kept here for when snap-on-drop is
        // implemented properly. The naive shift-only check below is the
        // bug that was firing the overlay constantly:
        //
        //   - User presses ⇧ to type a capital letter → overlay opens
        //   - User releases ⇧                          → overlay closes
        //   - Every ⇧⌘N / ⇧⌥drag combo also triggers
        //
        // A correct trigger needs to:
        //   1. Detect an active window drag (left mouse down + move)
        //      via the Accessibility API or CGEventTap.
        //   2. Only THEN start watching for Shift to gate the overlay.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self = self, self.isEnabled else { return }

            let shiftPressed = event.modifierFlags.contains(.shift)
            if shiftPressed && !self.isOverlayShowing {
                DispatchQueue.main.async {
                    self.showOverlay()
                }
            } else if !shiftPressed && self.isOverlayShowing {
                DispatchQueue.main.async {
                    self.hideOverlay()
                }
            }
        }
    }

    // MARK: - Zone Overlay

    func showOverlay() {
        guard !isOverlayShowing, let screen = NSScreen.main else { return }
        isOverlayShowing = true

        let currentLayout = layouts[safe: activeLayoutIndex] ?? layouts[0]

        let window = NSWindow(
            contentRect: screen.visibleFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = ZoneOverlayView(frame: screen.visibleFrame)
        view.zones = currentLayout.zones
        view.screenFrame = screen.visibleFrame

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        overlayWindow = window
    }

    func hideOverlay() {
        isOverlayShowing = false
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }

    // MARK: - Zone Editor

    func openEditor() {
        guard !isEditorActive, let screen = NSScreen.main else { return }
        isEditorActive = true

        let editorSize = NSSize(width: 800, height: 560)
        let origin = NSPoint(
            x: screen.visibleFrame.midX - editorSize.width / 2,
            y: screen.visibleFrame.midY - editorSize.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: editorSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FancyZones — Zone Editor"
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)

        let editorView = ZoneEditorView(frame: NSRect(origin: .zero, size: editorSize))
        editorView.layout = layouts[safe: activeLayoutIndex] ?? layouts[0]
        editorView.onSave = { [weak self] layout in
            self?.saveLayout(layout)
            self?.closeEditor()
        }
        editorView.onCancel = { [weak self] in
            self?.closeEditor()
        }

        window.contentView = editorView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        editorWindow = window
    }

    func closeEditor() {
        isEditorActive = false
        editorWindow?.orderOut(nil)
        editorWindow = nil
    }

    // MARK: - Snap Window to Zone

    func snapFocusedWindow(to zoneIndex: Int) {
        guard let screen = NSScreen.main else { return }
        let currentLayout = layouts[safe: activeLayoutIndex] ?? layouts[0]
        guard let zone = currentLayout.zones[safe: zoneIndex] else { return }

        let screenFrame = screen.visibleFrame
        let targetFrame = CGRect(
            x: screenFrame.origin.x + zone.rect.origin.x * screenFrame.width,
            y: screenFrame.origin.y + zone.rect.origin.y * screenFrame.height,
            width: zone.rect.width * screenFrame.width,
            height: zone.rect.height * screenFrame.height
        )

        // Use Accessibility API to move focused window
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else { return }
        let appRef = AXUIElementCreateApplication(focusedApp.processIdentifier)

        var focusedWindow: AnyObject?
        AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard let windowRef = focusedWindow else { return }
        let axWindow = windowRef as! AXUIElement

        var position = CGPoint(x: targetFrame.origin.x, y: screen.frame.height - targetFrame.maxY)
        var size = CGSize(width: targetFrame.width, height: targetFrame.height)

        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    func cycleLayout() {
        activeLayoutIndex = (activeLayoutIndex + 1) % layouts.count
        saveLayouts()
    }

    // MARK: - Persistence

    private var layoutsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fancyzones_layouts.json")
    }

    private func loadLayouts() {
        guard let data = try? Data(contentsOf: layoutsURL),
              let saved = try? JSONDecoder().decode([ZoneLayoutConfig].self, from: data) else {
            layouts = ZoneLayoutConfig.defaults
            return
        }
        layouts = saved
    }

    private func saveLayouts() {
        if let data = try? JSONEncoder().encode(layouts) {
            try? data.write(to: layoutsURL)
        }
    }

    private func saveLayout(_ layout: ZoneLayoutConfig) {
        if activeLayoutIndex < layouts.count {
            layouts[activeLayoutIndex] = layout
        } else {
            layouts.append(layout)
        }
        saveLayouts()
    }

    // MARK: - Commands

    func commands() -> [ForgeCommand] {
        [
            ForgeCommand(
                id: "fancyzones.editor", title: "FancyZones — Zone Editor", subtitle: "Design custom window layouts",
                iconName: "rectangle.split.3x3", moduleId: id,
                action: { [weak self] in self?.openEditor() },
                keywords: ["zones", "layout", "editor", "fancy", "window", "snap", "grid"]
            ),
            ForgeCommand(
                id: "fancyzones.cycle", title: "FancyZones — Cycle Layout", subtitle: "Switch to next zone layout",
                iconName: "arrow.triangle.2.circlepath", moduleId: id,
                action: { [weak self] in self?.cycleLayout() },
                keywords: ["zones", "cycle", "layout", "switch", "next"]
            ),
            ForgeCommand(
                id: "fancyzones.overlay", title: "FancyZones — Show Zones", subtitle: "Display current zone overlay",
                iconName: "rectangle.dashed", moduleId: id,
                action: { [weak self] in self?.showOverlay() },
                keywords: ["zones", "overlay", "show", "display"]
            ),
        ]
    }
}

// MARK: - Zone Data Models

struct ZoneRect: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var origin: CGPoint {
        CGPoint(x: x, y: y)
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

struct ZoneDefinition: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var rect: ZoneRect

    init(name: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.id = UUID().uuidString
        self.name = name
        self.rect = ZoneRect(x: x, y: y, width: width, height: height)
    }
}

struct ZoneLayoutConfig: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var zones: [ZoneDefinition]

    static let defaults: [ZoneLayoutConfig] = [
        // Two columns 50/50
        ZoneLayoutConfig(
            id: "twoColumn",
            name: "Two Columns",
            zones: [
                ZoneDefinition(name: "Left", x: 0, y: 0, width: 0.5, height: 1.0),
                ZoneDefinition(name: "Right", x: 0.5, y: 0, width: 0.5, height: 1.0),
            ]
        ),
        // Three columns
        ZoneLayoutConfig(
            id: "threeColumn",
            name: "Three Columns",
            zones: [
                ZoneDefinition(name: "Left", x: 0, y: 0, width: 0.333, height: 1.0),
                ZoneDefinition(name: "Center", x: 0.333, y: 0, width: 0.334, height: 1.0),
                ZoneDefinition(name: "Right", x: 0.667, y: 0, width: 0.333, height: 1.0),
            ]
        ),
        // Dev layout: 70/30 with stacked right
        ZoneLayoutConfig(
            id: "devLayout",
            name: "Dev + Sidebar",
            zones: [
                ZoneDefinition(name: "Editor", x: 0, y: 0, width: 0.65, height: 1.0),
                ZoneDefinition(name: "Terminal", x: 0.65, y: 0, width: 0.35, height: 0.5),
                ZoneDefinition(name: "Browser", x: 0.65, y: 0.5, width: 0.35, height: 0.5),
            ]
        ),
        // Four quadrants
        ZoneLayoutConfig(
            id: "fourQuadrant",
            name: "Four Quadrants",
            zones: [
                ZoneDefinition(name: "Top Left", x: 0, y: 0, width: 0.5, height: 0.5),
                ZoneDefinition(name: "Top Right", x: 0.5, y: 0, width: 0.5, height: 0.5),
                ZoneDefinition(name: "Bottom Left", x: 0, y: 0.5, width: 0.5, height: 0.5),
                ZoneDefinition(name: "Bottom Right", x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            ]
        ),
        // Centered focus
        ZoneLayoutConfig(
            id: "centeredFocus",
            name: "Centered Focus",
            zones: [
                ZoneDefinition(name: "Left Sidebar", x: 0, y: 0, width: 0.15, height: 1.0),
                ZoneDefinition(name: "Main", x: 0.15, y: 0, width: 0.7, height: 1.0),
                ZoneDefinition(name: "Right Sidebar", x: 0.85, y: 0, width: 0.15, height: 1.0),
            ]
        ),
    ]
}

// MARK: - Zone Overlay View

final class ZoneOverlayView: NSView {
    var zones: [ZoneDefinition] = []
    var screenFrame: CGRect = .zero
    var highlightedZone: Int? = nil

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        for (index, zone) in zones.enumerated() {
            let rect = CGRect(
                x: zone.rect.origin.x * bounds.width,
                y: zone.rect.origin.y * bounds.height,
                width: zone.rect.width * bounds.width,
                height: zone.rect.height * bounds.height
            ).insetBy(dx: 4, dy: 4)

            let isHighlighted = highlightedZone == index

            // Zone fill
            let fillColor = isHighlighted
                ? NSColor.systemBlue.withAlphaComponent(0.25)
                : NSColor.systemBlue.withAlphaComponent(0.08)
            context.setFillColor(fillColor.cgColor)

            let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            context.addPath(path)
            context.fillPath()

            // Zone border
            let borderColor = isHighlighted
                ? NSColor.systemBlue.withAlphaComponent(0.8)
                : NSColor.systemBlue.withAlphaComponent(0.35)
            context.setStrokeColor(borderColor.cgColor)
            context.setLineWidth(isHighlighted ? 3 : 2)
            context.addPath(path)
            context.strokePath()

            // Zone label
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(isHighlighted ? 0.9 : 0.5)
            ]
            let label = NSAttributedString(string: zone.name, attributes: attrs)
            let labelSize = label.size()
            label.draw(at: NSPoint(
                x: rect.midX - labelSize.width / 2,
                y: rect.midY - labelSize.height / 2
            ))

            // Zone number badge
            let numAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.6)
            ]
            let numLabel = NSAttributedString(string: "\(index + 1)", attributes: numAttrs)
            let numSize = numLabel.size()
            let badgeRect = NSRect(x: rect.minX + 10, y: rect.maxY - numSize.height - 14, width: numSize.width + 12, height: numSize.height + 6)
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
            NSColor(calibratedWhite: 0.2, alpha: 0.7).setFill()
            badgePath.fill()
            numLabel.draw(at: NSPoint(x: badgeRect.minX + 6, y: badgeRect.minY + 3))
        }
    }
}

// MARK: - Zone Editor View

final class ZoneEditorView: NSView {
    var layout: ZoneLayoutConfig = ZoneLayoutConfig.defaults[0]
    var onSave: ((ZoneLayoutConfig) -> Void)?
    var onCancel: (() -> Void)?

    private var selectedZone: Int? = nil
    private var isDragging: Bool = false
    private var dragStart: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?() // Escape
        case 36: onSave?(layout) // Enter — save
        default: break
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let canvasRect = editorCanvasRect()

        // Check if clicking on a zone
        for (index, zone) in layout.zones.enumerated() {
            let zoneRect = CGRect(
                x: canvasRect.origin.x + zone.rect.origin.x * canvasRect.width,
                y: canvasRect.origin.y + zone.rect.origin.y * canvasRect.height,
                width: zone.rect.width * canvasRect.width,
                height: zone.rect.height * canvasRect.height
            )
            if zoneRect.contains(point) {
                selectedZone = index
                isDragging = true
                dragStart = point
                needsDisplay = true
                return
            }
        }
        selectedZone = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let selected = selectedZone else { return }
        let point = convert(event.locationInWindow, from: nil)
        let canvas = editorCanvasRect()

        let dx = (point.x - dragStart.x) / canvas.width
        let dy = (point.y - dragStart.y) / canvas.height

        layout.zones[selected].rect.x += dx
        layout.zones[selected].rect.y += dy

        // Clamp to canvas
        layout.zones[selected].rect.x = max(0, min(1 - layout.zones[selected].rect.width, layout.zones[selected].rect.x))
        layout.zones[selected].rect.y = max(0, min(1 - layout.zones[selected].rect.height, layout.zones[selected].rect.y))

        dragStart = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    private func editorCanvasRect() -> CGRect {
        let padding: CGFloat = 40
        let headerHeight: CGFloat = 60
        let footerHeight: CGFloat = 60
        return CGRect(
            x: padding,
            y: footerHeight,
            width: bounds.width - padding * 2,
            height: bounds.height - headerHeight - footerHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        // Background
        context.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor)
        context.fill(bounds)

        // Header
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let header = NSAttributedString(string: "Zone Editor — \(layout.name)", attributes: headerAttrs)
        header.draw(at: NSPoint(x: 40, y: bounds.height - 45))

        // Canvas background
        let canvas = editorCanvasRect()
        context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor)
        let canvasPath = CGPath(roundedRect: canvas, cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.addPath(canvasPath)
        context.fillPath()

        // Draw grid lines
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.05).cgColor)
        context.setLineWidth(0.5)
        for i in 1..<12 {
            let x = canvas.origin.x + canvas.width * CGFloat(i) / 12
            context.move(to: CGPoint(x: x, y: canvas.minY))
            context.addLine(to: CGPoint(x: x, y: canvas.maxY))
        }
        for i in 1..<8 {
            let y = canvas.origin.y + canvas.height * CGFloat(i) / 8
            context.move(to: CGPoint(x: canvas.minX, y: y))
            context.addLine(to: CGPoint(x: canvas.maxX, y: y))
        }
        context.strokePath()

        // Draw zones
        for (index, zone) in layout.zones.enumerated() {
            let rect = CGRect(
                x: canvas.origin.x + zone.rect.origin.x * canvas.width,
                y: canvas.origin.y + zone.rect.origin.y * canvas.height,
                width: zone.rect.width * canvas.width,
                height: zone.rect.height * canvas.height
            ).insetBy(dx: 3, dy: 3)

            let isSelected = selectedZone == index

            // Fill
            let fillColor = isSelected
                ? NSColor.systemBlue.withAlphaComponent(0.3)
                : NSColor.systemBlue.withAlphaComponent(0.12)
            context.setFillColor(fillColor.cgColor)
            let zonePath = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            context.addPath(zonePath)
            context.fillPath()

            // Border
            let borderColor = isSelected
                ? NSColor.systemBlue.withAlphaComponent(0.9)
                : NSColor.systemBlue.withAlphaComponent(0.4)
            context.setStrokeColor(borderColor.cgColor)
            context.setLineWidth(isSelected ? 2.5 : 1.5)
            context.addPath(zonePath)
            context.strokePath()

            // Label
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(isSelected ? 0.9 : 0.6)
            ]
            let label = NSAttributedString(string: zone.name, attributes: labelAttrs)
            let labelSize = label.size()
            label.draw(at: NSPoint(x: rect.midX - labelSize.width / 2, y: rect.midY - labelSize.height / 2))
        }

        // Footer instructions
        let footerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.4)
        ]
        let footer = NSAttributedString(string: "Drag zones to reposition · Enter to save · Esc to cancel", attributes: footerAttrs)
        let footerSize = footer.size()
        footer.draw(at: NSPoint(x: bounds.midX - footerSize.width / 2, y: 20))
    }
}

import SwiftUI
import AppKit

/// Color Picker — system-wide pixel color sampling.
/// Activated with ⌃⌥C. Shows magnified loupe around cursor,
/// click to pick, auto-copies to clipboard in chosen format.
final class ColorPickerModule: ForgeModule, ObservableObject {
    let id = "colorPicker"
    let name = "Color Picker"
    let description = "Pick colors from anywhere on screen"
    let iconName = "eyedropper"
    let category: ModuleCategory = .screen
    var isEnabled: Bool = true

    // MARK: - State

    @Published var pickedColors: [PickedColor] = []
    @Published var savedPalettes: [ColorPalette] = []
    @Published var outputFormat: ColorFormat = .hex
    @Published var isActive: Bool = false

    private var overlayWindow: NSWindow?
    private var loupeView: ColorLoupeView?
    private var eventMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var rightClickMonitor: Any?
    private var scrollMonitor: Any?

    // MARK: - Lifecycle

    func activate() {
        loadHistory()
        print("[Forge ColorPicker] Activated")
    }

    func deactivate() {
        stopPicking()
    }

    // MARK: - Start Picking

    func startPicking() {
        guard !isActive else { return }
        isActive = true

        // Create fullscreen transparent overlay
        guard let screen = NSScreen.main else { return }

        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let loupe = ColorLoupeView(frame: screen.frame)
        loupe.onPick = { [weak self] color, point in
            self?.handleColorPicked(color: color, at: point)
        }
        loupe.onCancel = { [weak self] in
            self?.stopPicking()
        }
        loupe.outputFormat = outputFormat

        window.contentView = loupe
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(loupe)
        NSApp.activate(ignoringOtherApps: true)

        // Set crosshair cursor
        NSCursor.crosshair.push()

        overlayWindow = window
        loupeView = loupe

        // Track mouse movement
        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.loupeView?.updatePosition(event.locationInWindow)
            return event
        }

        // Track clicks
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.loupeView?.pickAtCurrentPosition()
            return nil // Consume the event
        }

        // Track right-click to cancel
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] _ in
            self?.stopPicking()
            return nil
        }

        // Track scroll to zoom
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.loupeView?.adjustZoom(delta: event.scrollingDeltaY)
            return nil
        }
    }

    func stopPicking() {
        isActive = false
        NSCursor.pop()

        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMoveMonitor = nil
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }

        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        loupeView = nil
    }

    // MARK: - Color Handling

    private func handleColorPicked(color: NSColor, at point: NSPoint) {
        let picked = PickedColor(
            color: color,
            point: point,
            timestamp: Date()
        )

        pickedColors.insert(picked, at: 0)
        if pickedColors.count > 24 { pickedColors.removeLast() }

        // Copy to clipboard
        let formatted = formatColor(color, format: outputFormat)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formatted, forType: .string)
        saveHistory()

        // Give the user a clear "it copied" beat: flash the loupe's info
        // bar to a green "✓ Copied <value>" confirmation, play the system
        // copy sound, then tear the overlay down after a short hold. The
        // loupe freezes itself while the banner is up, so stray
        // moves/clicks during the hold are ignored.
        loupeView?.flashCopied(formatted)
        NSSound(named: NSSound.Name("Pop"))?.play()
        print("[Forge ColorPicker] Picked: \(formatted)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.stopPicking()
        }
    }

    // MARK: - Color Formatting

    func formatColor(_ color: NSColor, format: ColorFormat) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = rgb.redComponent
        let g = rgb.greenComponent
        let b = rgb.blueComponent
        let a = rgb.alphaComponent

        switch format {
        case .hex:
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))

        case .rgb:
            return String(format: "rgb(%d, %d, %d)", Int(r * 255), Int(g * 255), Int(b * 255))

        case .rgba:
            return String(format: "rgba(%d, %d, %d, %.2f)", Int(r * 255), Int(g * 255), Int(b * 255), a)

        case .hsl:
            let (h, s, l) = rgbToHSL(r: r, g: g, b: b)
            return String(format: "hsl(%d, %d%%, %d%%)", Int(h * 360), Int(s * 100), Int(l * 100))

        case .hsb:
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &br, alpha: nil)
            return String(format: "hsb(%d, %d%%, %d%%)", Int(h * 360), Int(s * 100), Int(br * 100))

        case .swiftUI:
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", r, g, b)

        case .uiColor:
            return String(format: "UIColor(red: %.3f, green: %.3f, blue: %.3f, alpha: 1.0)", r, g, b)

        case .tailwind:
            return nearestTailwindColor(r: r, g: g, b: b)

        case .cmyk:
            let k = 1 - max(r, g, b)
            if k == 1 { return "cmyk(0%, 0%, 0%, 100%)" }
            let c = (1 - r - k) / (1 - k)
            let m = (1 - g - k) / (1 - k)
            let y = (1 - b - k) / (1 - k)
            return String(format: "cmyk(%d%%, %d%%, %d%%, %d%%)", Int(c * 100), Int(m * 100), Int(y * 100), Int(k * 100))

        case .p3:
            if let p3 = color.usingColorSpace(.displayP3) {
                return String(format: "color(display-p3 %.3f %.3f %.3f)", p3.redComponent, p3.greenComponent, p3.blueComponent)
            }
            return formatColor(color, format: .hex)
        }
    }

    private func rgbToHSL(r: CGFloat, g: CGFloat, b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2

        if maxC == minC { return (0, 0, l) }

        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)

        var h: CGFloat
        switch maxC {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6

        return (h, s, l)
    }

    private func nearestTailwindColor(r: CGFloat, g: CGFloat, b: CGFloat) -> String {
        // Simplified Tailwind color matcher — returns nearest named color
        let hex = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        // For now, return the hex with a comment
        return "\(hex) /* tailwind: nearest match */"
    }

    // MARK: - Palette Management

    func createPalette(name: String) {
        let palette = ColorPalette(
            id: UUID().uuidString,
            name: name,
            colors: pickedColors.prefix(10).map { $0 }
        )
        savedPalettes.append(palette)
        savePalettes()
    }

    // MARK: - Persistence

    private var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("color_history.json")
    }

    private func loadHistory() {
        // Load from JSON
    }

    private func saveHistory() {
        // Save to JSON
    }

    private func savePalettes() {
        // Save palettes to JSON
    }

    // MARK: - Module Protocol

}

// MARK: - Supporting Types

struct PickedColor: Identifiable, Codable {
    let id: String
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
    let x: CGFloat
    let y: CGFloat
    let timestamp: Date

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    init(color: NSColor, point: NSPoint, timestamp: Date) {
        self.id = UUID().uuidString
        let rgb = color.usingColorSpace(.sRGB) ?? color
        self.red = rgb.redComponent
        self.green = rgb.greenComponent
        self.blue = rgb.blueComponent
        self.alpha = rgb.alphaComponent
        self.x = point.x
        self.y = point.y
        self.timestamp = timestamp
    }
}

struct ColorPalette: Identifiable, Codable {
    let id: String
    let name: String
    let colors: [PickedColor]
}

enum ColorFormat: String, CaseIterable, Identifiable, Codable {
    case hex = "HEX"
    case rgb = "RGB"
    case rgba = "RGBA"
    case hsl = "HSL"
    case hsb = "HSB"
    case cmyk = "CMYK"
    case p3 = "Display P3"
    case swiftUI = "SwiftUI"
    case uiColor = "UIColor"
    case tailwind = "Tailwind"

    var id: String { rawValue }
}

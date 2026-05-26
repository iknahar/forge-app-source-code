import SwiftUI
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - SkyLight private API (window level for non-owned windows)
//
// AXRaise only raises a window above siblings in the SAME app — that's
// why our previous pin-on-top implementation appeared to "pin" but
// other apps still floated above. The standard fix used by every
// always-on-top utility on macOS (Magnet, Rectangle Pro, BetterSnapTool,
// Microsoft PowerToys port, etc.) is the private SkyLight call
// `CGSSetWindowLevel`, which can elevate any window — including
// third-party ones — to a higher window level. It has been stable
// across every macOS release since 10.6 and is the only public-ish
// way to make this work.

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSSetWindowLevel")
private func CGSSetWindowLevel(_ cid: Int32, _ wid: CGWindowID, _ level: Int32) -> Int32

/// Pin Window module — keeps the focused window always-on-top with a
/// thin red border, toggled by a global shortcut. FancyZones (zone
/// tiling) lives in its own module now, so this one is scoped purely
/// to the pin-window behaviour and reads as such in the Tools list.
final class WindowManagerModule: ForgeModule, ObservableObject {
    let id = "windowManager"
    let name = "Pin Window"
    let description = "Keep a window always on top with a single shortcut"
    let iconName = "rectangle.split.3x1"
    let category: ModuleCategory = .windows
    var isEnabled: Bool = true

    // MARK: - State

    @Published var activeLayout: ZoneLayout = .twoColumn
    @Published var savedWorkspaces: [Workspace] = []

    /// Currently pinned target. Nil = nothing pinned. Stays alive even
    /// when the user minimises the pinned window — the border just
    /// hides until the window comes back into view.
    @Published private(set) var pinnedTarget: PinnedTarget?

    /// Border overlay shown around the pinned window. Tracks the
    /// window's frame on every poll tick.
    private var borderPanel: PinnedWindowBorderPanel?

    /// 60ms poll keeps the overlay glued to the window during drags /
    /// resizes and continually calls `AXRaise` so the window stays
    /// above other apps. AX has no "always on top" attribute for
    /// third-party windows on macOS, so polling raise is the
    /// industry-standard approach (used by Magnet, Rectangle Pro, etc.).
    private var pinTimer: Timer?

    struct PinnedTarget {
        let pid: pid_t
        let windowElement: AXUIElement
        let windowID: CGWindowID
        let appName: String
    }

    /// Window level we elevate pinned windows to. `kCGFloatingWindowLevel`
    /// (3) sits above all normal app windows but below status-bar items
    /// and Forge's own overlays. Picked deliberately so a system alert
    /// can still display on top if one fires.
    private let pinnedLevel = Int32(CGWindowLevelForKey(.floatingWindow))
    private let normalLevel = Int32(CGWindowLevelForKey(.normalWindow))

    // MARK: - Lifecycle

    func activate() {
        loadWorkspaces()
        print("[Forge WindowManager] Activated with layout: \(activeLayout.name)")
    }

    func deactivate() {
        unpinWindow(playSound: false)
    }

    // MARK: - Zone Snapping

    /// Snap the frontmost window to a specific zone
    func snapFrontWindow(to position: SnapPosition) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame

        let targetFrame: CGRect
        switch position {
        case .left:
            targetFrame = CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height
            )
        case .right:
            targetFrame = CGRect(
                x: visibleFrame.midX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height
            )
        case .top:
            targetFrame = CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.midY,
                width: visibleFrame.width,
                height: visibleFrame.height / 2
            )
        case .bottom:
            targetFrame = CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width,
                height: visibleFrame.height / 2
            )
        case .topLeft:
            targetFrame = CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.midY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height / 2
            )
        case .topRight:
            targetFrame = CGRect(
                x: visibleFrame.midX,
                y: visibleFrame.midY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height / 2
            )
        case .bottomLeft:
            targetFrame = CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height / 2
            )
        case .bottomRight:
            targetFrame = CGRect(
                x: visibleFrame.midX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height / 2
            )
        case .maximize:
            targetFrame = visibleFrame
        case .center:
            let w = visibleFrame.width * 0.6
            let h = visibleFrame.height * 0.7
            targetFrame = CGRect(
                x: visibleFrame.midX - w / 2,
                y: visibleFrame.midY - h / 2,
                width: w,
                height: h
            )
        case .zone(let index):
            targetFrame = activeLayout.zones[safe: index]?.frame(in: visibleFrame) ?? visibleFrame
        }

        moveFrontWindow(to: targetFrame)
    }

    // MARK: - Pin Window

    /// Toggle pin on the currently focused window. If something is
    /// already pinned, unpins it (regardless of which window is
    /// currently focused) — the shortcut is a global "release the
    /// current pin" too.
    func togglePinWindow() {
        if pinnedTarget != nil {
            unpinWindow(playSound: true)
        } else {
            pinFocusedWindow()
        }
    }

    /// Capture the focused window of the frontmost app and start
    /// holding it on top. Shows a red border + plays a pin sound.
    private func pinFocusedWindow() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)

        // `kAXFocusedWindowAttribute` is the right read: `kAXWindowsAttribute`
        // returns ALL windows of the app, ordered arbitrarily — picking
        // .first there would pin the wrong window when the app has
        // multiple open.
        var windowRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appRef, kAXFocusedWindowAttribute as CFString, &windowRef
        )
        guard err == .success, let window = windowRef else {
            // No focused window — likely the user is on the desktop, or
            // Accessibility permission isn't granted. Soft-fail silently;
            // System Settings → Privacy & Security → Accessibility shows
            // the missing entitlement.
            NSSound.beep()
            return
        }
        let windowElement = window as! AXUIElement

        // Resolve the window's CGWindowID — needed by SkyLight to set
        // the level cross-app. If we can't, fail soft (border + AXRaise
        // still kick in but the pin won't elevate over other apps).
        var windowID: CGWindowID = 0
        _AXUIElementGetWindow(windowElement, &windowID)

        pinnedTarget = PinnedTarget(
            pid: frontApp.processIdentifier,
            windowElement: windowElement,
            windowID: windowID,
            appName: frontApp.localizedName ?? "Window"
        )

        // Elevate the window above other apps via SkyLight.
        if windowID != 0 {
            let conn = CGSMainConnectionID()
            _ = CGSSetWindowLevel(conn, windowID, pinnedLevel)
        }

        // Build the red-border overlay.
        let panel = PinnedWindowBorderPanel()
        panel.orderFront(nil)
        borderPanel = panel

        // Start the raise + reposition poller.
        pinTimer?.invalidate()
        pinTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.tickPin()
        }
        // Run one tick immediately so the border appears in place
        // without a 60ms flash at (0, 0).
        tickPin()

        playPinSound(pin: true)
    }

    /// Stop tracking + tear down the overlay. Safe to call when no
    /// window is pinned.
    private func unpinWindow(playSound: Bool) {
        pinTimer?.invalidate()
        pinTimer = nil
        borderPanel?.orderOut(nil)
        borderPanel = nil

        // Restore the window's normal level so it stops floating after
        // we release it. If the app already quit, this is a no-op.
        if let target = pinnedTarget, target.windowID != 0 {
            let conn = CGSMainConnectionID()
            _ = CGSSetWindowLevel(conn, target.windowID, normalLevel)
        }

        let hadTarget = pinnedTarget != nil
        pinnedTarget = nil
        if playSound, hadTarget {
            playPinSound(pin: false)
        }
    }

    /// One poll cycle: re-read the pinned window's frame, move the
    /// border overlay to match, raise the window, and detect
    /// minimize / app-quit so we can hide the border or auto-unpin.
    private func tickPin() {
        guard let target = pinnedTarget else { return }

        // App went away? Unpin automatically.
        if NSRunningApplication(processIdentifier: target.pid) == nil {
            unpinWindow(playSound: false)
            return
        }

        // Minimized? Hide the border but keep polling so we can show
        // it again when the window is restored.
        var minimizedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(
            target.windowElement,
            kAXMinimizedAttribute as CFString,
            &minimizedRef
        )
        if (minimizedRef as? Bool) == true {
            borderPanel?.orderOut(nil)
            return
        }

        // Read window frame (top-left origin, screen coordinates).
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(target.windowElement, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(target.windowElement, kAXSizeAttribute as CFString, &sizeRef)

        var pos = CGPoint.zero
        var size = CGSize.zero
        if let raw = posRef {
            AXValueGetValue(raw as! AXValue, .cgPoint, &pos)
        }
        if let raw = sizeRef {
            AXValueGetValue(raw as! AXValue, .cgSize, &size)
        }
        guard size.width > 0, size.height > 0 else { return }

        // AX coords use top-left origin matching the global screen
        // space (origin at the top-left of the primary display).
        // NSWindow uses bottom-left. Convert.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        // Expand the panel a few pt past the window edges so the
        // 3pt stroke sits OUTSIDE the window rather than overlapping
        // its content.
        let inset: CGFloat = 3
        let expanded = NSRect(
            x: pos.x - inset,
            y: (primaryHeight - pos.y - size.height) - inset,
            width: size.width + inset * 2,
            height: size.height + inset * 2
        )

        if let panel = borderPanel {
            if !panel.isVisible { panel.orderFront(nil) }
            panel.setFrame(expanded, display: false)
        }

        // Persistent raise — keeps the window above OTHER windows in
        // the same app (AXRaise) AND above other apps (SkyLight level
        // re-application — macOS resets levels on space switches and
        // some app activations).
        AXUIElementPerformAction(target.windowElement, kAXRaiseAction as CFString)
        if target.windowID != 0 {
            let conn = CGSMainConnectionID()
            _ = CGSSetWindowLevel(conn, target.windowID, pinnedLevel)
        }
    }

    /// Submarine on pin (distinct "tug" sound), Pop on unpin (release).
    /// Both are bundled with macOS so we don't need to ship audio.
    private func playPinSound(pin: Bool) {
        let name: NSSound.Name = pin
            ? NSSound.Name("Submarine")
            : NSSound.Name("Pop")
        NSSound(named: name)?.play()
    }

    // MARK: - Workspaces

    func saveCurrentWorkspace(name: String) {
        // Capture current window arrangement
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }

        var apps: [WorkspaceApp] = []
        for info in windowList {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let pid = info[kCGWindowOwnerPID as String] as? Int32 else { continue }

            // Skip system processes
            if ownerName == "Window Server" || ownerName == "Dock" { continue }

            let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

            apps.append(WorkspaceApp(
                bundleIdentifier: bundleId ?? "",
                name: ownerName,
                frame: CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 800,
                    height: bounds["Height"] ?? 600
                )
            ))
        }

        let workspace = Workspace(
            id: UUID().uuidString,
            name: name,
            apps: apps
        )

        savedWorkspaces.append(workspace)
        saveWorkspaces()
    }

    func launchWorkspace(_ workspace: Workspace) {
        for app in workspace.apps {
            guard !app.bundleIdentifier.isEmpty else { continue }

            // Launch or activate the app
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { runningApp, error in
                    if let error = error {
                        print("[Forge] Failed to launch \(app.name): \(error)")
                    }
                    // TODO: Position window after launch using Accessibility API
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func moveFrontWindow(to frame: CGRect) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)

        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)

        guard let windows = windowsRef as? [AXUIElement], let frontWindow = windows.first else { return }

        // Set position
        var position = CGPoint(x: frame.origin.x, y: frame.origin.y)
        let positionValue = AXValueCreate(.cgPoint, &position)!
        AXUIElementSetAttributeValue(frontWindow, kAXPositionAttribute as CFString, positionValue)

        // Set size
        var size = CGSize(width: frame.width, height: frame.height)
        let sizeValue = AXValueCreate(.cgSize, &size)!
        AXUIElementSetAttributeValue(frontWindow, kAXSizeAttribute as CFString, sizeValue)
    }

    // MARK: - Persistence

    private var workspacesURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Forge/workspaces.json")
    }

    private func loadWorkspaces() {
        guard let data = try? Data(contentsOf: workspacesURL),
              let decoded = try? JSONDecoder().decode([Workspace].self, from: data) else { return }
        savedWorkspaces = decoded
    }

    private func saveWorkspaces() {
        guard let data = try? JSONEncoder().encode(savedWorkspaces) else { return }
        try? data.write(to: workspacesURL, options: .atomic)
    }

    // MARK: - Module Protocol

}

// MARK: - Supporting Types

enum SnapPosition {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center
    case zone(Int)
}

struct ZoneLayout: Identifiable {
    let id: String
    let name: String
    let zones: [Zone]

    struct Zone {
        let x: CGFloat       // 0.0 to 1.0
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        func frame(in screen: CGRect) -> CGRect {
            CGRect(
                x: screen.minX + screen.width * x,
                y: screen.minY + screen.height * y,
                width: screen.width * width,
                height: screen.height * height
            )
        }
    }

    // Preset layouts
    static let twoColumn = ZoneLayout(
        id: "twoColumn", name: "Two Column",
        zones: [
            Zone(x: 0, y: 0, width: 0.5, height: 1),
            Zone(x: 0.5, y: 0, width: 0.5, height: 1)
        ]
    )

    static let threeColumn = ZoneLayout(
        id: "threeColumn", name: "Three Column",
        zones: [
            Zone(x: 0, y: 0, width: 0.333, height: 1),
            Zone(x: 0.333, y: 0, width: 0.334, height: 1),
            Zone(x: 0.667, y: 0, width: 0.333, height: 1)
        ]
    )

    static let devWithSidebar = ZoneLayout(
        id: "devSidebar", name: "Dev + Sidebar",
        zones: [
            Zone(x: 0, y: 0, width: 0.65, height: 1),
            Zone(x: 0.65, y: 0, width: 0.35, height: 0.5),
            Zone(x: 0.65, y: 0.5, width: 0.35, height: 0.5)
        ]
    )

    static let fourQuadrant = ZoneLayout(
        id: "fourQuad", name: "Four Quadrant",
        zones: [
            Zone(x: 0, y: 0, width: 0.5, height: 0.5),
            Zone(x: 0.5, y: 0, width: 0.5, height: 0.5),
            Zone(x: 0, y: 0.5, width: 0.5, height: 0.5),
            Zone(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        ]
    )

    static let allPresets: [ZoneLayout] = [twoColumn, threeColumn, devWithSidebar, fourQuadrant]
}

struct Workspace: Identifiable, Codable {
    let id: String
    let name: String
    let apps: [WorkspaceApp]
}

struct WorkspaceApp: Codable {
    let bundleIdentifier: String
    let name: String
    let frame: CGRect
}

// CGRect Codable conformance
extension CGRect: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case x, y, width, height
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try c.decode(CGFloat.self, forKey: .x),
            y: try c.decode(CGFloat.self, forKey: .y),
            width: try c.decode(CGFloat.self, forKey: .width),
            height: try c.decode(CGFloat.self, forKey: .height)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(origin.x, forKey: .x)
        try c.encode(origin.y, forKey: .y)
        try c.encode(size.width, forKey: .width)
        try c.encode(size.height, forKey: .height)
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Pinned window border overlay

/// Borderless, click-through panel that draws a red rounded stroke
/// around the pinned window. Sits at `.statusBar` level so it floats
/// above almost everything; mouse events pass through so the user
/// can still interact with the window underneath normally.
final class PinnedWindowBorderPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // `.statusBar` keeps the border above ordinary windows but
        // below modal alerts, so it doesn't obscure system prompts.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false

        let view = PinnedWindowBorderView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the actual stroke. Re-renders on resize because the view
/// auto-resizes inside the panel.
final class PinnedWindowBorderView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Inset by half-stroke so the line sits cleanly inside the
        // view's bounds (Cocoa strokes are centered on the path).
        let lineWidth: CGFloat = 3
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.systemRed.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

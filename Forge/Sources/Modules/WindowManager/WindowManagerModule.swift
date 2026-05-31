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

// Returns the connection ID that OWNS a given window. Setting a window's
// level through its owning connection works on macOS versions where the
// same call through our main connection is silently ignored.
@_silgen_name("CGSGetWindowOwner")
private func CGSGetWindowOwner(_ cid: Int32, _ wid: CGWindowID, _ outOwner: UnsafeMutablePointer<Int32>) -> Int32

// Orders a window relative to another (or absolutely). order: 1 = above,
// -1 = below, 0 = out. relativeTo: 0 = absolute front/back. Re-asserting
// the order each tick complements the level change.
@_silgen_name("CGSOrderWindow")
private func CGSOrderWindow(_ cid: Int32, _ wid: CGWindowID, _ order: Int32, _ relativeTo: CGWindowID) -> Int32


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
    /// resizes and continually re-raises the window so it stays on top.
    private var pinTimer: Timer?

    /// Watches for app-switch events so we can re-raise the pinned
    /// window when the user clicks into another app.
    private var appSwitchObserver: Any?

    struct PinnedTarget {
        let pid: pid_t
        let windowElement: AXUIElement
        let windowID: CGWindowID
        let appName: String
    }

    /// Target window level. CGSSetWindowLevel may silently no-op on
    /// macOS Tahoe with self-signed apps, so this is best-effort.
    private let pinnedLevel: Int32 = 25   // kCGStatusWindowLevel
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

    /// Smart 3-state toggle:
    ///  • Nothing pinned → pin the focused window
    ///  • Pinned but behind other windows → bring it to front
    ///  • Pinned AND already in front → unpin
    func togglePinWindow() {
        if let target = pinnedTarget {
            let pinnedAppIsFront = NSWorkspace.shared.frontmostApplication?
                .processIdentifier == target.pid
            if pinnedAppIsFront {
                unpinWindow(playSound: true)
            } else {
                bringPinnedToFront()
            }
        } else {
            pinFocusedWindow()
        }
    }

    /// Immediately bring the pinned window back to the front.
    /// Called by the shortcut toggle and the app-switch observer.
    private func bringPinnedToFront() {
        guard let target = pinnedTarget else { return }
        // Activate the app so its windows come to the foreground
        NSRunningApplication(processIdentifier: target.pid)?
            .activate(options: .activateIgnoringOtherApps)
        // Raise the specific pinned window above siblings
        AXUIElementPerformAction(
            target.windowElement, kAXRaiseAction as CFString)
        // Best-effort SkyLight elevation (works on older macOS,
        // silently no-ops on Tahoe with self-signed apps)
        elevate(windowID: target.windowID)
    }

    /// Best-effort SkyLight elevation. Tries to set the window level
    /// via the private CGSSetWindowLevel API. On macOS Tahoe with
    /// self-signed apps this silently no-ops — that's OK, the
    /// app-switch observer handles the fallback. On older macOS (or
    /// with a Developer ID signature) the level change sticks and the
    /// window truly floats above everything.
    private func elevate(windowID: CGWindowID) {
        guard windowID != 0 else { return }
        let mainConn = CGSMainConnectionID()
        CGSSetWindowLevel(mainConn, windowID, pinnedLevel)
        CGSOrderWindow(mainConn, windowID, 1, 0)

        var ownerConn: Int32 = 0
        if CGSGetWindowOwner(mainConn, windowID, &ownerConn) == 0,
           ownerConn != 0 {
            CGSSetWindowLevel(ownerConn, windowID, pinnedLevel)
            CGSOrderWindow(ownerConn, windowID, 1, 0)
        }
    }

    /// Resolve an AX window element to its CGWindowID. Fast path is the
    /// private `_AXUIElementGetWindow`; if that returns 0 (it can, in
    /// sandboxed/edge cases) we fall back to matching the window in the
    /// CG window list by owner-pid + frame, which only needs the public
    /// `CGWindowListCopyWindowInfo` metadata (no Screen Recording grant).
    private func resolveWindowID(for element: AXUIElement, pid: pid_t) -> CGWindowID {
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(element, &wid) == .success, wid != 0 {
            return wid
        }

        // Fallback — read the AX frame and match it against the on-screen
        // windows owned by this pid.
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
        if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }

        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return 0 }

        var bestMatch: CGWindowID = 0
        for info in infoList {
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                let num = info[kCGWindowNumber as String] as? CGWindowID,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let bx = bounds["X"] ?? -1
            let by = bounds["Y"] ?? -1
            let bw = bounds["Width"] ?? -1
            let bh = bounds["Height"] ?? -1
            // CG window bounds and AX frame both use top-left global
            // coordinates; match with a few-px tolerance.
            if size.width > 0,
               abs(bx - pos.x) < 6, abs(by - pos.y) < 6,
               abs(bw - size.width) < 6, abs(bh - size.height) < 6 {
                return num
            }
            // Keep the largest pid-owned window as a last resort if no
            // exact frame match is found.
            if bestMatch == 0, bw * bh > 0 { bestMatch = num }
        }
        return bestMatch
    }

    /// Capture the focused window of the frontmost app and start
    /// holding it on top. Shows a red border + plays a pin sound.
    /// Uses a dual strategy: SkyLight level elevation (best-effort,
    /// may silently fail on macOS Tahoe with self-signed apps) plus
    /// an app-switch observer that re-raises the window whenever
    /// another app comes to the foreground.
    private func pinFocusedWindow() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)

        var windowRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appRef, kAXFocusedWindowAttribute as CFString, &windowRef
        )
        guard err == .success, let window = windowRef else {
            NSSound.beep()
            return
        }
        let windowElement = window as! AXUIElement
        let windowID = resolveWindowID(
            for: windowElement, pid: frontApp.processIdentifier)

        guard windowID != 0 else {
            NSSound.beep()
            return
        }

        pinnedTarget = PinnedTarget(
            pid: frontApp.processIdentifier,
            windowElement: windowElement,
            windowID: windowID,
            appName: frontApp.localizedName ?? "Window"
        )

        // Best-effort SkyLight elevation
        elevate(windowID: windowID)

        // Build the red-border overlay.
        let panel = PinnedWindowBorderPanel()
        panel.orderFront(nil)
        borderPanel = panel

        // ── App-switch observer ────────────────────────────────────
        // When the user clicks into another app, we wait a brief
        // moment (so macOS finishes its activation animation), then
        // re-activate the pinned app to push its window back on top.
        appSwitchObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] notif in
                guard let self = self, let target = self.pinnedTarget else { return }
                guard let activated = notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                // Don't fight ourselves or the pinned app
                if activated.processIdentifier == target.pid { return }
                if activated.bundleIdentifier == Bundle.main.bundleIdentifier { return }

                // Brief delay lets macOS finish its activation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    [weak self] in
                    self?.bringPinnedToFront()
                }
            }

        // Start the raise + reposition poller.
        pinTimer?.invalidate()
        pinTimer = Timer.scheduledTimer(
            withTimeInterval: 0.06, repeats: true
        ) { [weak self] _ in
            self?.tickPin()
        }
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

        // Remove app-switch observer
        if let obs = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appSwitchObserver = nil
        }

        // Restore the window's normal level (best-effort)
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

        // AXRaise keeps the pinned window above OTHER windows in the
        // same app. Cross-app elevation is handled by the app-switch
        // observer (or SkyLight if the level change took effect).
        AXUIElementPerformAction(target.windowElement, kAXRaiseAction as CFString)
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

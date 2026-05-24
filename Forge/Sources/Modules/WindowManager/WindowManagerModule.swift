import SwiftUI
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Window Management module — FancyZones + Always On Top + Snap shortcuts.
/// Provides zone-based window tiling, always-on-top pinning, and keyboard-driven snapping.
final class WindowManagerModule: ForgeModule, ObservableObject {
    let id = "windowManager"
    let name = "Window Manager"
    let description = "Snap zones, always on top, workspaces"
    let iconName = "rectangle.split.3x1"
    let category: ModuleCategory = .windows
    var isEnabled: Bool = true

    // MARK: - State

    @Published var activeLayout: ZoneLayout = .twoColumn
    @Published var pinnedWindows: Set<CGWindowID> = []
    @Published var savedWorkspaces: [Workspace] = []

    // MARK: - Lifecycle

    func activate() {
        loadWorkspaces()
        print("[Forge WindowManager] Activated with layout: \(activeLayout.name)")
    }

    func deactivate() {
        // Remove all pin overlays
        pinnedWindows.removeAll()
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

    // MARK: - Always On Top

    func toggleAlwaysOnTop() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }

        // Use Accessibility API to get and modify window level
        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)

        guard let windows = windowsRef as? [AXUIElement], let frontWindow = windows.first else { return }

        // Get window ID for tracking
        var windowId: CGWindowID = 0
        _AXUIElementGetWindow(frontWindow, &windowId)

        if pinnedWindows.contains(windowId) {
            pinnedWindows.remove(windowId)
            setWindowLevel(frontWindow, level: .normal)
            print("[Forge] Unpinned window \(windowId)")
        } else {
            pinnedWindows.insert(windowId)
            setWindowLevel(frontWindow, level: .floating)
            print("[Forge] Pinned window \(windowId)")
        }
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

    private func setWindowLevel(_ window: AXUIElement, level: NSWindow.Level) {
        // Note: Setting window level via AX API is limited on macOS.
        // Full implementation requires a helper process or accessibility permissions.
        // This is a simplified version.
        if level == .floating {
            AXUIElementSetAttributeValue(window, "AXRaise" as CFString, kCFBooleanTrue)
        }
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

    func commands() -> [ForgeCommand] {
        var commands: [ForgeCommand] = [
            ForgeCommand(
                id: "window.snapLeft", title: "Snap Left", subtitle: "Snap window to left half",
                iconName: "rectangle.lefthalf.filled", moduleId: id,
                action: { [weak self] in self?.snapFrontWindow(to: .left) },
                keywords: ["snap", "left", "half", "window", "tile"]
            ),
            ForgeCommand(
                id: "window.snapRight", title: "Snap Right", subtitle: "Snap window to right half",
                iconName: "rectangle.righthalf.filled", moduleId: id,
                action: { [weak self] in self?.snapFrontWindow(to: .right) },
                keywords: ["snap", "right", "half", "window", "tile"]
            ),
            ForgeCommand(
                id: "window.maximize", title: "Maximize", subtitle: "Fill the entire screen",
                iconName: "rectangle.fill", moduleId: id,
                action: { [weak self] in self?.snapFrontWindow(to: .maximize) },
                keywords: ["maximize", "full", "screen", "window"]
            ),
            ForgeCommand(
                id: "window.center", title: "Center Window", subtitle: "Center and resize to 60%",
                iconName: "rectangle.center.inset.filled", moduleId: id,
                action: { [weak self] in self?.snapFrontWindow(to: .center) },
                keywords: ["center", "middle", "window"]
            ),
            ForgeCommand(
                id: "window.alwaysOnTop", title: "Always On Top", subtitle: "Pin window above others",
                iconName: "pin", moduleId: id,
                action: { [weak self] in self?.toggleAlwaysOnTop() },
                keywords: ["pin", "always", "top", "above", "float"]
            ),
        ]

        // Add workspace launch commands
        for workspace in savedWorkspaces {
            commands.append(ForgeCommand(
                id: "workspace.\(workspace.id)",
                title: "Launch: \(workspace.name)",
                subtitle: "\(workspace.apps.count) apps",
                iconName: "square.grid.2x2",
                moduleId: id,
                action: { [weak self] in self?.launchWorkspace(workspace) },
                keywords: ["workspace", "launch", workspace.name.lowercased()]
            ))
        }

        return commands
    }
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

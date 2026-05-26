import SwiftUI

/// Every Forge utility conforms to this protocol.
/// Disabled modules consume zero CPU/memory beyond this static registration record.
protocol ForgeModule: AnyObject, Identifiable {
    /// Unique identifier for the module (e.g., "calendar", "screenshot")
    var id: String { get }

    /// Display name shown in Settings
    var name: String { get }

    /// Short description for Settings
    var description: String { get }

    /// SF Symbol name for the module icon
    var iconName: String { get }

    /// Category for grouping in Settings
    var category: ModuleCategory { get }

    /// Whether this module is currently enabled
    var isEnabled: Bool { get set }

    /// Called when the module is activated (user enables it or app launches with it enabled)
    func activate()

    /// Called when the module is deactivated (user disables it or app quits)
    func deactivate()

    /// The view this module contributes to the menu bar popover (if any)
    @ViewBuilder
    func menuBarView() -> AnyView

    /// Global keyboard shortcuts this module needs
    func shortcuts() -> [ForgeShortcut]
}

// MARK: - Default Implementations

extension ForgeModule {
    func menuBarView() -> AnyView {
        AnyView(EmptyView())
    }

    func shortcuts() -> [ForgeShortcut] {
        []
    }
}

// MARK: - Module Category
//
// Order here = display order in the popover's Tools tab. Names mirror
// the Settings → Shortcuts groups so the Tools list and the Shortcuts
// list read as the same hierarchy.

enum ModuleCategory: String, CaseIterable, Identifiable, Codable {
    case calendar  = "Calendar & Meetings"
    case windows   = "Window Management"
    case screen    = "Screen Tools"
    case input     = "Mouse & Highlights"
    case keyboard  = "Keyboard"
    case files     = "Files & Clipboard"
    case developer = "Developer"
    // Kept for back-compat with any persisted data that used these
    // names — no modules live here anymore.
    case system    = "System Utilities"
    case launcher  = "Launcher"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .calendar:  return "calendar"
        case .windows:   return "rectangle.split.3x1"
        case .screen:    return "eyedropper"
        case .input:     return "cursorarrow.click.2"
        case .keyboard:  return "keyboard"
        case .files:     return "doc.on.clipboard"
        case .developer: return "terminal"
        case .system:    return "gearshape.2"
        case .launcher:  return "magnifyingglass"
        }
    }
}

// MARK: - Shortcut Definition

struct ForgeShortcut {
    let id: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let description: String
    let action: () -> Void
}

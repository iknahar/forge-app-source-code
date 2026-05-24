import SwiftUI

/// Every Forge utility conforms to this protocol.
/// Disabled modules consume zero CPU/memory beyond this static registration record.
protocol ForgeModule: AnyObject, Identifiable {
    /// Unique identifier for the module (e.g., "calendar", "commandPalette")
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

    /// Commands this module provides to the Command Palette
    func commands() -> [ForgeCommand]

    /// Global keyboard shortcuts this module needs
    func shortcuts() -> [ForgeShortcut]
}

// MARK: - Default Implementations

extension ForgeModule {
    func menuBarView() -> AnyView {
        AnyView(EmptyView())
    }

    func commands() -> [ForgeCommand] {
        []
    }

    func shortcuts() -> [ForgeShortcut] {
        []
    }
}

// MARK: - Module Category

enum ModuleCategory: String, CaseIterable, Identifiable, Codable {
    case calendar = "Calendar & Meetings"
    case windows = "Window Management"
    case files = "Files & Clipboard"
    case screen = "Screen Tools"
    case input = "Input Customization"
    case system = "System Utilities"
    case developer = "Developer Tools"
    case launcher = "Launcher"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .calendar: return "calendar"
        case .windows: return "rectangle.split.3x1"
        case .files: return "doc.on.clipboard"
        case .screen: return "eyedropper"
        case .input: return "keyboard"
        case .system: return "gearshape.2"
        case .developer: return "terminal"
        case .launcher: return "magnifyingglass"
        }
    }
}

// MARK: - Command (for Command Palette)

struct ForgeCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let iconName: String
    let moduleId: String
    let action: () -> Void

    /// Keywords for fuzzy search matching
    let keywords: [String]
}

// MARK: - Shortcut Definition

struct ForgeShortcut {
    let id: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let description: String
    let action: () -> Void
}

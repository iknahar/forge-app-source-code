import SwiftUI

/// Command Palette — the central hub of Forge.
/// Every feature is reachable from here via fuzzy search.
/// Activated with ⌘+Shift+Space globally.
final class CommandPaletteModule: ForgeModule, ObservableObject {
    let id = "commandPalette"
    let name = "Command Palette"
    let description = "Search and launch anything"
    let iconName = "magnifyingglass"
    let category: ModuleCategory = .launcher
    var isEnabled: Bool = true

    func activate() {
        print("[Forge] Command Palette activated")
    }

    func deactivate() {
        print("[Forge] Command Palette deactivated")
    }

    func commands() -> [ForgeCommand] {
        [
            ForgeCommand(
                id: "system.lock",
                title: "Lock Screen",
                subtitle: "Lock this Mac",
                iconName: "lock",
                moduleId: id,
                action: { Self.lockScreen() },
                keywords: ["lock", "screen", "security"]
            ),
            ForgeCommand(
                id: "system.sleep",
                title: "Sleep Display",
                subtitle: "Turn off the display",
                iconName: "moon",
                moduleId: id,
                action: { Self.sleepDisplay() },
                keywords: ["sleep", "display", "monitor", "off"]
            ),
            ForgeCommand(
                id: "system.emptyTrash",
                title: "Empty Trash",
                subtitle: "Permanently delete trashed items",
                iconName: "trash",
                moduleId: id,
                action: { Self.emptyTrash() },
                keywords: ["empty", "trash", "delete", "clean"]
            ),
            ForgeCommand(
                id: "forge.settings",
                title: "Forge Settings",
                subtitle: "Open preferences",
                iconName: "gearshape",
                moduleId: id,
                action: {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                },
                keywords: ["settings", "preferences", "config"]
            ),
        ]
    }

    // MARK: - System Actions

    private static func lockScreen() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    private static func sleepDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    private static func emptyTrash() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trash")!)
    }
}

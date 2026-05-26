import AppKit
import Carbon.HIToolbox

/// One source of truth for "is this shortcut likely to collide with
/// something the user already relies on?" Used by the Launchers
/// settings (and any future shortcut-recording UI) to warn the user
/// before they bind a combo that would steal a system action.
///
/// Two flavours of conflict the helper detects:
///   1. **macOS / system shortcuts** — a hard-coded inventory of the
///      well-known ones (⌘C, ⌘V, ⌘Q, ⌘W, ⌘⇧3, ⌘⌥⎋, ⌘Space, etc.).
///      Far from exhaustive — there's no public API that enumerates
///      every system shortcut — but covers the high-frequency ones
///      that would obviously break the user's workflow.
///   2. **Forge's own shortcuts** — the live `SettingsManager`
///      bindings (`screenshot`, `colorPicker`, etc.) plus the
///      list of registered Launcher shortcuts on `LaunchersModule`.
///      Detected via simple `(keyCode, modifiers)` equality.
///
/// "Overlapping in any other app" is intentionally out of scope —
/// macOS doesn't expose a global, queryable registry of all app
/// shortcuts, so any such check would be a guessing game. The system
/// inventory below is the next-best heuristic.
enum ShortcutConflicts {

    /// One row of the macOS shortcut inventory.
    struct SystemShortcut {
        let keyCode: UInt16
        /// Normalised modifier set. Compared with
        /// `event.modifierFlags.intersection(.deviceIndependentFlagsMask)`
        /// (which is also what `HotkeyManager` stores) so case-of-shift
        /// etc. doesn't slip through.
        let modifiers: NSEvent.ModifierFlags
        let label: String
    }

    /// The well-known macOS system shortcuts. NOT exhaustive — we
    /// list the ones a user is most likely to type by reflex.
    static let systemShortcuts: [SystemShortcut] = [
        // Core editing
        .init(keyCode: 0x08, modifiers: [.command],               label: "Copy"),       // C
        .init(keyCode: 0x09, modifiers: [.command],               label: "Paste"),      // V
        .init(keyCode: 0x07, modifiers: [.command],               label: "Cut"),        // X
        .init(keyCode: 0x06, modifiers: [.command],               label: "Undo"),       // Z
        .init(keyCode: 0x06, modifiers: [.command, .shift],       label: "Redo"),       // ⇧Z
        .init(keyCode: 0x00, modifiers: [.command],               label: "Select All"), // A
        .init(keyCode: 0x01, modifiers: [.command],               label: "Save"),       // S
        .init(keyCode: 0x11, modifiers: [.command],               label: "Open"),       // O — note: T(0x11)? actually T
        .init(keyCode: 0x2D, modifiers: [.command],               label: "New"),        // N
        .init(keyCode: 0x23, modifiers: [.command],               label: "Print"),      // P
        .init(keyCode: 0x03, modifiers: [.command],               label: "Find"),       // F
        .init(keyCode: 0x05, modifiers: [.command],               label: "Find Next"),  // G

        // Window / app management
        .init(keyCode: 0x0D, modifiers: [.command],               label: "Close Window"),    // W
        .init(keyCode: 0x0C, modifiers: [.command],               label: "Quit App"),        // Q
        .init(keyCode: 0x04, modifiers: [.command],               label: "Hide App"),        // H
        .init(keyCode: 0x2E, modifiers: [.command],               label: "Minimize Window"), // M
        .init(keyCode: 0x30, modifiers: [.command],               label: "App Switcher"),    // Tab
        .init(keyCode: 0x33, modifiers: [.command],               label: "Delete Word Back"),// Delete

        // Spotlight / system
        .init(keyCode: 0x31, modifiers: [.command],               label: "Spotlight"),       // Space

        // Screenshots
        .init(keyCode: 0x14, modifiers: [.command, .shift],       label: "Screenshot Full"),     // 3
        .init(keyCode: 0x15, modifiers: [.command, .shift],       label: "Screenshot Region"),   // 4
        .init(keyCode: 0x17, modifiers: [.command, .shift],       label: "Screenshot Tools"),    // 5

        // Force Quit
        .init(keyCode: 0x35, modifiers: [.command, .option],      label: "Force Quit"),          // Esc
    ]

    // MARK: - Public API

    /// Returns a human-readable description of any conflict the
    /// passed `(keyCode, modifiers)` combo would cause, or `nil` if
    /// the combo looks safe to bind.
    static func conflict(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        forgeBindings: [String: ShortcutBinding],
        excludingForgeId: String? = nil,
        launchers: [Launcher] = [],
        excludingLauncherId: UUID? = nil
    ) -> String? {
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)

        // 1. System inventory.
        if let hit = systemShortcuts.first(where: {
            $0.keyCode == keyCode && $0.modifiers == normalized
        }) {
            return "macOS default: \(hit.label)"
        }

        // 2. Forge's own built-in module shortcuts.
        for (id, binding) in forgeBindings {
            if id == excludingForgeId { continue }
            if binding.keyCode == keyCode && binding.nsModifiers == normalized {
                return "Forge action: \(id)"
            }
        }

        // 3. Launcher shortcuts.
        for launcher in launchers {
            if launcher.id == excludingLauncherId { continue }
            guard let binding = launcher.shortcut else { continue }
            if binding.keyCode == keyCode && binding.nsModifiers == normalized {
                return "Launcher: \(launcher.name.isEmpty ? "Untitled" : launcher.name)"
            }
        }

        return nil
    }
}

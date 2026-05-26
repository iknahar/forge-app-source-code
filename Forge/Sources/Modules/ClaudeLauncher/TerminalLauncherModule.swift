import SwiftUI
import AppKit

/// Opens a fresh macOS Terminal.app window. Bound to `⌃⌥⇧T` by
/// default. Lives as its own registered module — not as a method on
/// `ClaudeLauncherModule` — so it shows up as its own row in the
/// menu-bar Tools popover and the Settings → Shortcuts list,
/// distinct from the Claude-Code variant.
///
/// The two terminal launchers share their AppleScript implementation
/// path conceptually (both run `tell application "Terminal" / do
/// script`) but the duplication is tiny and keeps each module a
/// single-purpose unit — easier for the user to reason about
/// (one toggle = one shortcut) and easier for the Tools grid which
/// iterates registered modules.
final class TerminalLauncherModule: ForgeModule, ObservableObject {
    let id = "openTerminal"
    let name = "Open Terminal"
    let description = "Open a fresh macOS Terminal.app window."
    let iconName = "terminal"
    let category: ModuleCategory = .developer
    var isEnabled: Bool = true

    func activate() {}
    func deactivate() {}

    /// Open a plain Terminal window — no auto-typed command.
    func launch() {
        runInNewTerminal(command: "")
    }

    private func runInNewTerminal(command: String) {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&error)
            if let err = error {
                print("[Forge TerminalLauncher] AppleScript failed: \(err)")
                NSSound.beep()
            }
        }
    }
}

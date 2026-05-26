import SwiftUI
import AppKit

/// Opens Terminal and starts a Claude Code session in the user's
/// current shell. Bound to `⌃⌥K` by default. The module itself is
/// stateless — it just exposes `launch()` which the global hotkey
/// in AppDelegate calls.
///
/// Why AppleScript? `NSWorkspace.openURL(...)` can open Terminal but
/// can't *also* type a command into the new window. AppleScript's
/// `do script` is the standard macOS way to open a Terminal window
/// and immediately run something in it.
final class ClaudeLauncherModule: ForgeModule, ObservableObject {
    let id = "claudeLauncher"
    let name = "Claude Code"
    let description = "Open Terminal and start a Claude Code session"
    let iconName = "terminal.fill"
    let category: ModuleCategory = .developer
    var isEnabled: Bool = true

    func activate() {}
    func deactivate() {}

    /// Launch a fresh Terminal window and run the `claude` CLI in it.
    /// If `claude` isn't on $PATH the window opens anyway with an
    /// inline hint — the user can install it from the Anthropic docs.
    func launch() {
        runInNewTerminal(command: "command -v claude >/dev/null 2>&1 && claude || echo 'claude command not found. Install it from https://www.anthropic.com/claude-code'")
    }

    /// Open a plain Terminal.app window — no auto-command. Bound to
    /// ⌃⌥⇧T by default. Useful when the user just wants a shell, not
    /// specifically a Claude session.
    func launchPlainTerminal() {
        // `do script ""` (empty) gets us a clean new window without
        // typing anything into it.
        runInNewTerminal(command: "")
    }

    /// Shared AppleScript path so both launchers stay consistent.
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
                print("[Forge ClaudeLauncher] AppleScript failed: \(err)")
                NSSound.beep()
            }
        }
    }
}

import Foundation
import ServiceManagement
import AppKit

/// Launch-at-login control backed by `SMAppService` (macOS 13+).
///
/// Registers the MAIN app bundle as a login item — no separate helper
/// bundle or privileged daemon required. The *enabled* state is owned by
/// the system (queried via `SMAppService.mainApp.status`), NOT persisted
/// in Forge's JSON, so the toggle stays correct even if the user changes
/// it directly in System Settings → General → Login Items.
///
/// Default-on policy: Forge registers itself at login automatically on a
/// fresh install. We record only the user's *explicit* choice (a single
/// "did the user turn this off" flag) so the default never overrides a
/// deliberate opt-out — that's what keeps the toggle genuinely two-way
/// instead of snapping back on the next launch.
///
/// Reliability note: `SMAppService` keys on the code signature, so this
/// is dependable only because Forge signs with the fixed "Forge Dev"
/// certificate (see project.yml / BUILD.md) rather than an ad-hoc
/// signature that changes every build.
enum LaunchAtLogin {

    /// UserDefaults flag recording that the user explicitly turned launch
    /// at login OFF. Absent/false = honor the default-on policy.
    private static let userDisabledKey = "forge.launchAtLogin.userDisabled"

    /// Whether Forge is currently registered to open at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turn launch-at-login on or off in response to an explicit user
    /// action (the Settings toggle). Records the choice so the default-on
    /// policy won't re-enable it later if they turned it off.
    ///
    /// Returns the resulting enabled state so the toggle can reconcile with
    /// reality — e.g. if macOS puts the request in `.requiresApproval`
    /// (when the user previously disabled Forge in System Settings) we open
    /// that pane and report the still-not-enabled state.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(!enabled, forKey: userDisabledKey)
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("[Forge] LaunchAtLogin.setEnabled(\(enabled)) failed: \(error.localizedDescription)")
            return isEnabled
        }

        if enabled && SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        return isEnabled
    }

    /// Applies the default-on policy at startup: unless the user has
    /// explicitly opted out, make sure Forge is registered as a login
    /// item. Because it re-registers the CURRENT bundle whenever it isn't
    /// already enabled, it also self-heals if the app moved (e.g. from a
    /// dev build to /Applications) — the stale path is replaced with the
    /// running one. No-op once the user disables it.
    static func applyDefaultPolicy() {
        let userOptedOut = UserDefaults.standard.bool(forKey: userDisabledKey)
        guard !userOptedOut else { return }
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            NSLog("[Forge] LaunchAtLogin: registered by default-on policy")
        } catch {
            NSLog("[Forge] LaunchAtLogin default-on register failed: \(error.localizedDescription)")
        }
    }
}

import Foundation
import ServiceManagement
import AppKit

/// Launch-at-login control backed by `SMAppService` (macOS 13+).
///
/// Registers the MAIN app bundle as a login item — no separate helper
/// bundle or privileged daemon required. The enabled state is owned by
/// the system (queried via `SMAppService.mainApp.status`), NOT persisted
/// in Forge's JSON, so the toggle stays correct even if the user changes
/// it directly in System Settings → General → Login Items.
///
/// Reliability note: `SMAppService` registration depends on a stable code
/// signature. Forge signs with the fixed "Forge Dev" certificate (see
/// project.yml / BUILD.md), so the login item survives rebuilds and
/// upgrades instead of being invalidated each time like an ad-hoc build.
enum LaunchAtLogin {

    /// Whether Forge is currently registered to open at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turn launch-at-login on or off.
    ///
    /// If the user previously disabled Forge in System Settings → Login
    /// Items, a re-enable can land in `.requiresApproval`; in that case we
    /// open that settings pane so they can flip it back on. Returns the
    /// resulting enabled state so callers (e.g. the Settings toggle) can
    /// reflect reality if the operation didn't fully succeed.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
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
}

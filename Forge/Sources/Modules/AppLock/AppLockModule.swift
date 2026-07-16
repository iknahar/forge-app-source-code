import SwiftUI
import AppKit
import Combine
import CryptoKit

// MARK: - Types

/// One selected app. No PIN here — the PIN is global.
struct AppLockSelection: Codable, Identifiable, Hashable {
    var bundleId: String
    var displayName: String
    var id: String { bundleId }
}

// MARK: - Persisted config

private struct AppLockConfig: Codable {
    var selections: [AppLockSelection] = []
    var pinHash: String = ""
    var pinSalt: String = ""
}

// MARK: - Module

/// Selectively locks apps with a single global PIN. Locked apps keep
/// running in the background — Slack still receives DMs, badges still
/// bump, notifications still fire — but any window belonging to a
/// locked app gets covered by a full-screen PIN prompt the moment
/// it becomes active. This is intentionally weaker than a SIGSTOP:
/// the user wanted background delivery preserved.
///
/// Locking model:
///   • `isEnabled == true` — module is *locked*. Every selected app
///     shows the overlay on activation.
///   • `isEnabled == false` — module is *unlocked*. Nothing is
///     intercepted.
///
/// The user drives the transition through three interchangeable
/// entry points (Tools popover toggle, Settings arm card toggle,
/// global shortcut). All of them route through:
///   • `armForLock()` — locks immediately (unlocked → locked).
///   • `requestUnlock()` — pops a floating PIN window; correct PIN
///     flips to unlocked.
final class AppLockModule: ForgeModule, ObservableObject {

    let id          = "appLock"
    let name        = "Lock selected apps"
    let description = "Freeze Slack, Chrome, etc. behind a PIN while notifications keep flowing in the background"
    let iconName    = "lock.app.dashed"
    let category: ModuleCategory = .system
    var isEnabled: Bool = false

    // MARK: - Published

    @Published private(set) var selections: [AppLockSelection] = []
    /// bundleId → currently painted with a lock overlay. UI reads
    /// this to show a "LOCKED" chip per row.
    @Published private(set) var activeLocks: Set<String> = []
    @Published private(set) var hasPIN: Bool = false
    /// Session-lifetime gate for the Settings → App Lock section.
    /// Any modification (add app, remove app, change PIN, toggle
    /// selection state) requires the user to punch the PIN in first
    /// on this Forge run. Reset every launch, never persisted — a
    /// fresh session always re-prompts.
    @Published var settingsSessionUnlocked: Bool = false

    // MARK: - Internals

    private var pinHash: String = ""
    private var pinSalt: String = ""

    private var activationObserver: NSObjectProtocol?
    /// Consumes Cmd+Q / Cmd+W / Cmd+H while a lock overlay is the
    /// key window. Without this, Cmd+Q quits Forge itself → every
    /// overlay window is destroyed → locked apps become visible
    /// without a PIN. With this, those shortcuts terminate the
    /// locked app instead (which then re-locks itself on next
    /// launch via the activation observer).
    private var quitEventMonitor: Any?
    /// Per-app blocking overlays. One entry per app that's currently
    /// covered by a PIN prompt on screen.
    private var overlayWindows: [String: NSWindow] = [:]
    /// The floating unlock window that pops when the user triggers
    /// disarm without a specific app in focus. Separate from
    /// `overlayWindows` because it isn't tied to any bundleId.
    private var unlockWindow: NSWindow?

    /// Set by AppDelegate right after registration. Used so
    /// `armForLock()` and `finishDisarm()` can drive the same
    /// activate / deactivate + persistence path that a user-driven
    /// toggle does — without duplicating the bookkeeping.
    weak var registryRef: ModuleRegistry?

    private static let configURL: URL = {
        let support = (FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("app_lock.json")
    }()

    // MARK: - Init

    init() {
        let cfg = Self.loadConfig()
        self.selections = cfg.selections
        self.pinHash = cfg.pinHash
        self.pinSalt = cfg.pinSalt
        self.hasPIN = !cfg.pinHash.isEmpty
    }

    // MARK: - ForgeModule

    /// Called when the registry flips `isEnabled` to true. We refuse
    /// to lock without both a PIN and at least one selection —
    /// otherwise the user would end up in a locked state they
    /// couldn't clear. Guard is defensive; the UI blocks the same
    /// path.
    func activate() {
        guard hasPIN, !selections.isEmpty else {
            isEnabled = false
            return
        }
        subscribeToAppEvents()
        installQuitEventMonitor()
        // If a selected app is currently frontmost at lock time,
        // cover it now — otherwise the just-locked app would stay
        // fully visible until the user Cmd+Tabs away and back.
        // Dismiss-on-switch handles the "user goes to another app"
        // case, so this doesn't lock the user out of the machine.
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier,
           let sel = selections.first(where: { $0.bundleId == bid }) {
            presentOverlay(for: sel)
        }
    }

    func deactivate() {
        unsubscribeFromAppEvents()
        removeQuitEventMonitor()
        for (_, w) in overlayWindows { w.orderOut(nil) }
        overlayWindows.removeAll()
        activeLocks.removeAll()
        dismissUnlockWindow()
    }

    // MARK: - Public API — arm / disarm

    /// Toggle-on / shortcut-when-unlocked path. Direct arm, no
    /// confirmation needed (nothing is locked yet, so this can't
    /// hurt).
    func armForLock() {
        guard hasPIN, !selections.isEmpty else { return }
        guard !isEnabled, let reg = registryRef else { return }
        reg.toggleModule(id)   // sets isEnabled=true → activate()
    }

    /// Toggle-off / shortcut-when-locked path. Pops the floating
    /// unlock window. Correct PIN in there calls `finishDisarm()`.
    /// If already unlocked, this is a no-op.
    func requestUnlock() {
        guard isEnabled else { return }
        presentUnlockWindow()
    }

    /// Called by the unlock window after a correct PIN verify. Flips
    /// the module off through the registry so state persists.
    private func finishDisarm() {
        guard isEnabled, let reg = registryRef else { return }
        reg.toggleModule(id)   // sets isEnabled=false → deactivate()
    }

    /// The one shortcut the user binds — Ctrl-Alt-L by default.
    /// Same key does both jobs: lock when unlocked, request unlock
    /// when locked. Toggle-like but PIN-gated on the disarm half.
    func toggleFromShortcut() {
        if isEnabled { requestUnlock() }
        else         { armForLock() }
    }

    // MARK: - Selection list

    func addSelection(bundleId: String, displayName: String) {
        guard !bundleId.isEmpty else { return }
        guard !selections.contains(where: { $0.bundleId == bundleId }) else { return }
        selections.append(AppLockSelection(bundleId: bundleId, displayName: displayName))
        persist()
        // Cover the app right now if it's running while we're armed.
        if isEnabled,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty,
           let sel = selections.first(where: { $0.bundleId == bundleId }) {
            presentOverlay(for: sel)
        }
    }

    /// Removing a selection while armed — release its overlay
    /// immediately. Doesn't touch the module's arm state.
    func removeSelection(bundleId: String) {
        dismissOverlay(bundleId: bundleId)
        selections.removeAll { $0.bundleId == bundleId }
        persist()
    }

    // MARK: - PIN

    /// First-time PIN setup only. Refuses to overwrite an existing
    /// PIN — the Change-PIN flow (which requires the old PIN) is the
    /// only way to rotate once a PIN exists.
    func setPIN(_ pin: String) {
        guard pin.count >= 4 else { return }
        guard !hasPIN else { return }
        pinSalt = Self.randomSaltHex()
        pinHash = Self.hash(pin: pin, saltHex: pinSalt)
        hasPIN = true
        persist()
    }

    /// Rotate an existing PIN. Requires the old PIN to succeed —
    /// without this, anyone with access to the settings window
    /// could silently replace the PIN and lock the user out (or
    /// bypass their intent). Returns false on wrong old PIN or too-
    /// short new PIN; caller surfaces the error.
    @discardableResult
    func changePIN(oldPIN: String, newPIN: String) -> Bool {
        guard hasPIN, newPIN.count >= 4 else { return false }
        guard checkPIN(oldPIN) else { return false }
        pinSalt = Self.randomSaltHex()
        pinHash = Self.hash(pin: newPIN, saltHex: pinSalt)
        persist()
        return true
    }

    /// Constant-time compare against the stored PIN hash. Side-effect
    /// free — the caller decides what to do on success. The PIN
    /// space is 10^4 so an early-out mismatch would leak digit-by-
    /// digit correctness via timing.
    func checkPIN(_ pin: String) -> Bool {
        guard !pinHash.isEmpty else { return false }
        let candidate = Self.hash(pin: pin, saltHex: pinSalt)
        guard candidate.count == pinHash.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(candidate.utf8, pinHash.utf8) { diff |= a ^ b }
        return diff == 0
    }

    /// Called from both the per-app overlay and the floating unlock
    /// window. On success, disarms the module entirely — every
    /// locked app comes back at once.
    @discardableResult
    func verify(pin: String) -> Bool {
        guard checkPIN(pin) else { return false }
        dismissUnlockWindow()
        finishDisarm()
        return true
    }

    // MARK: - App activation

    private func subscribeToAppEvents() {
        let nc = NSWorkspace.shared.notificationCenter
        activationObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let bid = app.bundleIdentifier
            // Own app activating? Ignore — otherwise pulling the
            // Forge menu bar down while locked would dismiss the
            // overlay covering the locked app.
            if bid == Bundle.main.bundleIdentifier { return }
            if let bid = bid, let sel = self.selections.first(where: { $0.bundleId == bid }) {
                // Locked app came to front → cover it.
                self.presentOverlay(for: sel)
            } else {
                // Switched to a non-locked app. Take the overlay
                // down so this app is actually usable — otherwise
                // the screensaver-level window would keep sitting
                // on top of the new frontmost app.
                self.dismissAllAppOverlays()
            }
        }
    }

    /// Tears down every per-app overlay (not the floating unlock
    /// window — that has its own dismissal path). Called when the
    /// user switches to any app that isn't in the locked list.
    private func dismissAllAppOverlays() {
        for (_, w) in overlayWindows { w.orderOut(nil) }
        overlayWindows.removeAll()
        activeLocks.removeAll()
    }

    // MARK: - Quit interception

    /// Cmd+Q while an overlay is key would quit Forge itself,
    /// silently dropping every lock. We install a local keyDown
    /// monitor while armed that catches those quit-adjacent
    /// shortcuts (Cmd+Q / Cmd+W / Cmd+H) and reroutes them to
    /// terminate the locked app instead — Slack's own Cmd+Q is
    /// the natural "get out of here" action, and it re-locks
    /// itself on next launch via the activation observer.
    ///
    /// Only intercepts when one of our lock windows actually holds
    /// key focus, so hitting Cmd+Q in the Forge Settings window
    /// still quits Forge normally.
    private func installQuitEventMonitor() {
        removeQuitEventMonitor()
        quitEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            let ourLockWindowIsKey =
                self.overlayWindows.values.contains(where: { $0.isKeyWindow })
                || self.unlockWindow?.isKeyWindow == true
            guard ourLockWindowIsKey else { return event }

            let cmd = event.modifierFlags.contains(.command)
            guard cmd else { return event }

            // 12 = Q, 13 = W, 4 = H. All three would either quit
            // Forge or hide it (which visually tears the overlay).
            switch event.keyCode {
            case 12, 13, 4:
                self.handleQuitAttempt()
                return nil   // consume
            default:
                return event
            }
        }
    }

    private func removeQuitEventMonitor() {
        if let m = quitEventMonitor { NSEvent.removeMonitor(m) }
        quitEventMonitor = nil
    }

    /// Fired when the user tries Cmd+Q/W/H over a lock overlay.
    ///   • If a per-app overlay owns key: terminate that app,
    ///     dismiss its overlay. Locked app is now truly gone, not
    ///     silently unlocked.
    ///   • If only the floating unlock window is key: dismiss it.
    ///     Module stays armed; user can bring the prompt back with
    ///     the ⌘L shortcut.
    private func handleQuitAttempt() {
        // Prefer whichever overlay is currently key.
        for (bid, window) in overlayWindows where window.isKeyWindow {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                app.terminate()
            }
            dismissOverlay(bundleId: bid)
            return
        }
        if unlockWindow?.isKeyWindow == true {
            dismissUnlockWindow()
            return
        }
    }

    private func unsubscribeFromAppEvents() {
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        activationObserver = nil
    }

    // MARK: - Per-app blocking overlay

    private func presentOverlay(for sel: AppLockSelection) {
        if let existing = overlayWindows[sel.bundleId] {
            existing.orderFrontRegardless()
            return
        }
        guard let screen = NSScreen.main else { return }
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // `.modalPanel` (8) sits above every normal app window but
        // below the system menu bar (24) and dock (~20). Keeps the
        // locked app covered while leaving system UI reachable so
        // the user can Cmd+Tab, click other Dock icons, or hide
        // the app from the Dock right-click menu.
        window.level = .modalPanel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.ignoresMouseEvents = false
        let host = NSHostingView(rootView: AppLockOverlayView(
            module: self,
            title: sel.displayName,
            onSuccess: { [weak self] in self?.dismissOverlay(bundleId: sel.bundleId) },
            onMinimize: { [weak self] in
                // hide() removes the app's windows from screen
                // without quitting it. Notifications keep firing.
                // Also drop the overlay explicitly — hide() doesn't
                // reliably produce a `didActivate` notif for
                // whoever becomes frontmost, so we can't rely on
                // the observer path to tear it down.
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: sel.bundleId).first {
                    app.hide()
                }
                self?.dismissOverlay(bundleId: sel.bundleId)
            }
        ))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        overlayWindows[sel.bundleId] = window
        activeLocks.insert(sel.bundleId)
    }

    func dismissOverlay(bundleId: String) {
        overlayWindows[bundleId]?.orderOut(nil)
        overlayWindows.removeValue(forKey: bundleId)
        activeLocks.remove(bundleId)
    }

    // MARK: - Floating unlock window

    private func presentUnlockWindow() {
        if let existing = unlockWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let screen = NSScreen.main else { return }
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // `.modalPanel` (8) sits above every normal app window but
        // below the system menu bar (24) and dock (~20). Keeps the
        // locked app covered while leaving system UI reachable so
        // the user can Cmd+Tab, click other Dock icons, or hide
        // the app from the Dock right-click menu.
        window.level = .modalPanel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.ignoresMouseEvents = false
        let host = NSHostingView(rootView: AppLockOverlayView(
            module: self,
            title: "Locked",
            onSuccess: { /* verify() already tears everything down */ },
            onMinimize: nil   // no specific target app to hide
        ))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        unlockWindow = window
    }

    func dismissUnlockWindow() {
        unlockWindow?.orderOut(nil)
        unlockWindow = nil
    }

    // MARK: - Persistence

    private static func loadConfig() -> AppLockConfig {
        guard
            let data = try? Data(contentsOf: configURL),
            let decoded = try? JSONDecoder().decode(AppLockConfig.self, from: data)
        else { return AppLockConfig() }
        return decoded
    }

    private func persist() {
        let cfg = AppLockConfig(
            selections: selections,
            pinHash: pinHash,
            pinSalt: pinSalt
        )
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: Self.configURL)
        }
    }

    private static func hash(pin: String, saltHex: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(saltHex.utf8))
        hasher.update(data: Data(pin.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func randomSaltHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Installed-app discovery

struct InstalledApp: Identifiable, Hashable {
    let bundleId: String
    let name: String
    let url: URL
    var id: String { bundleId }
}

extension AppLockModule {
    static func discoverInstalledApps() -> [InstalledApp] {
        let fm = FileManager.default
        let roots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]
        var seen = Set<String>()
        var out: [InstalledApp] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in items where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let bid = bundle.bundleIdentifier,
                      !seen.contains(bid) else { continue }
                seen.insert(bid)
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                out.append(InstalledApp(bundleId: bid, name: name, url: url))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

import SwiftUI
import AppKit
import Combine
import LocalAuthentication

// MARK: - Types

/// One selected app. No credential state — auth is delegated
/// entirely to macOS (`.deviceOwnerAuthentication`).
struct AppLockSelection: Codable, Identifiable, Hashable {
    var bundleId: String
    var displayName: String
    var id: String { bundleId }
}

// MARK: - Persisted config

private struct AppLockConfig: Codable {
    var selections: [AppLockSelection] = []
}

// MARK: - Module

/// Selectively locks apps behind a system biometric prompt. Locked
/// apps keep running in the background — Slack still receives DMs,
/// badges still bump, notifications still fire — but any window
/// belonging to a locked app gets covered by an overlay the moment
/// it becomes active. The user unlocks with Touch ID (or the macOS
/// password on Macs without a fingerprint reader — `LAContext`'s
/// `.deviceOwnerAuthentication` policy handles both).
///
/// Locking model:
///   • `isEnabled == true` — module is *locked*. Every selected app
///     shows the overlay on activation.
///   • `isEnabled == false` — module is *unlocked*. Nothing is
///     intercepted.
///
/// User entry points to the transition — Tools popover lock icon,
/// Settings arm toggle, ⌘L shortcut — all route through
/// `armForLock()` / `requestUnlock()`.
final class AppLockModule: ForgeModule, ObservableObject {

    let id          = "appLock"
    let name        = "Lock selected apps"
    let description = "Freeze Slack, Chrome, etc. behind Touch ID while notifications keep flowing in the background"
    let iconName    = "lock.app.dashed"
    let category: ModuleCategory = .system
    var isEnabled: Bool = false

    // MARK: - Published

    @Published private(set) var selections: [AppLockSelection] = []
    /// bundleId → currently painted with an overlay. UI reads this to
    /// show a "LOCKED" chip per row.
    @Published private(set) var activeLocks: Set<String> = []
    /// Session-lifetime gate for the Settings → App Lock section.
    /// Any modification (add app, remove app, toggle arm state)
    /// requires biometric verification once per Forge run. Reset
    /// every launch, never persisted.
    @Published var settingsSessionUnlocked: Bool = false

    // MARK: - Internals

    private var activationObserver: NSObjectProtocol?
    /// Consumes Cmd+Q / Cmd+W / Cmd+H while a lock overlay is the
    /// key window. Without this, Cmd+Q quits Forge itself → every
    /// overlay window is destroyed → locked apps become visible.
    /// With this, those shortcuts terminate the locked app instead.
    private var quitEventMonitor: Any?
    /// Per-app blocking overlays.
    private var overlayWindows: [String: NSWindow] = [:]
    /// Floating unlock window (triggered by ⌘L when no locked app
    /// is frontmost).
    private var unlockWindow: NSWindow?
    /// Prevents multiple concurrent quit-attempt paths from spawning
    /// duplicate prompts.
    private var quitAuthInFlight = false
    /// Floats a lock chip over each locked app's Dock icon while
    /// armed, so the locked state is visible at a glance without
    /// having to activate the app.
    private let dockBadges = DockLockBadgeController()

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
    }

    // MARK: - ForgeModule

    func activate() {
        guard !selections.isEmpty else {
            // No apps to lock — silently stay off.
            isEnabled = false
            return
        }
        subscribeToAppEvents()
        installQuitEventMonitor()
        dockBadges.start(bundleIds: selections.map { $0.bundleId })
        // If a selected app is currently frontmost at lock time,
        // cover it now — otherwise the just-locked app would stay
        // fully visible until the user Cmd+Tabs away and back.
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier,
           let sel = selections.first(where: { $0.bundleId == bid }) {
            presentOverlay(for: sel)
        }
    }

    func deactivate() {
        unsubscribeFromAppEvents()
        removeQuitEventMonitor()
        dockBadges.stop()
        for (_, w) in overlayWindows { w.orderOut(nil) }
        overlayWindows.removeAll()
        activeLocks.removeAll()
        dismissUnlockWindow()
    }

    // MARK: - Selections

    func addSelection(bundleId: String, displayName: String) {
        guard !bundleId.isEmpty else { return }
        guard !selections.contains(where: { $0.bundleId == bundleId }) else { return }
        selections.append(AppLockSelection(bundleId: bundleId, displayName: displayName))
        persist()
        if isEnabled {
            dockBadges.start(bundleIds: selections.map { $0.bundleId })
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty,
               let sel = selections.first(where: { $0.bundleId == bundleId }) {
                presentOverlay(for: sel)
            }
        }
    }

    func removeSelection(bundleId: String) {
        dismissOverlay(bundleId: bundleId)
        selections.removeAll { $0.bundleId == bundleId }
        persist()
        if isEnabled {
            dockBadges.start(bundleIds: selections.map { $0.bundleId })
        }
    }

    // MARK: - Arm / disarm

    func armForLock() {
        guard !selections.isEmpty else { return }
        guard !isEnabled, let reg = registryRef else { return }
        reg.toggleModule(id)
    }

    /// Unlock path. Fires the system biometric prompt immediately
    /// (falls back to macOS password if Touch ID isn't enrolled).
    /// Success disarms the module through the registry.
    func requestUnlock() {
        guard isEnabled else { return }
        authenticate(reason: "Unlock apps") { [weak self] ok in
            guard ok, let self = self else { return }
            self.dismissUnlockWindow()
            self.finishDisarm()
        }
    }

    /// Present the floating unlock overlay. Used by the ⌘L shortcut
    /// when no locked app is currently frontmost — gives the user
    /// somewhere to focus while macOS's own biometric prompt sits
    /// on top of it.
    func presentUnlockOverlayAndAuthenticate() {
        guard isEnabled else { return }
        presentUnlockWindow()
        authenticate(reason: "Unlock apps") { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.dismissUnlockWindow()
                self.finishDisarm()
            }
            // On fail/cancel, the unlock window stays up — the user
            // taps the fingerprint icon inside it to retry.
        }
    }

    private func finishDisarm() {
        guard isEnabled, let reg = registryRef else { return }
        reg.toggleModule(id)
    }

    /// One shortcut for both directions. Locks if unlocked, prompts
    /// for biometrics if locked.
    func toggleFromShortcut() {
        if isEnabled { presentUnlockOverlayAndAuthenticate() }
        else         { armForLock() }
    }

    // MARK: - Authentication

    /// Fires the system `LAContext` prompt. On Touch ID Macs the
    /// user sees the fingerprint sensor prompt; on Macs without a
    /// sensor, macOS falls back to the standard password entry
    /// (both cases handled by `.deviceOwnerAuthentication`).
    /// Completion always runs on the main queue.
    func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        // Fresh context per call — reusing caches the previous
        // result and can silently skip the prompt.
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &error
        ) else {
            completion(false); return
        }
        ctx.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        ) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// UI convenience — every host machine can authenticate somehow
    /// (Touch ID, watch, password), so we always render the auth
    /// widget. Kept as a computed for future hardware gating.
    var authenticationAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &error
        )
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
            if bid == Bundle.main.bundleIdentifier { return }
            if let bid = bid, let sel = self.selections.first(where: { $0.bundleId == bid }) {
                self.presentOverlay(for: sel)
            } else {
                self.dismissAllAppOverlays()
            }
        }
    }

    private func unsubscribeFromAppEvents() {
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        activationObserver = nil
    }

    private func dismissAllAppOverlays() {
        for (_, w) in overlayWindows { w.orderOut(nil) }
        overlayWindows.removeAll()
        activeLocks.removeAll()
    }

    // MARK: - Quit interception

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

            switch event.keyCode {
            case 12, 13, 4:
                self.handleQuitAttempt()
                return nil
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
    /// Terminates the locked app instead of quitting Forge.
    private func handleQuitAttempt() {
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

    // MARK: - Quit confirmation (Forge)

    /// Whether AppDelegate should block Cmd+Q / Quit-Forge. True
    /// while the module is armed — otherwise quitting silently
    /// tears down every lock and exposes the locked apps.
    var shouldBlockQuit: Bool { isEnabled }

    /// Ask macOS to authenticate the user before quitting Forge.
    /// No custom UI — just the native biometric / password prompt.
    /// `completion(true)` = allow terminate, `completion(false)` =
    /// cancel terminate.
    func requestQuitConfirmation(completion: @escaping (Bool) -> Void) {
        if quitAuthInFlight {
            // A second quit request while the first is still
            // asking. Second-in-line just gets a no.
            completion(false)
            return
        }
        quitAuthInFlight = true
        authenticate(reason: "Quit Forge") { [weak self] ok in
            self?.quitAuthInFlight = false
            completion(ok)
        }
    }

    // MARK: - Overlay windows

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
        // below the system menu bar (24) and dock (~20). System UI
        // stays reachable while the locked app stays covered.
        window.level = .modalPanel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.ignoresMouseEvents = false
        let host = NSHostingView(rootView: AppLockOverlayView(
            module: self,
            title: sel.displayName,
            authenticate: { [weak self] done in
                self?.authenticate(reason: "Unlock \(sel.displayName)") { ok in
                    if ok {
                        self?.dismissOverlay(bundleId: sel.bundleId)
                        self?.finishDisarm()
                    }
                    done(ok)
                }
            },
            onMinimize: { [weak self] in
                // hide() removes windows from screen but keeps the
                // process running so DMs / badges keep flowing.
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
        window.level = .modalPanel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.ignoresMouseEvents = false
        let host = NSHostingView(rootView: AppLockOverlayView(
            module: self,
            title: "Locked",
            authenticate: { [weak self] done in
                self?.authenticate(reason: "Unlock apps") { ok in
                    if ok {
                        self?.dismissUnlockWindow()
                        self?.finishDisarm()
                    }
                    done(ok)
                }
            },
            onMinimize: nil
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
        let cfg = AppLockConfig(selections: selections)
        if let data = try? JSONEncoder().encode(cfg) {
            try? data.write(to: Self.configURL)
        }
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

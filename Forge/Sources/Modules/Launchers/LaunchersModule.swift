import SwiftUI
import AppKit

// MARK: - Supporting Types

/// What kind of target a `Launcher` points at. Drives the file
/// picker, validation, and the eventual "fire" call.
enum LauncherKind: String, Codable, CaseIterable, Identifiable {
    case app      = "Application"
    case file     = "Document / File"
    case url      = "URL"
    var id: String { rawValue }

    /// SF Symbol used as the row's leading icon in the launcher list.
    var iconName: String {
        switch self {
        case .app:  return "app.fill"
        case .file: return "doc.fill"
        case .url:  return "globe"
        }
    }
}

/// One user-defined shortcut. `target` is interpreted based on
/// `kind`:
///   • `.app`  → absolute path to an `.app` bundle (e.g.
///              `/Applications/Slack.app`)
///   • `.file` → absolute path to any document, opened with its
///              default app via `NSWorkspace`
///   • `.url`  → any URL string (`https://`, `mailto:`, `obsidian://`,
///              etc.), opened with the system handler
struct Launcher: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var kind: LauncherKind
    var target: String
    var shortcut: ShortcutBinding?
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        kind: LauncherKind,
        target: String,
        shortcut: ShortcutBinding? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.target = target
        self.shortcut = shortcut
        self.enabled = enabled
    }
}

// MARK: - Module

/// Launchers — bind a global keyboard shortcut to one of three
/// actions:
///   1. Open an application.
///   2. Open a document / file with its default app.
///   3. Open a URL (http/https/mailto/custom scheme).
///
/// Each launcher carries its own optional `ShortcutBinding`, so the
/// user can have any number of these. The module re-registers all
/// hotkeys whenever the list changes, which the Settings UI does
/// after every add / edit / delete.
final class LaunchersModule: ForgeModule, ObservableObject {

    let id          = "launchers"
    let name        = "Launchers"
    let description = "Bind a shortcut to open any app, file, or URL"
    let iconName    = "bolt.fill"
    let category: ModuleCategory = .launcher
    var isEnabled: Bool = true

    // MARK: - State

    /// The persisted list of launchers. Any mutation triggers a
    /// re-persist + a re-registration of the hotkey table.
    @Published var launchers: [Launcher] = [] {
        didSet { persist(); reregisterHotkeys() }
    }

    /// Provided by `AppDelegate` after registration so the module
    /// can install / tear down global hotkeys directly. Weak so we
    /// don't form a cycle through the delegate.
    weak var hotkeyManagerRef: HotkeyManager?

    /// IDs we've currently registered with `HotkeyManager`. Tracked
    /// so `reregisterHotkeys()` can cleanly unregister the old set
    /// before installing the new one.
    private var registeredHotkeyIds: Set<String> = []

    // MARK: - Persistence path

    private let storeURL: URL = {
        let support = (FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("launchers.json")
    }()

    init() {
        self.launchers = Self.load(from: Self.storeURL)
    }

    private static let storeURL: URL = {
        let support = (FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("launchers.json")
    }()

    // MARK: - ForgeModule

    func activate() {
        reregisterHotkeys()
    }

    func deactivate() {
        unregisterAllHotkeys()
    }

    // MARK: - CRUD helpers

    func addLauncher(_ launcher: Launcher) {
        launchers.append(launcher)
    }

    func removeLauncher(_ id: UUID) {
        launchers.removeAll { $0.id == id }
    }

    func updateLauncher(_ updated: Launcher) {
        guard let idx = launchers.firstIndex(where: { $0.id == updated.id }) else { return }
        launchers[idx] = updated
    }

    func toggleEnabled(_ id: UUID) {
        guard let idx = launchers.firstIndex(where: { $0.id == id }) else { return }
        launchers[idx].enabled.toggle()
    }

    // MARK: - Firing

    /// Run a launcher's primary action. Routed through
    /// `NSWorkspace`, which handles every kind we care about: app
    /// launches, document opens (with the default app), URL handlers
    /// (http/https/mailto/custom schemes). All paths return quickly
    /// — `NSWorkspace.open` is fire-and-forget.
    func fire(_ launcher: Launcher) {
        switch launcher.kind {
        case .app, .file:
            // Both forms resolve to a file URL on disk. For .app
            // it's the bundle path; for .file it's the document.
            // `NSWorkspace.open(URL)` will handle both correctly —
            // it knows to launch the bundle in the .app case and
            // route to the default opener in the .file case.
            let url = URL(fileURLWithPath: launcher.target)
            NSWorkspace.shared.open(url)
        case .url:
            let raw = launcher.target.trimmingCharacters(in: .whitespacesAndNewlines)
            // If the user typed `github.com` we prepend `https://`
            // so they don't have to. Anything with a scheme is
            // passed through as-is.
            let candidate: String
            if raw.contains("://") {
                candidate = raw
            } else if raw.hasPrefix("mailto:") {
                candidate = raw
            } else {
                candidate = "https://" + raw
            }
            if let url = URL(string: candidate) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Hotkey wiring

    /// Wipe the previous round of registrations and install fresh
    /// ones for every enabled launcher that carries a shortcut.
    /// Called on init/activate and after every mutation of
    /// `launchers`.
    private func reregisterHotkeys() {
        guard let mgr = hotkeyManagerRef else { return }
        unregisterAllHotkeys()
        for launcher in launchers where launcher.enabled {
            guard let binding = launcher.shortcut else { continue }
            let hotkeyId = "launcher.\(launcher.id.uuidString)"
            mgr.register(
                keyCode: binding.keyCode,
                modifiers: binding.nsModifiers,
                id: hotkeyId,
                handler: { [weak self] in self?.fire(launcher) }
            )
            registeredHotkeyIds.insert(hotkeyId)
        }
    }

    private func unregisterAllHotkeys() {
        guard let mgr = hotkeyManagerRef else { return }
        for id in registeredHotkeyIds {
            mgr.unregister(id: id)
        }
        registeredHotkeyIds.removeAll()
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [Launcher] {
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([Launcher].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(launchers) {
            try? data.write(to: storeURL)
        }
    }
}

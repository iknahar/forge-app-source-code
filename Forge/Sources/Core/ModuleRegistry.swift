import SwiftUI
import Combine

/// Central registry for all Forge modules.
/// Manages module lifecycle, enables lazy activation, and exposes module state to SwiftUI.
final class ModuleRegistry: ObservableObject {

    // MARK: - Published State

    @Published private(set) var modules: [any ForgeModule] = []
    @Published var activeModuleId: String = "calendar"

    /// Source of truth for module enabled state. SwiftUI Toggles bind through
    /// `isEnabled(_:)` and `toggleModule(_:)` so views actually re-render on
    /// state changes (mutating a property on a class element of `modules`
    /// alone does NOT fire `@Published` invalidation).
    @Published private var enabledStates: [String: Bool] = [:]

    /// Set by `loadStates(from:)` and read by `toggleModule(_:)` to persist
    /// the flip immediately — without this, a Tools-toggle change lived only
    /// in-memory and got wiped on the next launch (`loadStates` overwrites
    /// `isEnabled` from `settings.moduleStates`, which the toggle never
    /// updated). Weak so the registry doesn't extend the settings manager's
    /// lifetime.
    private weak var settingsRef: SettingsManager?

    // MARK: - Registration

    func register(_ module: any ForgeModule) {
        guard !modules.contains(where: { $0.id == module.id }) else {
            print("[Forge] Module '\(module.id)' already registered, skipping.")
            return
        }
        modules.append(module)
        // Seed the published state from the module's initial flag.
        enabledStates[module.id] = module.isEnabled
        print("[Forge] Registered module: \(module.name)")
    }

    /// Public, observable enabled lookup. Falls back to the module's own
    /// `isEnabled` if there's no entry (e.g. before `register`).
    func isEnabled(_ id: String) -> Bool {
        if let v = enabledStates[id] { return v }
        return module(withId: id)?.isEnabled ?? false
    }

    // MARK: - Lookup

    func module(withId id: String) -> (any ForgeModule)? {
        modules.first { $0.id == id }
    }

    func module<T: ForgeModule>(ofType type: T.Type) -> T? {
        modules.compactMap { $0 as? T }.first
    }

    func modules(in category: ModuleCategory) -> [any ForgeModule] {
        modules.filter { $0.category == category }
    }

    // MARK: - Lifecycle

    func activateEnabledModules() {
        for module in modules where module.isEnabled {
            module.activate()
            print("[Forge] Activated: \(module.name)")
        }
    }

    func deactivateAllModules() {
        for module in modules {
            module.deactivate()
        }
        print("[Forge] All modules deactivated.")
    }

    func toggleModule(_ id: String) {
        guard let module = self.module(withId: id) else { return }
        let nowEnabled = !isEnabled(id)

        // Drive the @Published dictionary FIRST so the UI re-renders.
        enabledStates[id] = nowEnabled
        // Keep the module's own flag in sync (used by activateEnabledModules etc.)
        module.isEnabled = nowEnabled

        if nowEnabled {
            module.activate()
            print("[Forge] Enabled: \(module.name)")
        } else {
            module.deactivate()
            print("[Forge] Disabled: \(module.name)")
        }

        // Persist immediately. A module's `activate()` may self-abort
        // (e.g. AppLock refuses to arm without a PIN + selections and
        // resets `isEnabled` back to false) — re-sync `enabledStates`
        // to the module's actual flag before saving so what we
        // persist matches what the module actually did.
        if enabledStates[id] != module.isEnabled {
            enabledStates[id] = module.isEnabled
        }
        if let settings = settingsRef {
            saveStates(to: settings)
        }
    }

    // MARK: - State Persistence

    func loadStates(from settings: SettingsManager) {
        // Keep the ref for `toggleModule` to save through. Same
        // instance the AppDelegate creates once at launch, so no
        // risk of races.
        self.settingsRef = settings
        let states = settings.moduleStates
        for module in modules {
            if let saved = states[module.id] {
                module.isEnabled = saved
                enabledStates[module.id] = saved
            } else {
                enabledStates[module.id] = module.isEnabled
            }
        }
    }

    func saveStates(to settings: SettingsManager) {
        var states: [String: Bool] = [:]
        for module in modules {
            states[module.id] = module.isEnabled
        }
        settings.moduleStates = states
    }
}

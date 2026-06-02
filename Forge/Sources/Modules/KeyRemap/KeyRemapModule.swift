import SwiftUI
import AppKit

/// Key Remap — remap keys and shortcuts system-wide using CGEventTap.
/// Supports key-to-key remapping, shortcut remapping, and per-app profiles.
/// Requires Accessibility permission.
final class KeyRemapModule: ForgeModule, ObservableObject {
    let id = "keyRemap"
    let name = "Key Remap"
    let description = "Remap keys and shortcuts"
    let iconName = "keyboard"
    let category: ModuleCategory = .keyboard
    var isEnabled: Bool = true

    // MARK: - State

    @Published var isListening: Bool = false
    @Published var activeProfileId: String = "default"
    @Published var profiles: [RemapProfile] = [RemapProfile.defaultProfile]
    @Published var remappings: [KeyRemapping] = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Lifecycle

    func activate() {
        loadProfiles()
        applyActiveProfile()
        installEventTap()
    }

    func deactivate() {
        removeEventTap()
        saveProfiles()
    }

    // MARK: - Event Tap

    private func installEventTap() {
        guard eventTap == nil else { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        // Store self reference for the C callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let module = Unmanaged<KeyRemapModule>.fromOpaque(refcon).takeUnretainedValue()
                return module.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        )

        guard let tap = eventTap else {
            print("[Forge KeyRemap] Failed to create event tap. Accessibility permission required.")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[Forge KeyRemap] Event tap installed successfully")
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it was disabled by the system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Check for listening mode (capturing a key for the UI)
        if isListening {
            // Don't remap while user is choosing a key
            return Unmanaged.passRetained(event)
        }

        // Check if this key should be remapped
        let activeRemappings = remappingsForCurrentApp()

        for remap in activeRemappings where remap.isEnabled {
            // Check source key match
            if remap.sourceKeyCode == keyCode && modifiersMatch(remap.sourceModifiers, flags) {
                // Remap to target
                event.setIntegerValueField(.keyboardEventKeycode, value: Int64(remap.targetKeyCode))

                // Apply target modifiers if specified
                if !remap.targetModifiers.isEmpty {
                    var newFlags = flags
                    // Remove source modifiers
                    for mod in remap.sourceModifiers {
                        newFlags.remove(mod.cgEventFlag)
                    }
                    // Add target modifiers
                    for mod in remap.targetModifiers {
                        newFlags.insert(mod.cgEventFlag)
                    }
                    event.flags = newFlags
                }

                return Unmanaged.passRetained(event)
            }
        }

        return Unmanaged.passRetained(event)
    }

    private func modifiersMatch(_ required: [ModifierKey], _ actual: CGEventFlags) -> Bool {
        if required.isEmpty { return true }
        for mod in required {
            if !actual.contains(mod.cgEventFlag) {
                return false
            }
        }
        return true
    }

    private func remappingsForCurrentApp() -> [KeyRemapping] {
        // Get the frontmost application bundle identifier
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        return remappings.filter { remap in
            if remap.appBundleId == nil || remap.appBundleId == "*" {
                return true // Global remap
            }
            return remap.appBundleId == frontApp
        }
    }

    // MARK: - Profile Management

    private func applyActiveProfile() {
        guard let profile = profiles.first(where: { $0.id == activeProfileId }) else { return }
        remappings = profile.remappings
    }

    func addRemapping(_ remap: KeyRemapping) {
        remappings.append(remap)
        updateActiveProfile()
    }

    func removeRemapping(at index: Int) {
        guard remappings.indices.contains(index) else { return }
        remappings.remove(at: index)
        updateActiveProfile()
    }

    func toggleRemapping(at index: Int) {
        guard remappings.indices.contains(index) else { return }
        remappings[index].isEnabled.toggle()
        updateActiveProfile()
    }

    func createProfile(name: String) {
        let profile = RemapProfile(id: UUID().uuidString, name: name, remappings: [])
        profiles.append(profile)
        activeProfileId = profile.id
        remappings = []
        saveProfiles()
    }

    func switchProfile(id: String) {
        // Save current remappings to current profile first
        updateActiveProfile()
        activeProfileId = id
        applyActiveProfile()
    }

    private func updateActiveProfile() {
        if let index = profiles.firstIndex(where: { $0.id == activeProfileId }) {
            profiles[index].remappings = remappings
        }
        saveProfiles()
    }

    // MARK: - Key Listening

    func startListening() {
        isListening = true
    }

    func stopListening() {
        isListening = false
    }

    // MARK: - Persistence

    private var profilesURL: URL {
        let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("keyremap_profiles.json")
    }

    private func loadProfiles() {
        guard let data = try? Data(contentsOf: profilesURL),
              let saved = try? JSONDecoder().decode([RemapProfile].self, from: data) else {
            profiles = [RemapProfile.defaultProfile]
            return
        }
        profiles = saved
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: profilesURL)
        }
    }

    // MARK: - Commands

}

// MARK: - Data Models

struct KeyRemapping: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var sourceKeyCode: UInt16
    var sourceModifiers: [ModifierKey]
    var targetKeyCode: UInt16
    var targetModifiers: [ModifierKey]
    var appBundleId: String? // nil = global
    var isEnabled: Bool

    init(name: String, sourceKeyCode: UInt16, sourceModifiers: [ModifierKey] = [],
         targetKeyCode: UInt16, targetModifiers: [ModifierKey] = [],
         appBundleId: String? = nil) {
        self.id = UUID().uuidString
        self.name = name
        self.sourceKeyCode = sourceKeyCode
        self.sourceModifiers = sourceModifiers
        self.targetKeyCode = targetKeyCode
        self.targetModifiers = targetModifiers
        self.appBundleId = appBundleId
        self.isEnabled = true
    }

    var sourceDescription: String {
        let modStr = sourceModifiers.map(\.symbol).joined()
        return "\(modStr)\(KeyRemapping.keyName(for: sourceKeyCode))"
    }

    var targetDescription: String {
        let modStr = targetModifiers.map(\.symbol).joined()
        return "\(modStr)\(KeyRemapping.keyName(for: targetKeyCode))"
    }

    static func keyName(for keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "⏎",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 53: "⎋", 76: "⌅",
            115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            // Function keys
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
            97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12",
        ]
        return names[keyCode] ?? "Key\(keyCode)"
    }
}

enum ModifierKey: String, Codable, CaseIterable, Equatable {
    case command
    case option
    case control
    case shift
    case fn

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .fn: return "fn"
        }
    }

    var cgEventFlag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .shift: return .maskShift
        case .fn: return .maskSecondaryFn
        }
    }
}

struct RemapProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var remappings: [KeyRemapping]

    static let defaultProfile = RemapProfile(
        id: "default",
        name: "Default",
        remappings: []
    )
}

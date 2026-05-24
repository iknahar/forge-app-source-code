import AppKit
import Carbon

/// Manages global keyboard shortcuts using Carbon Hot Key API.
/// Each hotkey is registered system-wide and fires even when Forge is not focused.
final class HotkeyManager {

    // MARK: - Types

    private struct RegisteredHotkey {
        let id: String
        let eventHotKey: EventHotKeyRef
        let handler: () -> Void
    }

    // MARK: - Properties

    private var hotkeys: [UInt32: RegisteredHotkey] = [:]
    private var nextId: UInt32 = 1
    private var eventHandlerRef: EventHandlerRef?

    // MARK: - Init

    init() {
        installCarbonHandler()
    }

    deinit {
        unregisterAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    // MARK: - Public API

    func register(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        id: String,
        handler: @escaping () -> Void
    ) {
        let hotkeyId = nextId
        nextId += 1

        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        var hotKeyID = EventHotKeyID(
            signature: OSType(0x464F5247), // "FORG"
            id: hotkeyId
        )

        var eventHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &eventHotKey
        )

        guard status == noErr, let hotKey = eventHotKey else {
            print("[Forge] Failed to register hotkey '\(id)': \(status)")
            return
        }

        hotkeys[hotkeyId] = RegisteredHotkey(
            id: id,
            eventHotKey: hotKey,
            handler: handler
        )

        print("[Forge] Registered hotkey: \(id)")
    }

    /// Unregister a single hotkey by its string ID
    func unregister(id: String) {
        if let entry = hotkeys.first(where: { $0.value.id == id }) {
            UnregisterEventHotKey(entry.value.eventHotKey)
            hotkeys.removeValue(forKey: entry.key)
        }
    }

    /// Re-register a hotkey: unregisters the old one (if any) and registers the new combo
    func reregister(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        id: String,
        handler: @escaping () -> Void
    ) {
        unregister(id: id)
        register(keyCode: keyCode, modifiers: modifiers, id: id, handler: handler)
    }

    func unregisterAll() {
        for (_, hotkey) in hotkeys {
            UnregisterEventHotKey(hotkey.eventHotKey)
        }
        hotkeys.removeAll()
    }

    // MARK: - Carbon Event Handler

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr else { return OSStatus(eventNotHandledErr) }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            if let registered = manager.hotkeys[hotKeyID.id] {
                DispatchQueue.main.async {
                    registered.handler()
                }
                return noErr
            }

            return OSStatus(eventNotHandledErr)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }
}

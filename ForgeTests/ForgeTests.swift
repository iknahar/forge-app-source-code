import XCTest

final class ForgeTests: XCTestCase {

    // MARK: - Fuzzy Search Tests

    func testFuzzySearchExactMatch() {
        let commands = [
            makeCommand(id: "test", title: "Snap Left", keywords: ["snap", "left"]),
            makeCommand(id: "other", title: "Other Command", keywords: ["other"]),
        ]

        let results = FuzzySearch.filter(commands: commands, query: "snap left")
        XCTAssertEqual(results.first?.id, "test")
    }

    func testFuzzySearchPartialMatch() {
        let commands = [
            makeCommand(id: "snap", title: "Snap Left", keywords: ["snap", "left"]),
            makeCommand(id: "join", title: "Join Meeting", keywords: ["join", "meeting"]),
        ]

        let results = FuzzySearch.filter(commands: commands, query: "sn")
        XCTAssertTrue(results.contains(where: { $0.id == "snap" }))
    }

    func testFuzzySearchNoMatch() {
        let commands = [
            makeCommand(id: "test", title: "Snap Left", keywords: ["snap", "left"]),
        ]

        let results = FuzzySearch.filter(commands: commands, query: "xyz123")
        XCTAssertTrue(results.isEmpty)
    }

    func testFuzzySearchRanking() {
        let commands = [
            makeCommand(id: "settings", title: "Forge Settings", keywords: ["settings", "preferences"]),
            makeCommand(id: "set", title: "Set Timer", keywords: ["set", "timer"]),
        ]

        let results = FuzzySearch.filter(commands: commands, query: "set")
        // "Set Timer" should rank higher (exact word start match)
        XCTAssertEqual(results.first?.id, "set")
    }

    // MARK: - Module Registry Tests

    func testModuleRegistration() {
        let registry = ModuleRegistry()
        let module = MockModule(id: "test", name: "Test Module")

        registry.register(module)

        XCTAssertEqual(registry.modules.count, 1)
        XCTAssertNotNil(registry.module(withId: "test"))
    }

    func testModuleToggle() {
        let registry = ModuleRegistry()
        let module = MockModule(id: "test", name: "Test Module")
        module.isEnabled = true

        registry.register(module)
        registry.toggleModule("test")

        XCTAssertFalse(module.isEnabled)
    }

    func testDuplicateRegistration() {
        let registry = ModuleRegistry()
        let module1 = MockModule(id: "test", name: "Test 1")
        let module2 = MockModule(id: "test", name: "Test 2")

        registry.register(module1)
        registry.register(module2)

        XCTAssertEqual(registry.modules.count, 1) // Second should be skipped
    }

    func testMultipleModulesInCategory() {
        let registry = ModuleRegistry()
        let m1 = MockModule(id: "tool1", name: "Tool 1", category: .screen)
        let m2 = MockModule(id: "tool2", name: "Tool 2", category: .screen)
        let m3 = MockModule(id: "sys1", name: "System 1", category: .system)

        registry.register(m1)
        registry.register(m2)
        registry.register(m3)

        let screenTools = registry.modules(in: .screen)
        XCTAssertEqual(screenTools.count, 2)

        let systemTools = registry.modules(in: .system)
        XCTAssertEqual(systemTools.count, 1)
    }

    // MARK: - Zone Layout Tests (WindowManager)

    func testTwoColumnLayout() {
        let layout = ZoneLayout.twoColumn
        XCTAssertEqual(layout.zones.count, 2)

        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let leftZone = layout.zones[0].frame(in: screen)
        let rightZone = layout.zones[1].frame(in: screen)

        XCTAssertEqual(leftZone.width, 960)
        XCTAssertEqual(rightZone.width, 960)
        XCTAssertEqual(leftZone.origin.x, 0)
        XCTAssertEqual(rightZone.origin.x, 960)
    }

    func testThreeColumnLayout() {
        let layout = ZoneLayout.threeColumn
        XCTAssertEqual(layout.zones.count, 3)

        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let leftZone = layout.zones[0].frame(in: screen)
        let middleZone = layout.zones[1].frame(in: screen)
        let rightZone = layout.zones[2].frame(in: screen)

        // Each should be ~400px wide
        XCTAssertEqual(leftZone.width, 400, accuracy: 1)
        XCTAssertEqual(middleZone.width, 400, accuracy: 1)
        XCTAssertEqual(rightZone.width, 400, accuracy: 1)
    }

    func testFourQuadrantLayout() {
        let layout = ZoneLayout.fourQuadrant
        XCTAssertEqual(layout.zones.count, 4)

        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let topLeft = layout.zones[0].frame(in: screen)
        let topRight = layout.zones[1].frame(in: screen)

        XCTAssertEqual(topLeft.width, 960)
        XCTAssertEqual(topLeft.height, 540)
        XCTAssertEqual(topRight.origin.x, 960)
    }

    // MARK: - FancyZones ZoneRect Tests

    func testZoneRectProperties() {
        let zone = ZoneRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)

        XCTAssertEqual(zone.origin, CGPoint(x: 0.1, y: 0.2))
        XCTAssertEqual(zone.rect, CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
    }

    func testZoneRectCodable() throws {
        let original = ZoneRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ZoneRect.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    // MARK: - Meeting URL Extraction Tests

    func testZoomURLExtraction() {
        let event = CalendarEvent(
            title: "Test Meeting",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            meetingURL: URL(string: "https://zoom.us/j/123456")
        )

        XCTAssertTrue(event.hasMeetingLink)
        XCTAssertEqual(event.meetingService, "Zoom")
    }

    func testMeetURLDetection() {
        let event = CalendarEvent(
            title: "Standup",
            startDate: Date(),
            endDate: Date().addingTimeInterval(900),
            meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")
        )

        XCTAssertEqual(event.meetingService, "Meet")
    }

    func testTeamsURLDetection() {
        let event = CalendarEvent(
            title: "Review",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            meetingURL: URL(string: "https://teams.microsoft.com/l/meetup/123")
        )

        XCTAssertEqual(event.meetingService, "Teams")
    }

    func testNoMeetingURL() {
        let event = CalendarEvent(
            title: "Lunch",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3600),
            meetingURL: nil
        )

        XCTAssertFalse(event.hasMeetingLink)
        XCTAssertNil(event.meetingService)
    }

    // MARK: - Shortcut Binding Tests

    func testShortcutBindingDisplayString() {
        let binding = ShortcutBinding(keyCode: 8, modifiers: [.control, .option]) // ⌃⌥C
        XCTAssertEqual(binding.displayString, "⌃⌥C")
    }

    func testShortcutBindingCommandShift() {
        let binding = ShortcutBinding(keyCode: 49, modifiers: [.command, .shift]) // ⌘⇧Space
        XCTAssertEqual(binding.displayString, "⇧⌘Space")
    }

    func testShortcutBindingKeyName() {
        XCTAssertEqual(ShortcutBinding.keyName(for: 0), "A")
        XCTAssertEqual(ShortcutBinding.keyName(for: 49), "Space")
        XCTAssertEqual(ShortcutBinding.keyName(for: 36), "Return")
        XCTAssertEqual(ShortcutBinding.keyName(for: 53), "Esc")
        XCTAssertEqual(ShortcutBinding.keyName(for: 123), "←")
        XCTAssertEqual(ShortcutBinding.keyName(for: 126), "↑")
    }

    func testShortcutBindingUnknownKey() {
        let name = ShortcutBinding.keyName(for: 999)
        XCTAssertEqual(name, "Key999")
    }

    func testShortcutBindingCodable() throws {
        let original = ShortcutBinding(keyCode: 15, modifiers: [.control, .option])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)

        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.displayString, "⌃⌥R")
    }

    func testShortcutBindingDefaults() {
        // All default actions should have bindings
        XCTAssertFalse(ShortcutBinding.defaults.isEmpty)

        for action in ShortcutBinding.allActions {
            XCTAssertNotNil(ShortcutBinding.defaults[action.id],
                            "Missing default binding for \(action.id)")
        }
    }

    func testCodableModifiersPreservesFlags() {
        let flags: NSEvent.ModifierFlags = [.command, .option, .shift]
        let codable = CodableModifiers(flags: flags)

        XCTAssertTrue(codable.flags.contains(.command))
        XCTAssertTrue(codable.flags.contains(.option))
        XCTAssertTrue(codable.flags.contains(.shift))
        XCTAssertFalse(codable.flags.contains(.control))
    }

    func testCodableModifiersStripsNonModifiers() {
        // If we pass in capsLock or other non-standard flags, they should be stripped
        let flags: NSEvent.ModifierFlags = [.command, .capsLock]
        let codable = CodableModifiers(flags: flags)

        XCTAssertTrue(codable.flags.contains(.command))
        XCTAssertFalse(codable.flags.contains(.capsLock))
    }

    // MARK: - Settings Manager Tests

    func testSettingsManagerBindingLookup() {
        let manager = SettingsManager()

        let cpBinding = manager.binding(for: "colorPicker")
        XCTAssertEqual(cpBinding.keyCode, 8) // C key
        XCTAssertTrue(cpBinding.nsModifiers.contains(.control))
        XCTAssertTrue(cpBinding.nsModifiers.contains(.option))
    }

    func testSettingsManagerUpdateBinding() {
        let manager = SettingsManager()

        manager.updateBinding(for: "colorPicker", keyCode: 46, modifiers: [.command, .shift])

        let updated = manager.binding(for: "colorPicker")
        XCTAssertEqual(updated.keyCode, 46) // M key
        XCTAssertTrue(updated.nsModifiers.contains(.command))
    }

    func testSettingsManagerResetBinding() {
        let manager = SettingsManager()

        // Change it
        manager.updateBinding(for: "colorPicker", keyCode: 46, modifiers: [.command])

        // Reset it
        manager.resetBinding(for: "colorPicker")

        let reset = manager.binding(for: "colorPicker")
        XCTAssertEqual(reset.keyCode, 8) // Back to C
    }

    func testSettingsManagerResetAll() {
        let manager = SettingsManager()

        // Change multiple
        manager.updateBinding(for: "colorPicker", keyCode: 46, modifiers: [.command])
        manager.updateBinding(for: "zoomIt", keyCode: 0, modifiers: [.command])

        // Reset all
        manager.resetAllBindings()

        XCTAssertEqual(manager.binding(for: "colorPicker").keyCode, 8)
        XCTAssertEqual(manager.binding(for: "zoomIt").keyCode, 6)
    }

    func testSettingsManagerUnknownBinding() {
        let manager = SettingsManager()
        let binding = manager.binding(for: "nonexistent")
        XCTAssertEqual(binding.keyCode, 0) // Fallback
    }

    // MARK: - Helpers

    private func makeCommand(id: String, title: String, keywords: [String]) -> ForgeCommand {
        ForgeCommand(
            id: id,
            title: title,
            subtitle: nil,
            iconName: "star",
            moduleId: "test",
            action: {},
            keywords: keywords
        )
    }
}

// MARK: - Mock Module

final class MockModule: ForgeModule {
    let id: String
    let name: String
    let description: String = "Mock module for testing"
    let iconName: String = "star"
    let category: ModuleCategory
    var isEnabled: Bool = true

    init(id: String, name: String, category: ModuleCategory = .system) {
        self.id = id
        self.name = name
        self.category = category
    }

    func activate() {}
    func deactivate() {}
}

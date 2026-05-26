import SwiftUI
import Combine

/// Manages all Forge preferences. Stored as JSON in Application Support.
/// No CoreData, no CloudKit — just a readable JSON file.
final class SettingsManager: ObservableObject {

    // MARK: - Settings

    @Published var moduleStates: [String: Bool] = [:] {
        didSet { save() }
    }

    @Published var use24HourTime: Bool = false {
        didSet { save() }
    }

    @Published var theme: AppTheme = .system {
        didSet { save() }
    }

    /// Menu bar tokens shown next to the menu-bar icon. Defaults
    /// to Icon + Next Event — the most useful pair for the
    /// fresh-install experience: people see Forge's mark and the
    /// next meeting at a glance.
    @Published var menuBarTokens: [MenuBarToken] = [.icon, .nextEvent] {
        didSet { save() }
    }

    /// Date/time format string for the Time token (NSDateFormatter syntax).
    @Published var menuBarTimeFormat: String = "HH:mm" {
        didSet { save() }
    }

    /// Separator placed between menu bar tokens.
    @Published var menuBarSeparator: String = " · " {
        didSet { save() }
    }

    /// User-chosen emoji to use in place of the hammer icon in the
    /// menu bar and previews. Defaults to ⚡ on a fresh install —
    /// it reads punchier than the SF Symbol hammer at the small
    /// menu-bar size and ties into the brand's "fast tool" idiom.
    /// Empty string ⇒ fall back to the SF Symbol hammer.
    @Published var menuBarEmoji: String = "⚡" {
        didSet { save() }
    }

    /// Screenshot Translator — source language (auto-detect when empty).
    /// Stored as a BCP-47 code (e.g. "sv", "en", "es"). Defaults to
    /// Swedish per the brand's primary market.
    @Published var translateSourceLanguage: String = "sv" {
        didSet { save() }
    }

    /// Screenshot Translator — target language. BCP-47 code.
    @Published var translateTargetLanguage: String = "en" {
        didSet { save() }
    }

    @Published var meetingReminderMinutes: Int = 1 {
        didSet { save() }
    }

    @Published var meetingReminderStyle: ReminderStyle = .floating {
        didSet { save() }
    }

    /// Absolute path to a user-picked image used as the full-screen reminder
    /// wallpaper. Nil = use the default vector stripe background.
    @Published var reminderBackgroundImagePath: String? {
        didSet { save() }
    }

    @Published var windowSnapModifier: SnapModifier = .controlOption {
        didSet { save() }
    }

    // MARK: - Calendar Display

    @Published var showYearProgress: Bool = true       { didSet { save() } }
    @Published var showDayProgress: Bool = true        { didSet { save() } }
    @Published var showWorldClock: Bool = true         { didSet { save() } }
    @Published var showWeekNumbers: Bool = false       { didSet { save() } }
    @Published var highlightToday: Bool = true         { didSet { save() } }
    @Published var dimWeekends: Bool = true            { didSet { save() } }
    @Published var weekStartsOnMonday: Bool = true     { didSet { save() } }
    @Published var eventDotStyle: EventDotStyle = .multiple { didSet { save() } }
    @Published var calendarTextScale: Double = 1.0     { didSet { save() } }

    /// User's chosen world clock cities. Defaults to Local + Stockholm.
    @Published var worldClockCities: [WorldClockCity] = WorldClockCity.defaults {
        didSet { save() }
    }

    /// Calendars the user has explicitly linked to Forge (max 10).
    /// When non-empty, Forge only shows events from these calendars and uses
    /// the user-overridden name/color for each.
    @Published var linkedCalendars: [LinkedCalendar] = [] {
        didSet { save() }
    }

    static let maxLinkedCalendars = 10

    // MARK: - Shortcut Bindings (user-configurable)

    @Published var shortcutBindings: [String: ShortcutBinding] = ShortcutBinding.defaults {
        didSet { save() }
    }

    /// Per-action enable/disable state. Missing keys ⇒ enabled (the
    /// default for every action). Disabled actions are skipped during
    /// hotkey registration AND their gesture handlers refuse to fire.
    @Published var actionEnabled: [String: Bool] = [:] {
        didSet { save() }
    }

    /// Look up a binding by action ID, falling back to built-in default
    func binding(for actionId: String) -> ShortcutBinding {
        shortcutBindings[actionId] ?? ShortcutBinding.defaults[actionId] ?? ShortcutBinding(keyCode: 0, modifiers: [])
    }

    /// Update a single binding and persist
    func updateBinding(for actionId: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        shortcutBindings[actionId] = ShortcutBinding(keyCode: keyCode, modifiers: modifiers)
    }

    /// Reset a single binding back to factory default
    func resetBinding(for actionId: String) {
        shortcutBindings[actionId] = ShortcutBinding.defaults[actionId]
    }

    /// Reset all bindings to factory defaults
    func resetAllBindings() {
        shortcutBindings = ShortcutBinding.defaults
        actionEnabled = [:]
    }

    /// Is the action currently enabled? Missing entries default to true.
    func isActionEnabled(_ actionId: String) -> Bool {
        actionEnabled[actionId] ?? true
    }

    /// Flip the enable/disable flag and re-register hotkeys.
    func setActionEnabled(_ actionId: String, _ enabled: Bool) {
        actionEnabled[actionId] = enabled
    }

    // MARK: - Types

    enum AppTheme: String, Codable, CaseIterable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"

        /// SwiftUI ColorScheme; `nil` = inherit from system.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }
    }

    enum MenuBarToken: String, Codable, CaseIterable, Identifiable {
        case icon         = "Icon"
        case date         = "Date"
        case clock        = "Clock"          // rawValue kept stable for back-compat
        case ongoingMeeting = "Ongoing"      // currently-happening event (live)
        case nextEvent    = "Next Event"
        case countdown    = "Countdown"
        case weekNumber   = "Week"
        case dayProgress  = "Day Progress"
        case yearProgress = "Year Progress"
        case worldClock   = "World Clock"
        case timeLeft     = "Time Left"
        case eventsLeft   = "Events Left"
        case focusTime    = "Focus Time"

        var id: String { rawValue }

        /// User-facing chip label (lets us rename without breaking saved JSON).
        var displayName: String {
            switch self {
            case .clock:           return "Time"
            case .ongoingMeeting:  return "Ongoing"
            case .dayProgress:     return "Day %"
            case .yearProgress:    return "Year %"
            default:               return rawValue
            }
        }
    }

    enum ReminderStyle: String, Codable, CaseIterable {
        case floating = "Floating"
        case fullscreen = "Full Screen"
    }

    enum SnapModifier: String, Codable, CaseIterable {
        case controlOption = "⌃⌥"
        case commandOption = "⌘⌥"
    }

    enum EventDotStyle: String, Codable, CaseIterable {
        case none = "None"
        case single = "Single dot"
        case multiple = "Per event"
    }

    // MARK: - Persistence

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let forgeDir = appSupport.appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: forgeDir, withIntermediateDirectories: true)
        return forgeDir.appendingPathComponent("settings.json")
    }()

    init() {
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode(PersistedSettings.self, from: data) else { return }

        self.moduleStates = decoded.moduleStates
        self.use24HourTime = decoded.use24HourTime
        self.theme = decoded.theme
        self.menuBarTokens = decoded.menuBarTokens
        self.meetingReminderMinutes = decoded.meetingReminderMinutes
        self.meetingReminderStyle = decoded.meetingReminderStyle
        self.windowSnapModifier = decoded.windowSnapModifier
        if let bindings = decoded.shortcutBindings {
            // Merge saved bindings over defaults so new shortcuts get their defaults
            var merged = ShortcutBinding.defaults
            for (key, value) in bindings { merged[key] = value }

            // Migration: older Forge versions defaulted Clipboard
            // History to ⌃⌥V. The new default is ⌥V. If the user
            // still has the OLD default saved (i.e. they never
            // customized it), bump them to the new one. If they've
            // bound clipboard to something else, leave their choice
            // alone — only the legacy default gets migrated.
            let legacyClipboard = ShortcutBinding(
                keyCode: 9,
                modifiers: [.control, .option]
            )
            if merged["clipboard"] == legacyClipboard {
                merged["clipboard"] = ShortcutBinding(
                    keyCode: 9,
                    modifiers: [.option]
                )
            }

            self.shortcutBindings = merged
        }
        if let v = decoded.actionEnabled { self.actionEnabled = v }
        // Calendar display preferences (backward-compatible — older files don't have these)
        if let v = decoded.showYearProgress    { self.showYearProgress = v }
        if let v = decoded.showDayProgress     { self.showDayProgress = v }
        if let v = decoded.showWorldClock      { self.showWorldClock = v }
        if let v = decoded.showWeekNumbers     { self.showWeekNumbers = v }
        if let v = decoded.highlightToday      { self.highlightToday = v }
        if let v = decoded.dimWeekends         { self.dimWeekends = v }
        if let v = decoded.weekStartsOnMonday  { self.weekStartsOnMonday = v }
        if let v = decoded.eventDotStyle       { self.eventDotStyle = v }
        if let v = decoded.calendarTextScale   { self.calendarTextScale = v }
        if let v = decoded.worldClockCities    { self.worldClockCities = v }
        if let v = decoded.menuBarTimeFormat   { self.menuBarTimeFormat = v }
        if let v = decoded.menuBarSeparator    { self.menuBarSeparator = v }
        if let v = decoded.menuBarEmoji        { self.menuBarEmoji = v }
        if let v = decoded.translateSourceLanguage { self.translateSourceLanguage = v }
        if let v = decoded.translateTargetLanguage { self.translateTargetLanguage = v }
        if let v = decoded.linkedCalendars     { self.linkedCalendars = v }
        if let v = decoded.reminderBackgroundImagePath { self.reminderBackgroundImagePath = v }
    }

    private func save() {
        let settings = PersistedSettings(
            moduleStates: moduleStates,
            use24HourTime: use24HourTime,
            theme: theme,
            menuBarTokens: menuBarTokens,
            meetingReminderMinutes: meetingReminderMinutes,
            meetingReminderStyle: meetingReminderStyle,
            windowSnapModifier: windowSnapModifier,
            shortcutBindings: shortcutBindings,
            showYearProgress: showYearProgress,
            showDayProgress: showDayProgress,
            showWorldClock: showWorldClock,
            showWeekNumbers: showWeekNumbers,
            highlightToday: highlightToday,
            dimWeekends: dimWeekends,
            weekStartsOnMonday: weekStartsOnMonday,
            eventDotStyle: eventDotStyle,
            calendarTextScale: calendarTextScale,
            worldClockCities: worldClockCities,
            menuBarTimeFormat: menuBarTimeFormat,
            menuBarSeparator: menuBarSeparator,
            menuBarEmoji: menuBarEmoji,
            translateSourceLanguage: translateSourceLanguage,
            translateTargetLanguage: translateTargetLanguage,
            linkedCalendars: linkedCalendars,
            reminderBackgroundImagePath: reminderBackgroundImagePath,
            actionEnabled: actionEnabled
        )

        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Shortcut Binding Model

struct ShortcutBinding: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: CodableModifiers

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = CodableModifiers(flags: modifiers)
    }

    var nsModifiers: NSEvent.ModifierFlags {
        modifiers.flags
    }

    /// Human-readable display string like "⌃⌥C"
    var displayString: String {
        var parts: [String] = []
        if nsModifiers.contains(.control) { parts.append("⌃") }
        if nsModifiers.contains(.option) { parts.append("⌥") }
        if nsModifiers.contains(.shift) { parts.append("⇧") }
        if nsModifiers.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    /// Factory defaults for every shortcut action
    static let defaults: [String: ShortcutBinding] = [
        "screenshot":       ShortcutBinding(keyCode: 1,  modifiers: [.control, .option]),     // ⌃⌥S
        // Find My Mouse is gesture-only (double-tap right ⌘) — no
        // assignable shortcut here. The gesture is hard-wired in
        // `MouseHighlightModule.setupRightCommandMonitor()`.
        "clickHighlighter": ShortcutBinding(keyCode: 4,  modifiers: [.command, .option]),     // ⌘⌥H
        "joinMeeting":      ShortcutBinding(keyCode: 38, modifiers: [.command, .shift]),       // ⌘⇧J
        "pinWindow":        ShortcutBinding(keyCode: 13, modifiers: [.shift, .option]),        // ⇧⌥W
        "colorPicker":      ShortcutBinding(keyCode: 8,  modifiers: [.control, .option]),      // ⌃⌥C
        "screenRuler":      ShortcutBinding(keyCode: 15, modifiers: [.control, .option]),      // ⌃⌥R
        "textExtractor":    ShortcutBinding(keyCode: 17, modifiers: [.control, .option]),      // ⌃⌥T
        "zoomIt":           ShortcutBinding(keyCode: 6,  modifiers: [.control, .option]),      // ⌃⌥Z
        "fancyZones":       ShortcutBinding(keyCode: 50, modifiers: [.option, .shift]),        // ⌥⇧` (backtick)
        "clipboard":        ShortcutBinding(keyCode: 9,  modifiers: [.option]),                // ⌥V
        "claudeLauncher":   ShortcutBinding(keyCode: 40, modifiers: [.control, .option]),      // ⌃⌥K
        "openTerminal":     ShortcutBinding(keyCode: 17, modifiers: [.control, .option, .shift]), // ⌃⌥⇧T
    ]

    /// Grouping for the Settings → Shortcuts list. Each group renders
    /// as its own card so related actions sit together visually.
    enum ShortcutGroup: String, CaseIterable, Identifiable {
        case calendar      = "Calendar & Meetings"
        case window        = "Window Management"
        case screen        = "Screen Tools"
        case input         = "Mouse & Highlights"
        case files         = "Files & Clipboard"
        case developer     = "Developer"
        var id: String { rawValue }
        var iconName: String {
            switch self {
            case .calendar:  return "calendar"
            case .window:    return "rectangle.split.3x1"
            case .screen:    return "eyedropper"
            case .input:     return "cursorarrow.click.2"
            case .files:     return "doc.on.clipboard"
            case .developer: return "terminal"
            }
        }
    }

    /// One action in the Shortcuts UI. Either keystroke-driven
    /// (`gestureLabel == nil`, has an editable `ShortcutBinding`) or
    /// gesture-driven (`gestureLabel == "Shift + Drag"` etc., no
    /// editable binding). Both kinds render in the same group card
    /// so related actions stay visually together — no more separate
    /// "Gestures" section.
    struct Action: Identifiable {
        let id: String
        let name: String
        let description: String
        let group: ShortcutGroup
        let gestureLabel: String?

        var isGesture: Bool { gestureLabel != nil }
    }

    /// All actions in display order, grouped by association. The flat
    /// `allActions` view (preserved as a computed property below) is
    /// what the hotkey registration loop walks — gestures are skipped
    /// there because they have no keyboard binding.
    static let allActionsGrouped: [Action] = [
        // Calendar & Meetings
        .init(id: "joinMeeting", name: "Join Next Meeting",
              description: "Opens the meeting URL of the next event on your calendar.",
              group: .calendar, gestureLabel: nil),

        // Window Management — Pin + both FancyZones flavors live here.
        .init(id: "pinWindow", name: "Pin Window",
              description: "Holds the focused window above all others with a red border. Press again to release.",
              group: .window, gestureLabel: nil),
        .init(id: "fancyZones", name: "FancyZones Editor",
              description: "Open the template gallery to pick or customize a tiling layout.",
              group: .window, gestureLabel: nil),
        .init(id: "fancyZonesSnap", name: "FancyZones Snap",
              description: "Hold Shift while dragging a window — drop it into a zone to resize.",
              group: .window, gestureLabel: "Shift + Drag"),

        // Screen Tools
        .init(id: "screenshot", name: "Screenshot & Annotate",
              description: "Capture a region, draw on top, share, or live-translate the text inside.",
              group: .screen, gestureLabel: nil),
        .init(id: "colorPicker", name: "Color Picker",
              description: "Magnified loupe — click any pixel to copy its color in HEX / RGB / HSL.",
              group: .screen, gestureLabel: nil),
        .init(id: "screenRuler", name: "Screen Ruler",
              description: "Measure pixel distances on screen with edge snapping.",
              group: .screen, gestureLabel: nil),
        .init(id: "textExtractor", name: "Text Extractor (OCR)",
              description: "Vision-powered OCR — select a region and the text lands on your clipboard.",
              group: .screen, gestureLabel: nil),
        .init(id: "zoomIt", name: "ZoomIt",
              description: "Zoom into any part of the screen and draw on top — built for demos.",
              group: .screen, gestureLabel: nil),

        // Mouse & Highlights — Find My Mouse gesture + click highlighter.
        .init(id: "findMyMouse", name: "Find My Mouse",
              description: "Dark spotlight ring under the cursor — helpful on multi-monitor setups.",
              group: .input, gestureLabel: "Double-tap right ⌘"),
        .init(id: "clickHighlighter", name: "On Click Highlight",
              description: "Small yellow ring at every mouse click. Toggles on / off.",
              group: .input, gestureLabel: nil),

        // Files & Clipboard
        .init(id: "clipboard", name: "Clipboard History",
              description: "Browse and paste from the last ~100 things you copied — text, images, files.",
              group: .files, gestureLabel: nil),

        // Developer
        .init(id: "openTerminal", name: "Open Terminal",
              description: "Open a fresh macOS Terminal.app window.",
              group: .developer, gestureLabel: nil),
        .init(id: "claudeLauncher", name: "Open Terminal · Claude",
              description: "Open Terminal and start a Claude Code session in a new window.",
              group: .developer, gestureLabel: nil),
    ]

    /// Flat view of keystroke-bindable actions. Used by the hotkey
    /// registration loop and the "Reset all to defaults" button. Skips
    /// gesture-only actions because they have no `ShortcutBinding`.
    static var allActions: [(id: String, name: String)] {
        allActionsGrouped
            .filter { !$0.isGesture }
            .map { ($0.id, $0.name) }
    }

    /// Convenience: every action (both keystroke + gesture) in one
    /// group, declaration order preserved.
    static func actions(in group: ShortcutGroup) -> [Action] {
        allActionsGrouped.filter { $0.group == group }
    }

    // Key code → name mapping
    static func keyName(for keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
            50: "`", 51: "Delete", 53: "Esc", 76: "Enter",
            115: "Home", 116: "PageUp", 117: "FwdDel", 119: "End", 121: "PageDown",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
            97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12",
        ]
        return names[keyCode] ?? "Key\(keyCode)"
    }
}

// MARK: - Codable wrapper for NSEvent.ModifierFlags

struct CodableModifiers: Codable, Equatable {
    let rawValue: UInt

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: rawValue)
    }

    init(flags: NSEvent.ModifierFlags) {
        // Only store the modifier bits we care about
        self.rawValue = flags.intersection([.command, .option, .control, .shift]).rawValue
    }
}

// MARK: - Codable Container

private struct PersistedSettings: Codable {
    let moduleStates: [String: Bool]
    let use24HourTime: Bool
    let theme: SettingsManager.AppTheme
    let menuBarTokens: [SettingsManager.MenuBarToken]
    let meetingReminderMinutes: Int
    let meetingReminderStyle: SettingsManager.ReminderStyle
    let windowSnapModifier: SettingsManager.SnapModifier
    let shortcutBindings: [String: ShortcutBinding]?

    // Calendar display (all optional for forward/back compatibility)
    let showYearProgress:    Bool?
    let showDayProgress:     Bool?
    let showWorldClock:      Bool?
    let showWeekNumbers:     Bool?
    let highlightToday:      Bool?
    let dimWeekends:         Bool?
    let weekStartsOnMonday:  Bool?
    let eventDotStyle:       SettingsManager.EventDotStyle?
    let calendarTextScale:   Double?
    let worldClockCities:    [WorldClockCity]?
    let menuBarTimeFormat:   String?
    let menuBarSeparator:    String?
    let menuBarEmoji:        String?
    let translateSourceLanguage: String?
    let translateTargetLanguage: String?
    let linkedCalendars:     [LinkedCalendar]?
    let reminderBackgroundImagePath: String?
    let actionEnabled:       [String: Bool]?
}

// MARK: - World Clock City

struct WorldClockCity: Codable, Equatable, Identifiable {
    let id: UUID
    var label: String
    /// IANA timezone id (e.g. "Europe/Stockholm"). Empty string means "follow Local".
    var timeZoneId: String

    init(id: UUID = UUID(), label: String, timeZoneId: String) {
        self.id = id
        self.label = label
        self.timeZoneId = timeZoneId
    }

    var timeZone: TimeZone {
        timeZoneId.isEmpty
            ? TimeZone.current
            : (TimeZone(identifier: timeZoneId) ?? TimeZone.current)
    }

    var isLocal: Bool { timeZoneId.isEmpty }

    static let defaults: [WorldClockCity] = [
        WorldClockCity(label: "Local",     timeZoneId: ""),
        WorldClockCity(label: "Stockholm", timeZoneId: "Europe/Stockholm"),
    ]

    /// Common picker presets shown in Settings.
    static let presets: [WorldClockCity] = [
        WorldClockCity(label: "Stockholm",     timeZoneId: "Europe/Stockholm"),
        WorldClockCity(label: "London",        timeZoneId: "Europe/London"),
        WorldClockCity(label: "Berlin",        timeZoneId: "Europe/Berlin"),
        WorldClockCity(label: "Paris",         timeZoneId: "Europe/Paris"),
        WorldClockCity(label: "New York",      timeZoneId: "America/New_York"),
        WorldClockCity(label: "San Francisco", timeZoneId: "America/Los_Angeles"),
        WorldClockCity(label: "Tokyo",         timeZoneId: "Asia/Tokyo"),
        WorldClockCity(label: "Singapore",     timeZoneId: "Asia/Singapore"),
        WorldClockCity(label: "Dubai",         timeZoneId: "Asia/Dubai"),
        WorldClockCity(label: "Sydney",        timeZoneId: "Australia/Sydney"),
        WorldClockCity(label: "Dhaka",         timeZoneId: "Asia/Dhaka"),
        WorldClockCity(label: "Mumbai",        timeZoneId: "Asia/Kolkata"),
    ]
}

// MARK: - Linked Calendar (user-curated subset of EventKit calendars)

struct LinkedCalendar: Codable, Equatable, Identifiable {
    let id: UUID
    /// EKCalendar.calendarIdentifier — pairs us to the actual macOS calendar
    let calendarIdentifier: String
    /// User-overridden display name shown in Forge
    var displayName: String
    /// Hex color from the preset palette (or custom hex)
    var colorHex: String

    init(id: UUID = UUID(),
         calendarIdentifier: String,
         displayName: String,
         colorHex: String) {
        self.id = id
        self.calendarIdentifier = calendarIdentifier
        self.displayName = displayName
        self.colorHex = colorHex
    }
}

/// 10 preset accent colors for linked calendars. Modelled on Dot / Apple Calendar.
enum CalendarColorPreset: String, CaseIterable, Identifiable {
    case red    = "#E72903"
    case orange = "#FF9F0A"
    case yellow = "#FFD60A"
    case green  = "#34C759"
    case mint   = "#00C7BE"
    case teal   = "#5AC8FA"
    case blue   = "#0A84FF"
    case purple = "#BF5AF2"
    case pink   = "#FF375F"
    case gray   = "#8E8E93"

    var id: String { rawValue }
    var hex: String { rawValue }

    static func nextUnused(in linked: [LinkedCalendar]) -> CalendarColorPreset {
        let used = Set(linked.map { $0.colorHex.uppercased() })
        return allCases.first { !used.contains($0.hex.uppercased()) } ?? .blue
    }
}


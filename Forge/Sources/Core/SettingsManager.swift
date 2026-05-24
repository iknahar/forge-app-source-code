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

    @Published var menuBarTokens: [MenuBarToken] = [.icon, .nextEvent, .clock] {
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

    /// User-chosen emoji to use in place of the hammer icon in the menu bar
    /// and previews. Empty string ⇒ fall back to the SF Symbol hammer.
    @Published var menuBarEmoji: String = "" {
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

    @Published var alwaysOnTopBorderColor: String = "#E72903" {
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
            case .clock:        return "Time"
            case .dayProgress:  return "Day %"
            case .yearProgress: return "Year %"
            default:            return rawValue
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
            self.shortcutBindings = merged
        }
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
            linkedCalendars: linkedCalendars,
            reminderBackgroundImagePath: reminderBackgroundImagePath
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
        "commandPalette": ShortcutBinding(keyCode: 49, modifiers: [.option]),               // ⌥Space (⌘⇧Space conflicts with macOS)
        "screenshot":     ShortcutBinding(keyCode: 1,  modifiers: [.control, .option]),     // ⌃⌥S
        "mouseHighlight": ShortcutBinding(keyCode: 46, modifiers: [.command, .shift]),      // ⇧⌘M
        "joinMeeting":    ShortcutBinding(keyCode: 38, modifiers: [.command, .shift]),       // ⌘⇧J
        "alwaysOnTop":    ShortcutBinding(keyCode: 0,  modifiers: [.control, .option]),      // ⌃⌥A
        "colorPicker":    ShortcutBinding(keyCode: 8,  modifiers: [.control, .option]),      // ⌃⌥C
        "screenRuler":    ShortcutBinding(keyCode: 15, modifiers: [.control, .option]),      // ⌃⌥R
        "textExtractor":  ShortcutBinding(keyCode: 17, modifiers: [.control, .option]),      // ⌃⌥T
        "zoomIt":         ShortcutBinding(keyCode: 6,  modifiers: [.control, .option]),      // ⌃⌥Z
        "fancyZones":     ShortcutBinding(keyCode: 3,  modifiers: [.control, .option]),      // ⌃⌥F
    ]

    /// All action IDs with human-readable names, in display order
    static let allActions: [(id: String, name: String)] = [
        ("commandPalette", "Command Bar"),
        ("joinMeeting",    "Join Next Meeting"),
        ("alwaysOnTop",    "Always On Top"),
        ("colorPicker",    "Color Picker"),
        ("screenRuler",    "Screen Ruler"),
        ("textExtractor",  "Text Extractor (OCR)"),
        ("zoomIt",         "ZoomIt"),
        ("fancyZones",     "FancyZones Editor"),
        ("screenshot",     "Screenshot & Annotate"),
        ("mouseHighlight", "Find My Mouse"),
    ]

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
    let linkedCalendars:     [LinkedCalendar]?
    let reminderBackgroundImagePath: String?
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


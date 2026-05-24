import SwiftUI
import AppKit
import Combine

/// The heart of Forge — manages menu bar presence, popover, and module lifecycle.
/// Forge lives entirely in the menu bar. No Dock icon. No standard windows (except Settings).
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var commandPaletteWindow: NSWindow?
    private var fullCalendarWindow: NSWindow?

    let moduleRegistry = ModuleRegistry()
    let settingsManager = SettingsManager()
    let hotkeyManager = HotkeyManager()
    private var shortcutObserver: AnyCancellable?
    private var menuBarTokensObserver: AnyCancellable?
    private var menuBarFormatObserver: AnyCancellable?
    private var menuBarSepObserver: AnyCancellable?
    private var menuBarEmojiObserver: AnyCancellable?
    private var menuBarRefreshTimer: Timer?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Forge] applicationDidFinishLaunching START")
        // Hide from Dock — Forge is menu-bar-only
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()
        print("[Forge] setupMenuBar done. statusItem=\(statusItem != nil) button=\(statusItem?.button != nil)")

        setupPopover()
        print("[Forge] setupPopover done. popover=\(popover != nil)")

        registerModules()
        print("[Forge] registerModules done. count=\(moduleRegistry.modules.count)")

        setupGlobalHotkeys()
        setupEventMonitor()

        // Activate the first enabled module
        moduleRegistry.activateEnabledModules()

        // Now that modules + settings are ready, observe & start menu bar refresh
        setupMenuBarObservers()
        startMenuBarRefreshTimer()
        refreshMenuBar()

        print("[Forge] applicationDidFinishLaunching COMPLETE")
    }

    func applicationWillTerminate(_ notification: Notification) {
        moduleRegistry.deactivateAllModules()
        hotkeyManager.unregisterAll()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Initial icon — refreshMenuBar() will adjust based on user tokens
            let icon = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "Forge")
            icon?.isTemplate = true
            button.image = icon
            button.imagePosition = .imageLeading

            // Subscribe to both left- and right-click events so we can
            // branch behavior — left = open the popover, right = show a
            // small AppKit menu with "Quit Forge".
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Builds the right-click menu shown when the user secondary-clicks the
    /// menu bar icon. Currently only contains Quit Forge, but is structured
    /// so we can add About / Preferences / Check for Updates later.
    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let quit = NSMenuItem(
            title: "Quit Forge",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    /// Single entry point for clicks on the status item; branches based on
    /// the actual NSEvent type. Right click pops the context menu, anything
    /// else toggles the popover (which is the expanded calendar).
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        switch event.type {
        case .rightMouseUp:
            // Showing a menu via `popUpMenu(_:)` blocks until the user
            // dismisses it. The status item's `menu` property is set
            // temporarily so the standard system positioning is used.
            let menu = buildContextMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        default:
            togglePopover()
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: ForgeTheme.Layout.popoverWidth, height: 520)
        popover.behavior = .transient
        popover.animates = true

        let menuBarView = MenuBarView()
            .environmentObject(moduleRegistry)
            .environmentObject(settingsManager)

        let controller = NSHostingController(rootView: menuBarView)
        // CRITICAL: lock the popover's size to `contentSize` and refuse to
        // track the SwiftUI content's natural size. Without this the
        // NSHostingController updates `preferredContentSize` whenever an
        // event row's natural width changes (e.g. a Join button appears),
        // and NSPopover observes that and re-animates its frame — which
        // makes the popover visibly resize between different selected
        // dates. Explicit empty `sizingOptions` keeps the popover rigid.
        if #available(macOS 13.0, *) {
            controller.sizingOptions = []
        }
        popover.contentViewController = controller
    }

    // MARK: - Module Registration

    private func registerModules() {
        // Calendar — the home screen
        let calendarModule = CalendarModule()
        moduleRegistry.register(calendarModule)

        // Command Palette — the central hub
        let commandPaletteModule = CommandPaletteModule()
        moduleRegistry.register(commandPaletteModule)

        // Window Manager — snap zones, always on top
        let windowManagerModule = WindowManagerModule()
        moduleRegistry.register(windowManagerModule)

        // Color Picker — system-wide pixel color sampling (⌃⌥C)
        let colorPickerModule = ColorPickerModule()
        moduleRegistry.register(colorPickerModule)

        // Screen Ruler — pixel measurement with edge detection (⌃⌥R)
        let screenRulerModule = ScreenRulerModule()
        moduleRegistry.register(screenRulerModule)

        // Text Extractor — OCR using Apple Vision framework (⌃⌥T)
        let textExtractorModule = TextExtractorModule()
        moduleRegistry.register(textExtractorModule)

        // ZoomIt — screen zoom, annotation, break timer (⌃⌥Z)
        let zoomItModule = ZoomItModule()
        moduleRegistry.register(zoomItModule)

        // FancyZones — custom window snap zone layouts (⌃⌥F)
        let fancyZonesModule = FancyZonesModule()
        moduleRegistry.register(fancyZonesModule)

        // Key Remap — remap keys and shortcuts system-wide
        let keyRemapModule = KeyRemapModule()
        moduleRegistry.register(keyRemapModule)

        // Mouse Highlight — find cursor, click visualization, crosshairs
        let mouseHighlightModule = MouseHighlightModule()
        moduleRegistry.register(mouseHighlightModule)

        // Meeting Reminder — floating banner before/during meetings
        let meetingReminderModule = MeetingReminderModule()
        meetingReminderModule.calendarRef = calendarModule
        meetingReminderModule.settingsRef = settingsManager
        moduleRegistry.register(meetingReminderModule)

        // Screenshot — region capture + annotate + share
        let screenshotModule = ScreenshotAnnotateModule()
        moduleRegistry.register(screenshotModule)

        // Load saved enabled/disabled states
        moduleRegistry.loadStates(from: settingsManager)
    }

    // MARK: - Global Hotkeys (user-configurable via Settings)

    private func setupGlobalHotkeys() {
        registerAllHotkeys()
        observeShortcutChanges()
    }

    /// Register every hotkey from the current settings bindings
    func registerAllHotkeys() {
        hotkeyManager.unregisterAll()

        let b = settingsManager.shortcutBindings

        registerHotkey("commandPalette", binding: b["commandPalette"]) { [weak self] in
            self?.showCommandPalette()
        }
        registerHotkey("joinMeeting", binding: b["joinMeeting"]) { [weak self] in
            self?.joinNextMeeting()
        }
        registerHotkey("alwaysOnTop", binding: b["alwaysOnTop"]) { [weak self] in
            self?.toggleAlwaysOnTop()
        }
        registerHotkey("colorPicker", binding: b["colorPicker"]) { [weak self] in
            self?.moduleRegistry.module(ofType: ColorPickerModule.self)?.startPicking()
        }
        registerHotkey("screenRuler", binding: b["screenRuler"]) { [weak self] in
            self?.moduleRegistry.module(ofType: ScreenRulerModule.self)?.startMeasuring()
        }
        registerHotkey("textExtractor", binding: b["textExtractor"]) { [weak self] in
            self?.moduleRegistry.module(ofType: TextExtractorModule.self)?.startExtracting()
        }
        registerHotkey("zoomIt", binding: b["zoomIt"]) { [weak self] in
            self?.moduleRegistry.module(ofType: ZoomItModule.self)?.startZoom()
        }
        registerHotkey("fancyZones", binding: b["fancyZones"]) { [weak self] in
            self?.moduleRegistry.module(ofType: FancyZonesModule.self)?.openEditor()
        }
        registerHotkey("screenshot", binding: b["screenshot"]) { [weak self] in
            self?.moduleRegistry.module(ofType: ScreenshotAnnotateModule.self)?.startCapture()
        }
        registerHotkey("mouseHighlight", binding: b["mouseHighlight"]) { [weak self] in
            self?.moduleRegistry.module(ofType: MouseHighlightModule.self)?.toggleFindMyMouse()
        }
    }

    private func registerHotkey(_ id: String, binding: ShortcutBinding?, handler: @escaping () -> Void) {
        guard let binding = binding else { return }
        hotkeyManager.register(
            keyCode: binding.keyCode,
            modifiers: binding.nsModifiers,
            id: id,
            handler: handler
        )
    }

    /// Watch for changes to shortcut bindings and re-register live
    private func observeShortcutChanges() {
        shortcutObserver = settingsManager.$shortcutBindings.dropFirst().sink { [weak self] _ in
            self?.registerAllHotkeys()
        }
    }

    // MARK: - Event Monitor (click-outside-to-close)

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    // MARK: - Actions

    @objc private func togglePopover() {
        print("[Forge] togglePopover FIRED")
        guard let button = statusItem.button else {
            print("[Forge] togglePopover: button is nil — aborting")
            return
        }

        if popover == nil {
            print("[Forge] togglePopover: popover is nil — aborting")
            return
        }

        if popover.isShown {
            print("[Forge] togglePopover: closing")
            popover.performClose(nil)
        } else {
            print("[Forge] togglePopover: showing popover, contentSize=\(popover.contentSize)")
            // Position popover below menu bar button
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Ensure popover window is key
            popover.contentViewController?.view.window?.makeKey()
            print("[Forge] togglePopover: shown=\(popover.isShown)")
        }
    }

    /// Open / focus the full-window Notion-style calendar.
    func openFullCalendar() {
        if let existing = fullCalendarWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let calendarModule = moduleRegistry.module(ofType: CalendarModule.self) else { return }

        let view = FullCalendarView()
            .environmentObject(calendarModule)
            .environmentObject(settingsManager)
            .environmentObject(moduleRegistry)

        let hosting = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Forge — Calendar"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.center()
        window.contentViewController = hosting
        window.minSize = NSSize(width: 880, height: 540)
        window.isReleasedWhenClosed = false

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        fullCalendarWindow = window

        // Close the popover so we don't have two surfaces visible
        if popover.isShown { popover.performClose(nil) }
    }

    private func showCommandPalette() {
        if let window = commandPaletteWindow, window.isVisible {
            window.orderOut(nil)
            commandPaletteWindow = nil
            return
        }

        let paletteView = CommandPaletteView(
            onDismiss: { [weak self] in
                self?.commandPaletteWindow?.orderOut(nil)
                self?.commandPaletteWindow = nil
            }
        )
        .environmentObject(moduleRegistry)

        let hostingView = NSHostingController(rootView: paletteView)

        let window = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.isMovableByWindowBackground = false

        // Center on active screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = window.frame
            let x = screenFrame.midX - windowFrame.width / 2
            let y = screenFrame.midY - windowFrame.height / 2 + 100 // Slightly above center
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        commandPaletteWindow = window
    }

    private func joinNextMeeting() {
        guard let calendarModule = moduleRegistry.module(ofType: CalendarModule.self) else { return }
        calendarModule.joinNextMeeting()
    }

    private func toggleAlwaysOnTop() {
        guard let windowManager = moduleRegistry.module(ofType: WindowManagerModule.self) else { return }
        windowManager.toggleAlwaysOnTop()
    }

    // MARK: - Menu Bar Composable Rendering

    private func setupMenuBarObservers() {
        menuBarTokensObserver = settingsManager.$menuBarTokens.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshMenuBar() }
        }
        menuBarFormatObserver = settingsManager.$menuBarTimeFormat.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshMenuBar() }
        }
        menuBarSepObserver = settingsManager.$menuBarSeparator.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshMenuBar() }
        }
        menuBarEmojiObserver = settingsManager.$menuBarEmoji.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshMenuBar() }
        }
    }

    private func startMenuBarRefreshTimer() {
        menuBarRefreshTimer?.invalidate()
        // Refresh every 30s so countdowns and clocks stay current.
        menuBarRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshMenuBar()
        }
    }

    /// Recompute and apply the menu bar icon + title from `settings.menuBarTokens`.
    func refreshMenuBar() {
        guard let button = statusItem?.button else { return }

        let tokens = settingsManager.menuBarTokens

        // Icon visibility — show hammer only if the user includes `.icon`.
        // Fallback: always show icon if no text tokens, otherwise the item disappears.
        let textTokens = tokens.filter { $0 != .icon }
        let renderedParts = textTokens.compactMap { token -> String? in
            let s = renderMenuBarToken(token)
            return s.isEmpty ? nil : s
        }
        let titleText = renderedParts.joined(separator: settingsManager.menuBarSeparator)

        let shouldShowIcon = tokens.contains(.icon) || renderedParts.isEmpty
        let userEmoji = settingsManager.menuBarEmoji.trimmingCharacters(in: .whitespacesAndNewlines)

        if shouldShowIcon {
            if !userEmoji.isEmpty {
                // Render user's emoji as TEXT (NSStatusItem can't tint emojis
                // through .isTemplate, so we draw them as title characters).
                // Title-only mode — no SF symbol image.
                button.image = nil
                button.imagePosition = .noImage
                button.title = renderedParts.isEmpty
                    ? userEmoji
                    : "\(userEmoji) \(titleText)"
            } else {
                let icon = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "Forge")
                icon?.isTemplate = true
                button.image = icon
                button.imagePosition = renderedParts.isEmpty ? .imageOnly : .imageLeading
                button.title = renderedParts.isEmpty ? "" : " \(titleText)"
            }
        } else {
            button.image = nil
            button.title = titleText
            button.imagePosition = .noImage
        }
    }

    /// Render a single token to its display string. Returns "" for tokens that
    /// have no current value (e.g. nextEvent when there are no upcoming events).
    private func renderMenuBarToken(_ token: SettingsManager.MenuBarToken) -> String {
        let cal = Calendar.current
        let now = Date()
        let fmt = DateFormatter()

        switch token {
        case .icon:
            return ""  // handled separately

        case .date:
            fmt.dateFormat = "EEE, MMM d"
            return fmt.string(from: now)

        case .clock:
            fmt.dateFormat = settingsManager.menuBarTimeFormat
            return fmt.string(from: now)

        case .nextEvent:
            guard let next = moduleRegistry.module(ofType: CalendarModule.self)?.nextEvent
            else { return "" }
            let mins = Int(next.startDate.timeIntervalSince(now) / 60)
            if mins < 60 && mins >= 0 {
                return "\(truncate(next.title, max: 22)) · \(mins)m"
            }
            return truncate(next.title, max: 22)

        case .countdown:
            guard let next = moduleRegistry.module(ofType: CalendarModule.self)?.nextEvent
            else { return "" }
            let interval = next.startDate.timeIntervalSince(now)
            guard interval > 0 else { return "now" }
            let totalMins = Int(interval / 60)
            let h = totalMins / 60
            let m = totalMins % 60
            return h > 0 ? "\(h)h \(m)m" : "\(m)m"

        case .weekNumber:
            var isoCal = Calendar(identifier: .iso8601)
            isoCal.firstWeekday = settingsManager.weekStartsOnMonday ? 2 : 1
            return "W\(isoCal.component(.weekOfYear, from: now))"

        case .dayProgress:
            let startOfDay = cal.startOfDay(for: now)
            let pct = Int(now.timeIntervalSince(startOfDay) / 86400 * 100)
            return "\(pct)%"

        case .yearProgress:
            let year = cal.component(.year, from: now)
            guard
                let yStart = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
                let yEnd   = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))
            else { return "" }
            let pct = Int(now.timeIntervalSince(yStart) / yEnd.timeIntervalSince(yStart) * 100)
            return "\(pct)% of \(year)"

        case .worldClock:
            // First non-local city; if none, skip.
            guard let city = settingsManager.worldClockCities.first(where: { !$0.isLocal })
            else { return "" }
            fmt.timeZone = city.timeZone
            fmt.dateFormat = settingsManager.menuBarTimeFormat
            let abbrev = String(city.label.prefix(3)).uppercased()
            return "\(abbrev) \(fmt.string(from: now))"

        case .timeLeft:
            // Time remaining in the currently happening event
            guard
                let cal2 = moduleRegistry.module(ofType: CalendarModule.self),
                let live = cal2.events.first(where: { now >= $0.startDate && now < $0.endDate })
            else { return "" }
            let mins = Int(live.endDate.timeIntervalSince(now) / 60)
            return "\(mins)m left"

        case .eventsLeft:
            guard let cal2 = moduleRegistry.module(ofType: CalendarModule.self) else { return "" }
            let remaining = cal2.todayEvents.filter { $0.startDate >= now }.count
            return remaining == 0 ? "" : "\(remaining) left"

        case .focusTime:
            guard let cal2 = moduleRegistry.module(ofType: CalendarModule.self) else { return "" }
            let secs = cal2.focusTimeToday
            let h = Int(secs / 3600)
            let m = Int((secs.truncatingRemainder(dividingBy: 3600)) / 60)
            if h > 0 { return m > 0 ? "\(h)h \(m)m focus" : "\(h)h focus" }
            return m > 0 ? "\(m)m focus" : ""
        }
    }

    private func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    // Backwards-compat shim: old callers use updateMenuBarTitle()
    func updateMenuBarTitle() { refreshMenuBar() }
}

// MARK: - Borderless Panel for Command Palette

final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

import SwiftUI
import AppKit
import Combine

/// The heart of Forge — manages menu bar presence, popover, and module lifecycle.
/// Forge lives entirely in the menu bar. No Dock icon. No standard windows (except Settings).
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // MARK: - Singleton handle
    //
    // SwiftUI's `@NSApplicationDelegateAdaptor` wraps the user-supplied
    // AppDelegate inside an internal `SwiftUI.AppDelegate` proxy, so
    // `NSApp.delegate as? AppDelegate` (where `AppDelegate` is our
    // type) ALWAYS fails the cast. The proxy still forwards messages
    // to our instance — but we can't get at our instance through
    // `NSApp.delegate`.
    //
    // Workaround: keep a `shared` reference set during
    // `applicationDidFinishLaunching`. Any UI surface that needs to
    // call into the app delegate (e.g. the Tools list icon buttons
    // calling `triggerPrimaryAction(forModuleId:)`) goes through
    // `AppDelegate.shared` instead of `NSApp.delegate`.
    static var shared: AppDelegate?

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var fullCalendarWindow: NSWindow?

    let moduleRegistry = ModuleRegistry()
    let settingsManager = SettingsManager()
    let hotkeyManager = HotkeyManager()
    private var shortcutObserver: AnyCancellable?
    private var actionEnabledObserver: AnyCancellable?
    private var menuBarTokensObserver: AnyCancellable?
    private var menuBarFormatObserver: AnyCancellable?
    private var menuBarSepObserver: AnyCancellable?
    private var menuBarEmojiObserver: AnyCancellable?
    private var menuBarRefreshTimer: Timer?

    /// Live-pulse state for the "● Ongoing meeting" indicator.
    /// `pulseTimer` only runs while an ongoing meeting is in the menu
    /// bar; it toggles `pulseHigh` ~every 650ms and re-renders so the
    /// green dot fades between full and dim, signalling "live".
    private var pulseTimer: Timer?
    private var pulseHigh: Bool = true

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Park ourselves on the class so the SwiftUI views can route
        // back here without going through `NSApp.delegate` (which is
        // a `SwiftUI.AppDelegate` proxy, not us — see the `shared`
        // doc comment above for the full story).
        AppDelegate.shared = self
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

        // Open Settings on launch so opening Forge from the
        // Applications folder / Launchpad / Spotlight lands the
        // user on a real window instead of just dropping a menu
        // bar icon they might not notice. Dispatched async so the
        // Settings scene has a beat to install itself before we
        // ask AppKit to show it.
        DispatchQueue.main.async { [weak self] in
            self?.openSettingsWindow()
        }

        print("[Forge] applicationDidFinishLaunching COMPLETE")
    }

    func applicationWillTerminate(_ notification: Notification) {
        moduleRegistry.deactivateAllModules()
        hotkeyManager.unregisterAll()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// AppKit invokes this when the user clicks Forge.app while it's
    /// already running (Dock click, Launchpad re-open,
    /// double-clicking the .app icon in Finder). For a menu-bar
    /// accessory app, AppKit would otherwise just no-op — we use it
    /// as a hook to re-show Settings so the user gets the same
    /// landing behaviour they got on the first launch.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        print("[Forge] applicationShouldHandleReopen hasVisibleWindows=\(hasVisibleWindows)")
        openSettingsWindow()
        // Returning false tells AppKit "I've handled it, don't do
        // any default un-hide / front-bringing on my behalf".
        return false
    }

    /// Programmatically open the SwiftUI `Settings { … }` scene.
    /// The selector-action path is brittle on accessory apps (the
    /// responder chain doesn't always include the Settings scene's
    /// internal target), so we ALSO scan the existing window list
    /// for one already created by the scene and bring it forward
    /// directly. Belt-and-suspenders so re-launches reliably land
    /// on Settings.
    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)

        // Look for an existing Settings window. SwiftUI's
        // `Settings` scene creates an NSWindow whose identifier
        // contains "settings" or whose title is "Forge Settings".
        // We match loosely so any reasonable identifier hits.
        let existing = NSApp.windows.first { w in
            let id = w.identifier?.rawValue.lowercased() ?? ""
            let title = w.title.lowercased()
            return id.contains("settings")
                || id.contains("preferences")
                || title.contains("settings")
                || title.contains("preferences")
        }
        if let win = existing {
            print("[Forge] openSettingsWindow: found existing window id=\(win.identifier?.rawValue ?? "nil") title=\(win.title)")
            win.makeKeyAndOrderFront(nil)
            return
        }

        // No existing window — send the AppKit action that the
        // SwiftUI Settings scene installs.
        print("[Forge] openSettingsWindow: no existing window, sending action")
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
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

        // Eye Care — 20-20-20 micro-breaks + warm-tint screen
        // filter. Registered second (in the Calendar category) so
        // it appears as the second row in the Tools list — the
        // user explicitly asked for that placement so it's
        // discoverable without scrolling. Holds a weak reference
        // to the CalendarModule so it can ask "is there a meeting
        // happening right now?" before pushing a break in front of
        // the user.
        let eyeCareModule = EyeCareModule()
        eyeCareModule.calendarRef = calendarModule
        moduleRegistry.register(eyeCareModule)

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

        // Launchers — user-defined shortcuts that open apps,
        // documents, or URLs. Holds a weak reference to the
        // shared `HotkeyManager` so it can register / tear down
        // its hotkeys dynamically as the user edits the list.
        let launchersModule = LaunchersModule()
        launchersModule.hotkeyManagerRef = hotkeyManager
        moduleRegistry.register(launchersModule)


        // Mouse Highlight — find cursor, click visualization, crosshairs
        let mouseHighlightModule = MouseHighlightModule()
        moduleRegistry.register(mouseHighlightModule)

        // Meeting Reminder — floating banner before/during meetings
        let meetingReminderModule = MeetingReminderModule()
        meetingReminderModule.calendarRef = calendarModule
        meetingReminderModule.settingsRef = settingsManager
        moduleRegistry.register(meetingReminderModule)

        // Screenshot — region capture + annotate + share + translate
        let screenshotModule = ScreenshotAnnotateModule()
        screenshotModule.settingsRef = settingsManager
        moduleRegistry.register(screenshotModule)

        // Clipboard History — NSPasteboard watcher + ⌃⌥V history panel
        let clipboardModule = ClipboardModule()
        moduleRegistry.register(clipboardModule)

        // Plain Terminal launcher — ⌃⌥⇧T opens a blank Terminal window.
        // Registered as its own module so the menu-bar Tools popover
        // shows it as a separate row (the Tools grid iterates
        // registered modules, so each shortcut needs its own module
        // entry to surface).
        let terminalLauncherModule = TerminalLauncherModule()
        moduleRegistry.register(terminalLauncherModule)

        // Claude Code launcher — ⌃⌥K opens Terminal and starts `claude`
        let claudeLauncherModule = ClaudeLauncherModule()
        moduleRegistry.register(claudeLauncherModule)

        // Text Expander — system-wide snippet expansion (aText-style)
        let textExpanderModule = TextExpanderModule()
        moduleRegistry.register(textExpanderModule)

        // Bridge the per-action enable toggles into gesture handlers
        // so flipping the Settings toggle silences them in real time.
        // Captures `settingsManager` weakly via self — Swift retains
        // it through the closures, which is fine because both live
        // for the app's lifetime.
        mouseHighlightModule.isFindMyMouseGestureEnabled = { [weak self] in
            self?.settingsManager.isActionEnabled("findMyMouse") ?? true
        }
        fancyZonesModule.isSnapGestureEnabled = { [weak self] in
            self?.settingsManager.isActionEnabled("fancyZonesSnap") ?? true
        }

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

        registerHotkey("joinMeeting", binding: b["joinMeeting"]) { [weak self] in
            self?.joinNextMeeting()
        }
        registerHotkey("pinWindow", binding: b["pinWindow"]) { [weak self] in
            self?.togglePinWindow()
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
        // Find My Mouse has no global hotkey — it's gesture-only
        // (double-tap right ⌘), implemented inside the module.
        registerHotkey("clickHighlighter", binding: b["clickHighlighter"]) { [weak self] in
            self?.moduleRegistry.module(ofType: MouseHighlightModule.self)?.toggleClickHighlighter()
        }
        registerHotkey("clipboard", binding: b["clipboard"]) { [weak self] in
            guard let module = self?.moduleRegistry.module(ofType: ClipboardModule.self)
            else { return }
            ClipboardHistoryPanel.toggle(module: module)
        }
        registerHotkey("claudeLauncher", binding: b["claudeLauncher"]) { [weak self] in
            self?.moduleRegistry.module(ofType: ClaudeLauncherModule.self)?.launch()
        }
        registerHotkey("openTerminal", binding: b["openTerminal"]) { [weak self] in
            self?.moduleRegistry.module(ofType: TerminalLauncherModule.self)?.launch()
        }
    }

    private func registerHotkey(_ id: String, binding: ShortcutBinding?, handler: @escaping () -> Void) {
        guard let binding = binding else { return }
        // Skip disabled actions — the user wants this action silenced
        // without removing its stored binding.
        guard settingsManager.isActionEnabled(id) else { return }
        hotkeyManager.register(
            keyCode: binding.keyCode,
            modifiers: binding.nsModifiers,
            id: id,
            handler: handler
        )
    }

    // MARK: - Programmatic Module Triggers
    //
    // Mirrors the hotkey routing above so any surface (the Tools list
    // in Settings, in particular) can fire a module's primary action
    // without having to know per-module method names. Stays a single
    // switch with the hotkey table so the two never drift.

    /// True if `moduleId` exposes a single "do the thing" action that
    /// makes sense to fire from a UI click. Modules whose value lives
    /// in passive settings (Calendar, KeyRemap, TextExpander) return
    /// false — there's nothing meaningful to "run" for those.
    func hasPrimaryAction(forModuleId moduleId: String) -> Bool {
        Self.triggerableModuleIds.contains(moduleId)
    }

    /// Run the primary action for `moduleId` — the same closure the
    /// global hotkey would invoke. No-op (and returns false) for
    /// modules without a primary action OR modules deliberately
    /// excluded from the click-to-trigger list (Pin Window,
    /// FancyZones, Meeting Reminder, Key Remap — see
    /// `triggerableModuleIds`).
    @discardableResult
    func triggerPrimaryAction(forModuleId moduleId: String) -> Bool {
        guard Self.triggerableModuleIds.contains(moduleId) else { return false }
        switch moduleId {
        case "screenshotAnnotate":
            moduleRegistry.module(ofType: ScreenshotAnnotateModule.self)?.startCapture()
        case "colorPicker":
            moduleRegistry.module(ofType: ColorPickerModule.self)?.startPicking()
        case "screenRuler":
            moduleRegistry.module(ofType: ScreenRulerModule.self)?.startMeasuring()
        case "textExtractor":
            moduleRegistry.module(ofType: TextExtractorModule.self)?.startExtracting()
        case "zoomIt":
            moduleRegistry.module(ofType: ZoomItModule.self)?.startZoom()
        case "clipboard":
            guard let module = moduleRegistry.module(ofType: ClipboardModule.self) else { return false }
            ClipboardHistoryPanel.toggle(module: module)
        case "claudeLauncher":
            moduleRegistry.module(ofType: ClaudeLauncherModule.self)?.launch()
        case "terminalLauncher":
            moduleRegistry.module(ofType: TerminalLauncherModule.self)?.launch()
        default:
            return false
        }
        // Close the popover so the action takes the screen, not the
        // Settings window — same UX the keyboard shortcut would give.
        if popover?.isShown == true { popover.performClose(nil) }
        return true
    }

    /// Single source of truth for "which modules show a clickable
    /// icon on the Tools list". Deliberately narrower than the
    /// hotkey table — Pin Window, FancyZones, Meeting Reminder, Key
    /// Remap and Click Highlighter each have a primary action but
    /// the user prefers those to live behind their keyboard
    /// shortcut only (they're either modal flows, gestures, or
    /// "always-on" toggles that don't read well as a one-tap
    /// launcher icon).
    private static let triggerableModuleIds: Set<String> = [
        "screenshotAnnotate",
        "colorPicker",
        "screenRuler",
        "textExtractor",
        "zoomIt",
        "clipboard",
        "claudeLauncher",
        "terminalLauncher",
    ]

    /// Watch for changes to shortcut bindings and the per-action
    /// enabled flags. Either kind of change re-registers every
    /// hotkey so the live behavior matches what Settings shows.
    private func observeShortcutChanges() {
        shortcutObserver = settingsManager.$shortcutBindings
            .dropFirst()
            .sink { [weak self] _ in self?.registerAllHotkeys() }
        actionEnabledObserver = settingsManager.$actionEnabled
            .dropFirst()
            .sink { [weak self] _ in self?.registerAllHotkeys() }
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

    private func joinNextMeeting() {
        guard let calendarModule = moduleRegistry.module(ofType: CalendarModule.self) else { return }
        calendarModule.joinNextMeeting()
    }

    private func togglePinWindow() {
        guard let windowManager = moduleRegistry.module(ofType: WindowManagerModule.self) else { return }
        windowManager.togglePinWindow()
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

        // Compose the final visible string so we can decide whether the
        // live-pulse timer needs to run.
        let finalTitle: String
        if shouldShowIcon {
            if !userEmoji.isEmpty {
                button.image = nil
                button.imagePosition = .noImage
                finalTitle = renderedParts.isEmpty ? userEmoji : "\(userEmoji) \(titleText)"
            } else {
                let icon = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "Forge")
                icon?.isTemplate = true
                button.image = icon
                button.imagePosition = renderedParts.isEmpty ? .imageOnly : .imageLeading
                finalTitle = renderedParts.isEmpty ? "" : " \(titleText)"
            }
        } else {
            button.image = nil
            button.imagePosition = .noImage
            finalTitle = titleText
        }

        // Apply with attributedTitle so the "●" prefix of the ongoing
        // meeting token can be colored green and pulsed. Everything
        // else inherits the system menu bar text color (which adapts to
        // light/dark mode automatically).
        button.attributedTitle = makeMenuBarAttributedTitle(finalTitle)
        // Spin the pulse timer up/down depending on whether there's a
        // live indicator on screen right now.
        updatePulseTimer(hasOngoing: finalTitle.contains("●"))
    }

    /// Build the styled `NSAttributedString` for the menu bar. The base
    /// text inherits the system menu-bar foreground (`labelColor`,
    /// which flips with appearance). The "●" prefix that the
    /// `ongoingMeeting` token emits gets a green tint whose alpha
    /// alternates each tick to create the live-pulse effect.
    private func makeMenuBarAttributedTitle(_ raw: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: raw)
        // Use the system menu-bar font so glyph metrics match plain
        // .title — otherwise the dot can sit at a slightly different
        // vertical position than the surrounding text.
        let font = NSFont.menuBarFont(ofSize: 0)
        result.addAttribute(.font,
                            value: font,
                            range: NSRange(location: 0, length: result.length))

        // Find every "●" and color it red with the current pulse
        // alpha — the universal "recording / live" cue (Loom, Discord,
        // Riverside, Google Meet all do red). There's normally one
        // (from the ongoingMeeting token); multiple is fine, they all
        // pulse in sync.
        let alpha: CGFloat = pulseHigh ? 1.0 : 0.40
        let liveDot = NSColor.systemRed.withAlphaComponent(alpha)
        let nsRaw = raw as NSString
        var searchStart = 0
        while searchStart < nsRaw.length {
            let r = nsRaw.range(
                of: "●",
                options: [],
                range: NSRange(location: searchStart, length: nsRaw.length - searchStart)
            )
            if r.location == NSNotFound { break }
            result.addAttribute(.foregroundColor, value: liveDot, range: r)
            // Slightly smaller than the surrounding text so the dot
            // reads as a tidy live indicator instead of a heavy
            // bullet. Still bold-weight for confident presence.
            result.addAttribute(
                .font,
                value: NSFont.systemFont(ofSize: font.pointSize - 2, weight: .black),
                range: r
            )
            // Nudge the dot up a hair so its baseline visually
            // centers against the cap-height of the surrounding text
            // (otherwise small dots sit too low).
            result.addAttribute(.baselineOffset, value: 1.0, range: r)
            searchStart = r.location + r.length
        }
        return result
    }

    /// Starts / stops the ~650ms blink timer for the live indicator.
    /// We don't run it when there's nothing pulsing — saves repaint
    /// churn most of the day.
    private func updatePulseTimer(hasOngoing: Bool) {
        if hasOngoing {
            guard pulseTimer == nil else { return }
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.pulseHigh.toggle()
                // Lightweight repaint — only the attributedTitle changes.
                self.refreshMenuBar()
            }
        } else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulseHigh = true
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

        case .ongoingMeeting:
            // Currently-happening event — distinguished from `nextEvent`
            // with a leading red dot ●, and the suffix is "Xm left"
            // instead of "Xm" so it's obvious at a glance which event
            // is live vs. upcoming.
            guard let live = moduleRegistry.module(ofType: CalendarModule.self)?.ongoingEvent
            else { return "" }
            let remaining = live.endDate.timeIntervalSince(now)
            let mins = max(0, Int(ceil(remaining / 60)))
            let suffix: String
            if mins == 0 { suffix = "ending" }
            else if mins < 60 { suffix = "\(mins)m left" }
            else {
                let h = mins / 60
                let m = mins % 60
                suffix = m > 0 ? "\(h)h \(m)m left" : "\(h)h left"
            }
            return "● \(truncate(live.title, max: 20)) · \(suffix)"

        case .nextEvent:
            // Skip the ongoing event so combining both tokens doesn't
            // double-print the same meeting. Reads from `activeEvents`
            // (declined RSVPs already stripped) so a "Decline" in the
            // detail popover hides the event from the menu bar too.
            let cal = moduleRegistry.module(ofType: CalendarModule.self)
            let ongoingId = cal?.ongoingEvent?.id
            guard let next = cal?.activeEvents
                .filter({ $0.startDate > now && $0.id != ongoingId })
                .sorted(by: { $0.startDate < $1.startDate })
                .first
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
            // Time remaining in the currently happening event. Uses
            // `activeEvents` so a declined meeting that's technically
            // "happening" doesn't bubble up to the menu bar.
            guard
                let cal2 = moduleRegistry.module(ofType: CalendarModule.self),
                let live = cal2.activeEvents.first(where: { now >= $0.startDate && now < $0.endDate })
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

import SwiftUI
import AppKit

/// The main popover view that appears when clicking the menu bar icon.
/// This is Forge's "home screen" — the calendar is the default view.
/// Width: 360pt. Matches Dot's warm cream aesthetic (#FDFBF7),
/// toggle pills for tab switching, progress bar footer.
struct MenuBarView: View {
    @EnvironmentObject var moduleRegistry: ModuleRegistry
    @EnvironmentObject var settings: SettingsManager
    @Environment(\.openSettings) private var openSettings
    @State private var selectedTab: Tab = .calendar
    @State private var isHoveringSettings = false
    @State private var showConfetti = false
    /// Tracks whether we already celebrated today so the confetti
    /// fires at most once per day (not every time the popover opens).
    @State private var celebratedToday: Date? = nil

    enum Tab: String, CaseIterable {
        case calendar = "Calendar"
        case tools = "Tools"
    }

    var body: some View {
        bodyContent
            .overlay(ConfettiOverlay(trigger: $showConfetti))
            .preferredColorScheme(settings.theme.colorScheme)
            .onReceive(NotificationCenter.default.publisher(for: .forgeConfetti)) { _ in
                showConfetti = true
            }
            .onAppear { checkAllMeetingsDone() }
    }

    /// Fire confetti when the user opens the popover and all of today's
    /// meetings have already ended. This is SAFE — the user initiated
    /// the popover themselves, so they aren't screen-sharing or in an
    /// overrun meeting. Fires at most once per calendar day.
    private func checkAllMeetingsDone() {
        guard let cal = moduleRegistry.module(ofType: CalendarModule.self) else { return }
        let now = Date()
        let calendar = Calendar.current

        // Already celebrated today?
        if let last = celebratedToday, calendar.isDateInToday(last) { return }

        let todayMeetings = cal.activeEvents.filter {
            calendar.isDateInToday($0.startDate) && !$0.isAllDay
        }
        // Must have had at least one meeting today
        guard !todayMeetings.isEmpty else { return }
        // All meetings must have ended
        let allDone = todayMeetings.allSatisfy { $0.endDate <= now }
        // Don't fire before noon — feels wrong if your only meeting
        // was an 8 AM standup.
        let hour = calendar.component(.hour, from: now)
        guard allDone && hour >= 12 else { return }

        celebratedToday = now
        showConfetti = true
    }

    private var bodyContent: some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar

            // Subtle divider (Dot: border-black/[0.04])
            Rectangle()
                .fill(ForgeTheme.Colors.borderSubtle)
                .frame(height: 1)

            // Live workday progress strip — shows how far through the
            // day you are, with colored blocks for each meeting.
            if let cal = moduleRegistry.module(ofType: CalendarModule.self) {
                WorkdayProgressBar(events: cal.activeEvents)
            }

            // Content — NSScrollView-backed so scroll wheel events reach us
            // inside the NSPopover (SwiftUI ScrollView swallows them).
            // `frame(maxWidth: .infinity, alignment: .leading)` everywhere
            // in the chain so the SwiftUI content actually pins to the left
            // edge of the hostView. Without explicit `.leading`, SwiftUI's
            // default `.center` alignment was pushing the content inward
            // and creating the big asymmetric inset.
            ScrollableContainer {
                Group {
                    switch selectedTab {
                    case .calendar:
                        calendarContent
                    case .tools:
                        toolsGrid
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Subtle divider
            Rectangle()
                .fill(ForgeTheme.Colors.borderSubtle)
                .frame(height: 1)

            // Footer
            footerBar
        }
        .frame(width: ForgeTheme.Layout.popoverWidth)
        .background(ForgeTheme.Colors.pageBg)
    }

    // MARK: - Header (Dot-style: date + pill tabs + gear)

    private var headerBar: some View {
        HStack {
            // Tab switcher — pinned to the LEFT now that the redundant
            // "Sun, May 24" / "N events today" header text is gone (the
            // calendar grid itself already highlights today's date).
            HStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    ForgeTogglePill(
                        title: tab.rawValue,
                        isActive: selectedTab == tab
                    ) {
                        withAnimation(ForgeTheme.Animation.smooth) {
                            selectedTab = tab
                        }
                    }
                }
            }
            .padding(2)
            .background(ForgeTheme.Colors.surfaceSubtle.opacity(0.5))
            .cornerRadius(ForgeTheme.Radius.full)

            Spacer()

            // Settings gear — Dot's subtle icon button.
            //
            // We deliberately don't use SwiftUI's `SettingsLink` here:
            // Forge is an LSUIElement app (menu-bar only, no Dock
            // icon), and SettingsLink in that mode opens the Settings
            // window behind whichever app currently has focus. Calling
            // `NSApp.activate(ignoringOtherApps: true)` BEFORE
            // openSettings (and rasing the window once it exists) is
            // the only reliable way to bring it to the front on the
            // first click.
            Button {
                openSettingsForeground()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(
                        isHoveringSettings
                            ? ForgeTheme.Colors.textSecondary
                            : ForgeTheme.Colors.textTertiary
                    )
                    .frame(width: 28, height: 28)
                    .background(
                        isHoveringSettings
                            ? ForgeTheme.Colors.surfaceHover
                            : Color.clear
                    )
                    .cornerRadius(ForgeTheme.Radius.small)
                    .animation(ForgeTheme.Animation.smooth, value: isHoveringSettings)
            }
            .buttonStyle(.plain)
            .onHover { hovering in isHoveringSettings = hovering }
        }
        // 20pt L/R inset — matches calendarContent and toolsGrid below so
        // every row in the popover shares the same left edge.
        .padding(.horizontal, 20)
        .padding(.vertical, ForgeTheme.Spacing.md)
    }

    // MARK: - Calendar Content

    private var calendarContent: some View {
        VStack(alignment: .leading, spacing: ForgeTheme.Spacing.lg) {
            if let calendarModule = moduleRegistry.module(ofType: CalendarModule.self),
               moduleRegistry.isEnabled("calendar") {
                CalendarView()
                    .environmentObject(calendarModule)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                moduleDisabledView(moduleId: "calendar", name: "Calendar", icon: "calendar")
            }
        }
        // Force-fill the popover width; the parent VStack would otherwise
        // center-align this view if its natural width is smaller.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, ForgeTheme.Spacing.md)
    }

    // MARK: - Tools Grid (module list with toggles)

    /// Modules that are core surfaces, not user-toggleable utilities.
    /// They stay always-on and don't show in the Tools list.
    private static let hiddenModuleIds: Set<String> = ["calendar"]

    private var toolsGrid: some View {
        VStack(alignment: .leading, spacing: ForgeTheme.Spacing.sm) {
            ForEach(ModuleCategory.allCases) { category in
                let categoryModules = moduleRegistry
                    .modules(in: category)
                    .filter { !Self.hiddenModuleIds.contains($0.id) }
                if !categoryModules.isEmpty {
                    VStack(alignment: .leading, spacing: ForgeTheme.Spacing.sm) {
                        ForgeSectionHeader(title: category.rawValue)

                        ForEach(categoryModules, id: \.id) { module in
                            moduleRow(module)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, ForgeTheme.Spacing.xs)
                }
            }
        }
        // Force-fill the popover width — matches calendarContent exactly.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, ForgeTheme.Spacing.md)
    }

    private func moduleRow(_ module: any ForgeModule) -> some View {
        let enabled = moduleRegistry.isEnabled(module.id)
        let shortcutText = shortcutDisplay(for: module.id)
        let gesture = gestureLabel(for: module.id)
        return HStack(alignment: .top, spacing: ForgeTheme.Spacing.md) {
            // Module icon. On modules that have a primary action
            // (Screenshot, Color Picker, Clipboard, Terminal, etc.)
            // this becomes a clickable button — same behavior as the
            // module's keyboard shortcut. Hover lights up the chip
            // (accent ring + brighter tint + slight scale-up) so the
            // affordance is obvious. The Toggle to the right stays a
            // separate control.
            ModuleIconButton(
                moduleId: module.id,
                iconName: module.iconName,
                moduleName: module.name,
                enabled: enabled
            )
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(module.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)

                // Keystroke chip + gesture chip live on the same row.
                // Both render only when present so single-shortcut and
                // double-trigger (keystroke + gesture) modules look
                // tidy.
                HStack(spacing: 4) {
                    if let shortcutText = shortcutText {
                        Text(shortcutText)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(ForgeTheme.Colors.textTertiary)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(ForgeTheme.Colors.surfaceHover)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 0.5)
                            )
                    }
                    if let gesture = gesture {
                        Text(gesture)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(ForgeTheme.Colors.textTertiary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(
                                Capsule().fill(ForgeTheme.Colors.surfaceHover)
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    ForgeTheme.Colors.borderDefault, lineWidth: 0.5
                                )
                            )
                    }
                }
            }

            Spacer()

            // Enable/disable toggle — binds through @Published enabledStates
            Toggle("", isOn: Binding(
                get: { moduleRegistry.isEnabled(module.id) },
                set: { _ in moduleRegistry.toggleModule(module.id) }
            ))
            .toggleStyle(.forge)
            .controlSize(.mini)
            .tint(ForgeTheme.Colors.accent)
        }
        // Edge-to-edge, matches the calendar tab's zero L/R inset.
        .padding(.vertical, ForgeTheme.Spacing.xs)
        .contentShape(Rectangle())
    }

    private func moduleDisabledView(moduleId: String, name: String, icon: String) -> some View {
        VStack(spacing: ForgeTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(ForgeTheme.Colors.textMuted)

            Text("\(name) is disabled")
                .font(ForgeTheme.Typography.bodyFont)
                .foregroundColor(ForgeTheme.Colors.textMuted)

            ForgeButton("Enable", style: .secondary) {
                moduleRegistry.toggleModule(moduleId)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ForgeTheme.Spacing.xxxl)
    }

    // MARK: - Footer (Dot-style: day progress + command bar shortcut)

    private var footerBar: some View {
        HStack {
            Spacer()
        }
        .padding(.vertical, ForgeTheme.Spacing.sm)
    }

    // MARK: - Helpers

    /// Maps a module's id to the global hotkey binding that activates it (if any).
    /// Static gesture-trigger label for modules whose primary
    /// activation is a hand/key gesture rather than an editable
    /// shortcut. Rendered as a sub-line in the Tools row.
    private func gestureLabel(for moduleId: String) -> String? {
        switch moduleId {
        case "mouseHighlight":   return "Double-tap right ⌘"
        case "fancyZones":       return "Shift + Drag"
        case "textExpander":     return "Type triggers"
        default:                 return nil
        }
    }

    /// Returns the user's current binding as a display string (e.g. "⌃⌥C"), or nil
    /// for modules without a primary shortcut.
    private func shortcutDisplay(for moduleId: String) -> String? {
        let bindingId: String?
        switch moduleId {
        case "colorPicker":      bindingId = "colorPicker"
        case "screenRuler":      bindingId = "screenRuler"
        case "textExtractor":    bindingId = "textExtractor"
        case "zoomIt":           bindingId = "zoomIt"
        case "fancyZones":       bindingId = "fancyZones"
        case "windowManager":    bindingId = "pinWindow"
        case "meetingReminder":  bindingId = "joinMeeting"
        case "screenshotAnnotate": bindingId = "screenshot"
        case "clipboard":        bindingId = "clipboard"
        case "claudeLauncher":   bindingId = "claudeLauncher"
        case "openTerminal":     bindingId = "openTerminal"
        // Mouse Highlight has two flavors: the gesture-driven Find
        // My Mouse (double-tap right ⌘) and the keystroke-driven
        // Click Highlighter (⌘⌥H). Surface the keystroke chip — the
        // gesture appears as a sub-line via `gestureLabel(for:)`.
        case "mouseHighlight":   bindingId = "clickHighlighter"
        // Text Expander has no global hotkey — it activates on type.
        // The Tools row gets a gesture sub-line ("Type triggers").
        default:                 bindingId = nil
        }
        guard let id = bindingId else { return nil }
        let str = settings.binding(for: id).displayString
        return str.isEmpty ? nil : str
    }

    /// Bring Forge to the foreground, open the Settings window, and
    /// raise it. Handles three states:
    ///   1. Settings not open at all  → `openSettings()` builds it.
    ///   2. Settings open + visible behind another app → just raise it.
    ///   3. Settings minimised in the Dock → deminiaturize + raise.
    ///
    /// Two-phase because `openSettings()` doesn't instantiate the
    /// NSWindow synchronously; we have to wait a runloop tick before
    /// the new window appears in `NSApp.windows`.
    private func openSettingsForeground() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let win = Self.findSettingsWindow() else { return }
            if win.isMiniaturized {
                win.deminiaturize(nil)
            }
            // Briefly bump to .floating so the window slides above
            // whatever full-screen app is on top, then settle back to
            // .normal so it behaves like any other window from there.
            win.level = .floating
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                win.level = .normal
            }
        }
    }

    /// Locate Forge's Settings NSWindow. SwiftUI's Settings scene on
    /// macOS 14+ doesn't expose the window directly, so we filter
    /// `NSApp.windows` by what the Settings window IS NOT — popover
    /// frames, status-bar items, panels, etc. The remaining titled,
    /// non-floating NSWindow is the Settings one.
    private static func findSettingsWindow() -> NSWindow? {
        // First pass: explicit title match. SwiftUI titles the
        // Settings window with the localised "Settings" string or the
        // window's `.navigationTitle`. Forge sets a "Forge Settings"
        // header internally; the OS chrome shows just "Settings".
        if let win = NSApp.windows.first(where: { w in
            let t = w.title.lowercased()
            return w.isVisible || w.isMiniaturized
                ? (t.contains("settings") || t.contains("preferences"))
                : false
        }) {
            return win
        }

        // Fallback: pick the largest non-popover, non-panel window
        // currently on screen. Popover internals are NSPanel subclasses
        // and have empty titles; the status-bar window has class
        // `NSStatusBarWindow`. The Settings window is a plain
        // `NSWindow` with a non-empty title and a 1020×660 frame.
        let candidates = NSApp.windows.filter { w in
            guard !(w is NSPanel) else { return false }
            let className = String(describing: type(of: w))
            if className.contains("StatusBar") || className.contains("Popover") {
                return false
            }
            return w.isVisible || w.isMiniaturized
        }
        return candidates.max(by: {
            ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
        })
    }

    private var dayOfWeekString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: Date())
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: Date())
    }

    /// "Mon, Feb 16" — Dot's compact format
    private var dotStyleDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: Date())
    }

    private var eventsTodayString: String {
        if let calendarModule = moduleRegistry.module(ofType: CalendarModule.self) {
            let count = calendarModule.todayEvents.count
            switch count {
            case 0: return "No events today"
            case 1: return "1 event today"
            default: return "\(count) events today"
            }
        }
        return "Today"
    }

    private var dayProgress: Double {
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let secondsSinceStart = now.timeIntervalSince(startOfDay)
        return secondsSinceStart / 86400.0
    }

    private var dayProgressPercent: Int {
        Int(dayProgress * 100)
    }
}

// MARK: - Workday Progress Bar
//
// A thin animated strip between the header and the scroll content.
// Shows how far through the workday you are (9 AM → 6 PM) with
// colored blocks for each meeting, a gradient progress fill, and a
// pulsing current-time dot. Updates every 30 seconds via TimelineView.

private struct WorkdayProgressBar: View {
    let events: [CalendarEvent]

    @State private var pulse = false

    private let workStart: Double = 9.0    // 9 AM
    private let workEnd: Double   = 18.0   // 6 PM

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            barContent(now: ctx.date)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    @ViewBuilder
    private func barContent(now: Date) -> some View {
        let cal = Calendar.current
        let hour = Double(cal.component(.hour, from: now))
            + Double(cal.component(.minute, from: now)) / 60.0
        let progress = max(0, min(1, (hour - workStart) / (workEnd - workStart)))
        let meetings = todayMeetings(on: now)

        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width

                ZStack(alignment: .leading) {
                    // 1. Track background
                    Capsule()
                        .fill(ForgeTheme.Colors.surfaceSubtle)
                        .frame(height: 4)

                    // 2. Elapsed progress fill
                    if progress > 0 {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        ForgeTheme.Colors.accent.opacity(0.35),
                                        ForgeTheme.Colors.accent.opacity(0.55),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, w * progress), height: 4)
                    }

                    // 3. Meeting blocks — colored segments on the track
                    ForEach(meetings) { event in
                        let sx = xFraction(for: event.startDate, cal: cal)
                        let ex = xFraction(for: event.endDate, cal: cal)
                        let blockW = max(3, (ex - sx) * w)
                        let isLive = now >= event.startDate && now < event.endDate

                        RoundedRectangle(cornerRadius: 2)
                            .fill(event.calendarColor.opacity(isLive ? 0.95 : 0.55))
                            .frame(width: blockW, height: 4)
                            .offset(x: sx * w)
                            .shadow(
                                color: isLive
                                    ? event.calendarColor.opacity(pulse ? 0.7 : 0.3)
                                    : .clear,
                                radius: isLive ? 4 : 0
                            )
                    }

                    // 4. Current-time indicator — glowing dot
                    if progress > 0 && progress < 1 {
                        Circle()
                            .fill(ForgeTheme.Colors.accent)
                            .frame(width: 8, height: 8)
                            .shadow(
                                color: ForgeTheme.Colors.accent.opacity(pulse ? 0.7 : 0.25),
                                radius: pulse ? 6 : 3
                            )
                            .offset(x: w * progress - 4, y: 0)
                    }
                }
            }
            .frame(height: 8)   // 4px bar + room for 8px dot

            // Hour markers
            HStack {
                Text("9AM")
                Spacer()
                Text("12PM")
                Spacer()
                Text("3PM")
                Spacer()
                Text("6PM")
            }
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundColor(ForgeTheme.Colors.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    // MARK: Helpers

    private func todayMeetings(on date: Date) -> [CalendarEvent] {
        let cal = Calendar.current
        return events.filter { cal.isDateInToday($0.startDate) && !$0.isAllDay }
    }

    private func xFraction(for date: Date, cal: Calendar) -> CGFloat {
        let h = Double(cal.component(.hour, from: date))
            + Double(cal.component(.minute, from: date)) / 60.0
        return max(0, min(1, (h - workStart) / (workEnd - workStart)))
    }
}

// MARK: - ModuleIconButton
//
// Pulled out into its own struct so each icon can carry its own
// @State for hover without rows fighting over a shared source.
// Renders the icon chip identically in two branches:
//   • triggerable modules — wrapped in a Button that calls
//     AppDelegate.triggerPrimaryAction, with the full hover
//     affordance (ring + tint brighten + scale bump).
//   • non-triggerable modules (Calendar, KeyRemap, TextExpander,
//     etc.) — a plain static image, no hover effects, the cursor
//     reads it as decoration.

private struct ModuleIconButton: View {
    let moduleId: String
    let iconName: String
    let moduleName: String
    let enabled: Bool

    @State private var hovering = false

    private var triggerable: Bool {
        AppDelegate.shared?.hasPrimaryAction(forModuleId: moduleId) ?? false
    }

    var body: some View {
        // We deliberately do NOT wrap the icon in a SwiftUI `Button`
        // here. On macOS, `Button` installs hit-test tracking that
        // can swallow scroll-wheel events inside the popover's
        // NSScrollView-backed container (see ScrollableContainer.swift)
        // — that breaks vertical scroll on the Tools tab. A bare
        // `.contentShape(Rectangle()) + .onTapGesture` gives the same
        // click behavior without interfering with scroll.
        Group {
            if triggerable {
                iconChip
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .onTapGesture {
                        _ = AppDelegate.shared?
                            .triggerPrimaryAction(forModuleId: moduleId)
                    }
                    .help("Run \(moduleName)")
            } else {
                iconChip
            }
        }
    }

    private var iconChip: some View {
        Image(systemName: iconName)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(
                enabled
                    ? ForgeTheme.Colors.accent
                    : ForgeTheme.Colors.textMuted
            )
            .frame(
                width: ForgeTheme.Layout.moduleIconSize,
                height: ForgeTheme.Layout.moduleIconSize
            )
            .background(
                Group {
                    if enabled {
                        ForgeTheme.Colors.accent.opacity(hovering ? 0.18 : 0.08)
                    } else {
                        ForgeTheme.Colors.surfaceHover.opacity(hovering ? 1.6 : 1.0)
                    }
                }
            )
            .cornerRadius(ForgeTheme.Radius.small)
            .overlay(
                RoundedRectangle(cornerRadius: ForgeTheme.Radius.small)
                    .stroke(
                        hovering ? ForgeTheme.Colors.accent.opacity(0.6) : Color.clear,
                        lineWidth: 1
                    )
            )
            .scaleEffect(hovering ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

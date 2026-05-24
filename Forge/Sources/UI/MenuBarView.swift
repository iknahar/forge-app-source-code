import SwiftUI

/// The main popover view that appears when clicking the menu bar icon.
/// This is Forge's "home screen" — the calendar is the default view.
/// Width: 360pt. Matches Dot's warm cream aesthetic (#FDFBF7),
/// toggle pills for tab switching, progress bar footer.
struct MenuBarView: View {
    @EnvironmentObject var moduleRegistry: ModuleRegistry
    @EnvironmentObject var settings: SettingsManager
    @State private var selectedTab: Tab = .calendar
    @State private var isHoveringSettings = false

    enum Tab: String, CaseIterable {
        case calendar = "Calendar"
        case tools = "Tools"
    }

    var body: some View {
        bodyContent
            .preferredColorScheme(settings.theme.colorScheme)
    }

    private var bodyContent: some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar

            // Subtle divider (Dot: border-black/[0.04])
            Rectangle()
                .fill(ForgeTheme.Colors.borderSubtle)
                .frame(height: 1)

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

            // Settings gear — Dot's subtle icon button (modern SettingsLink for macOS 14+)
            SettingsLink {
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
    private static let hiddenModuleIds: Set<String> = ["calendar", "commandPalette"]

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
        return HStack(alignment: .top, spacing: ForgeTheme.Spacing.md) {
            // Module icon — Dot's colored icon in subtle bg
            Image(systemName: module.iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(
                    enabled
                        ? ForgeTheme.Colors.accent
                        : ForgeTheme.Colors.textMuted
                )
                .frame(width: ForgeTheme.Layout.moduleIconSize,
                       height: ForgeTheme.Layout.moduleIconSize)
                .background(
                    enabled
                        ? ForgeTheme.Colors.accent.opacity(0.08)
                        : ForgeTheme.Colors.surfaceHover
                )
                .cornerRadius(ForgeTheme.Radius.small)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(module.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)

                // Shortcut hint — Dot-style monospaced pill (description removed
                // to keep rows compact and avoid scroll overflow)
                if let shortcutText = shortcutText {
                    Text(shortcutText)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(ForgeTheme.Colors.textTertiary)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.black.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                        )
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
            // Footer reserved — both day progress and the Command Bar hint
            // have been removed per the latest design decisions.
            Spacer()
        }
        // Footer matches calendar / tools at zero L/R inset.
        .padding(.vertical, ForgeTheme.Spacing.sm)
    }

    // MARK: - Helpers

    /// Maps a module's id to the global hotkey binding that activates it (if any).
    /// Returns the user's current binding as a display string (e.g. "⌃⌥C"), or nil
    /// for modules without a primary shortcut.
    private func shortcutDisplay(for moduleId: String) -> String? {
        let bindingId: String?
        switch moduleId {
        case "commandPalette":   bindingId = "commandPalette"
        case "colorPicker":      bindingId = "colorPicker"
        case "screenRuler":      bindingId = "screenRuler"
        case "textExtractor":    bindingId = "textExtractor"
        case "zoomIt":           bindingId = "zoomIt"
        case "fancyZones":       bindingId = "fancyZones"
        case "windowManager":    bindingId = "alwaysOnTop"
        case "meetingReminder":  bindingId = "joinMeeting"
        case "screenshotAnnotate": bindingId = "screenshot"
        case "mouseHighlight":   bindingId = "mouseHighlight"
        default:                 bindingId = nil
        }
        guard let id = bindingId else { return nil }
        let str = settings.binding(for: id).displayString
        return str.isEmpty ? nil : str
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

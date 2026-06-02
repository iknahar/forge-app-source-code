import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Custom toggle (iOS-style capsule with spring)

struct ForgeToggleStyle: ToggleStyle {
    var tint: Color = ForgeTheme.Colors.accent

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Capsule()
                .fill(configuration.isOn ? tint : Color.black.opacity(0.13))
                .frame(width: 36, height: 20)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.8)
                        .padding(2)
                        .offset(x: configuration.isOn ? 8 : -8)
                )
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

extension ToggleStyle where Self == ForgeToggleStyle {
    static var forge: ForgeToggleStyle { ForgeToggleStyle() }
}

/// Forge Preferences — 960×660, top tabs + live preview pane.
/// Rich visual design: hero headers, layered cards, accent CTAs.
struct SettingsView: View {
    @EnvironmentObject var moduleRegistry: ModuleRegistry
    @EnvironmentObject var settings: SettingsManager
    @State private var selectedSection: SettingsSection = .general

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general      = "General"
        case calendar     = "Calendar"
        case eyeCare      = "Eye Care"
        case launchers    = "Launchers"
        case keyRemap     = "Key Remap"
        case textExpander = "Text Expander"
        case menuBar      = "Menu Bar"
        case shortcuts    = "Shortcuts"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .general:      return "gearshape.fill"
            case .calendar:     return "calendar"
            case .eyeCare:      return "eye.fill"
            case .launchers:    return "bolt.fill"
            case .keyRemap:     return "keyboard"
            case .textExpander: return "text.cursor"
            case .menuBar:      return "menubar.rectangle"
            case .shortcuts:    return "keyboard.fill"
            }
        }

        var subtitle: String {
            switch self {
            case .general:      return "Appearance, time format, and startup behavior."
            case .calendar:     return "Meeting reminders, focus signals, and connected calendars."
            case .eyeCare:      return "20-20-20 breaks plus warm-tint screen filter to ease eye strain."
            case .launchers:    return "Bind a shortcut to open any app, document, or URL."
            case .keyRemap:     return "Remap any key combo to another, system-wide or per-app."
            case .textExpander: return "Type a trigger, get an expansion. Like aText / TextExpander."
            case .menuBar:      return "Compose what shows next to the hammer icon."
            case .shortcuts:    return "Toggle, re-record, or disable any Forge action. Changes register live."
            }
        }
    }

    @State private var previewIsDark: Bool = false

    private func pickReminderBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Pick a fullscreen reminder background"
        if panel.runModal() == .OK, let url = panel.url {
            settings.reminderBackgroundImagePath = url.path
        }
    }

    /// Description text for the "Fullscreen background" row. Shows
    /// the currently-picked image filename (so the user can confirm
    /// what's loaded) or the default-state hint when no custom image
    /// is set. Living in the row's description slot — instead of as
    /// a separate trailing Text — lets the action buttons sit in the
    /// same column as the dropdowns above.
    private var fullscreenBackgroundDescription: String {
        if let path = settings.reminderBackgroundImagePath {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return "Currently: \(name)"
        }
        return "Pick a wallpaper for the fullscreen alert."
    }

    /// Shared trailing-control width for the Meeting Reminders card —
    /// every row's control container is this wide so all of them end
    /// at the same X coordinate. Wide enough to fit "Full Screen" +
    /// the chevron with breathing room, and to fit `Reset` + `Pick…`
    /// side by side without overflow.
    private static let reminderControlWidth: CGFloat = 150

    /// Wrap a `Picker` so its menu button stretches to fill
    /// `reminderControlWidth`. SwiftUI's `Picker(.menu)` ignores raw
    /// `.frame(width:)` and shrinks to the selected text, which made
    /// the two pickers in the Meeting Reminders card render at
    /// different widths and at different right edges than the buttons
    /// row. The combination here pushes the picker to fill the
    /// container AND nudges the whole 14pt right so its visible
    /// chevron lines up with the `Pick…` button below — the menu
    /// button draws its rounded-rect chevron inset from its frame's
    /// trailing edge by ~14pt, so the offset closes that gap.
    @ViewBuilder
    private func fixedWidthPicker<P: View>(@ViewBuilder content: () -> P) -> some View {
        HStack(spacing: 0) {
            // `Spacer()` here is SwiftUI's "space between" — pushes
            // the picker to the trailing edge of the wrapper, the
            // way flexbox `justify-content: space-between` does.
            // Combined with the Picker's own `.frame(maxWidth: .infinity)`
            // below, this makes the menu button stretch from the
            // trailing edge inward.
            Spacer(minLength: 0)
            content()
                .frame(maxWidth: .infinity)
        }
        .frame(width: Self.reminderControlWidth)
        // Same trailing-nudge for every picker that uses this helper.
        // Centralized here so both rows shift identically — earlier
        // the offset was only on the second picker, which made the
        // two visually out of step with each other.
        .offset(x: 14)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top tab bar (replaces sidebar)
            SettingsTopTabs(selected: $selectedSection)
                .background(ForgeTheme.Colors.pageBgWarm)
                .overlay(
                    Rectangle()
                        .fill(Color.black.opacity(0.06))
                        .frame(height: 1),
                    alignment: .bottom
                )

            // Main split: settings (left) + preview (right)
            HStack(spacing: 0) {
                // Text Expander manages its own two-column scrolls
                // internally — wrapping it in the parent NSScrollView
                // gives it unbounded height, which makes the inner
                // tree + detail scrolls never engage. Render it
                // OUTSIDE the ScrollableContainer so its frame is
                // exactly the window height, and the inner panes can
                // each scroll within their bounds.
                if selectedSection == .textExpander {
                    textExpanderSettings
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(ForgeTheme.Colors.pageBg)
                } else {
                    // Settings content — NSScrollView-backed for reliable scroll wheel.
                    // .frame(maxWidth: .infinity) is critical so the scroll-view
                    // wrapper expands to fill the remaining HStack width instead of
                    // shrinking to its intrinsic 0pt size and getting clipped by
                    // the preview pane on the right.
                    ScrollableContainer {
                        VStack(alignment: .leading, spacing: 24) {
                            SectionHero(
                                title: selectedSection.rawValue,
                                subtitle: selectedSection.subtitle
                            )

                            Group {
                                switch selectedSection {
                                case .general:      generalSettings
                                case .calendar:     calendarSettings
                                case .eyeCare:      eyeCareSettings
                                case .launchers:    launchersSettings
                                case .keyRemap:     keyRemapSettings
                                case .textExpander: EmptyView()
                                case .menuBar:      menuBarSettings
                                case .shortcuts:    shortcutsSettings
                                }
                            }
                        }
                        // Tighter horizontal padding (was 28) so cards have more
                        // room — the preview pane was eating into the content.
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ForgeTheme.Colors.pageBg)
                }

                // Preview pane (right) — shown ONLY on the Calendar and
                // Menu Bar tabs (the two surfaces where users actively
                // shape the appearance and a live preview is genuinely
                // useful). Other tabs hide it so the content area
                // claims the full window width.
                let showsPreview: Bool = {
                    switch selectedSection {
                    case .calendar, .menuBar: return true
                    default:                  return false
                    }
                }()
                if showsPreview {
                    // Calendar's mini-month grid + progress strips +
                    // world-clock row need more horizontal room than
                    // the Menu Bar pill does. We carve out an extra
                    // 40pt for Calendar specifically; the left panel
                    // shrinks correspondingly but its cards are all
                    // fluid (`maxWidth: .infinity`) so none of the
                    // controls clip. Overall window width is unchanged.
                    let paneWidth: CGFloat = (selectedSection == .calendar) ? 320 : 280
                    SettingsPreviewPane(
                        section: selectedSection,
                        settings: settings,
                        moduleRegistry: moduleRegistry,
                        previewIsDark: $previewIsDark
                    )
                    .frame(width: paneWidth)
                    .background(ForgeTheme.Colors.pageBgWarm.opacity(0.6))
                    .overlay(
                        Rectangle()
                            .fill(ForgeTheme.Colors.borderDefault)
                            .frame(width: 1),
                        alignment: .leading
                    )
                }
            }
        }
        // Widened (was 960) to give every tab room for both settings content
        // and the live preview pane without things getting clipped.
        .frame(width: 1020, height: 660)
        .background(ForgeTheme.Colors.pageBg)
        .preferredColorScheme(settings.theme.colorScheme)
    }

    // MARK: - General

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(
                title: "Appearance",
                description: "Match the system, or force a theme."
            ) {
                SettingRow(
                    icon: "paintpalette.fill",
                    iconTint: .purple,
                    title: "Theme",
                    description: "Affects popover, settings, and command palette."
                ) {
                    ForgeSegmentedPicker(
                        selection: $settings.theme,
                        options: SettingsManager.AppTheme.allCases.map {
                            (label: $0.rawValue, value: $0)
                        }
                    )
                    .frame(width: 220)
                }
            }

            // 2x2 layout: each card holds two SettingRows side by side
            // instead of stacked vertically. More compact — the General
            // tab now fits without scrolling, and the eye reads the
            // related controls (24h + Launch) as one pair instead of
            // two separate stops.
            SettingsCard(title: "Behavior") {
                HStack(alignment: .top, spacing: 18) {
                    SettingRow(
                        icon: "clock.fill",
                        iconTint: .blue,
                        title: "Use 24-hour time",
                        description: "Affects calendar, world clock, and meeting countdowns."
                    ) {
                        Toggle("", isOn: $settings.use24HourTime)
                            .toggleStyle(.forge)
                            .labelsHidden()
                            .tint(ForgeTheme.Colors.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().frame(maxHeight: 56).opacity(0.3)

                    SettingRow(
                        icon: "power",
                        iconTint: .green,
                        title: "Launch at login",
                        description: "Forge starts automatically when you sign in."
                    ) {
                        LaunchAtLoginToggle()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Screen Translator — defaults for the translate button in
            // the screenshot toolbar. The on-the-fly chip there can still
            // override these per-capture.
            SettingsCard(
                title: "Screen Translator",
                titleIcon: "globe",
                description: "When you press ⌃⌥S and click the globe button, Forge OCRs your selection and translates it. These are the default source / target languages — you can override them on the fly from the toolbar chip."
            ) {
                HStack(alignment: .top, spacing: 18) {
                    SettingRow(
                        icon: "text.viewfinder",
                        iconTint: .indigo,
                        title: "Detect text in",
                        description: "Source language — pick \"Auto-detect\" to let Forge guess."
                    ) {
                        Picker("", selection: $settings.translateSourceLanguage) {
                            ForEach(ScreenTranslator.supportedLanguages, id: \.code) { lang in
                                Text(lang.label).tag(lang.code)
                            }
                        }
                        .labelsHidden()
                        // Narrower than the previous 200pt — needs to
                        // share the row with the other Picker now.
                        .frame(width: 140)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().frame(maxHeight: 56).opacity(0.3)

                    SettingRow(
                        icon: "character.bubble.fill",
                        iconTint: ForgeTheme.Colors.accent,
                        title: "Translate to",
                        description: "Target language for the translated output."
                    ) {
                        Picker("", selection: $settings.translateTargetLanguage) {
                            ForEach(ScreenTranslator.supportedLanguages.filter { $0.code != "auto" },
                                    id: \.code) { lang in
                                Text(lang.label).tag(lang.code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // About footer — replaces the standalone About tab.
            // Compact strip with the wordmark, version chip, tagline,
            // and the three local-first promises.
            aboutFooter
        }
    }

    /// Small inline About strip rendered at the bottom of the
    /// General settings page. Lifts the core pieces of the old
    /// standalone About tab (logo, name, version, tagline, the
    /// three "no telemetry / no accounts / local storage" facts)
    /// without the 96pt hero treatment — this is a footer, not a
    /// landing page.
    private var aboutFooter: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ForgeTheme.Colors.accent.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "hammer.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.accent)
                    .rotationEffect(.degrees(-12))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Forge")
                        .font(.system(size: 14, weight: .bold))
                    Text("v1.0.0")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ForgeTheme.Colors.accent.opacity(0.15))
                        .foregroundColor(ForgeTheme.Colors.accent)
                        .clipShape(Capsule())
                }
                Text("Local-first. No telemetry. No accounts. Storage stays on your Mac.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium)
                .fill(ForgeTheme.Colors.surfaceHover.opacity(0.45))
        )
    }

    // MARK: - Calendar

    private var calendarSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(
                title: "Calendar Display",
                titleIcon: "calendar",
                description: "Tune how the calendar popover looks. Changes apply instantly."
            ) {
                VStack(spacing: 10) {
                    SettingRow(icon: "chart.bar.fill", iconTint: .blue,
                               title: "Year progress bar",
                               description: "Show % of the year complete at the top.") {
                        Toggle("", isOn: $settings.showYearProgress)
                            .toggleStyle(.forge).labelsHidden().tint(ForgeTheme.Colors.accent)
                    }
                    Divider().opacity(0.3)
                    SettingRow(icon: "clock.badge.checkmark.fill", iconTint: .cyan,
                               title: "Day progress bar",
                               description: "Show % of today elapsed + time left.") {
                        Toggle("", isOn: $settings.showDayProgress)
                            .toggleStyle(.forge).labelsHidden().tint(ForgeTheme.Colors.accent)
                    }
                    Divider().opacity(0.3)
                    SettingRow(icon: "globe.americas.fill", iconTint: .green,
                               title: "World clock",
                               description: "Time zone strip at the bottom of the popover.") {
                        Toggle("", isOn: $settings.showWorldClock)
                            .toggleStyle(.forge).labelsHidden().tint(ForgeTheme.Colors.accent)
                    }
                    Divider().opacity(0.3)
                    SettingRow(icon: "number", iconTint: .indigo,
                               title: "Week numbers",
                               description: "ISO week number on the left of each row.") {
                        Toggle("", isOn: $settings.showWeekNumbers)
                            .toggleStyle(.forge).labelsHidden().tint(ForgeTheme.Colors.accent)
                    }
                    // Highlight today / Dim weekends / Event-dot style
                    // used to be three additional rows here. Removed —
                    // those behaviors are now always-on with sensible
                    // defaults: today is always highlighted, weekends
                    // are always dimmed (using the trailing two columns
                    // regardless of week-start), and event dots always
                    // render in the multi-dot style. Less to fiddle
                    // with, less to think about.
                    Divider().opacity(0.3)
                    SettingRow(icon: "calendar.day.timeline.left", iconTint: .pink,
                               title: "Week starts on",
                               description: "First column of the calendar grid.") {
                        ForgeSegmentedPicker(
                            selection: $settings.weekStartsOnMonday,
                            options: [
                                (label: "Sun", value: false),
                                (label: "Mon", value: true),
                            ]
                        )
                        .frame(width: 140)
                    }
                }
            }

            SettingsCard(
                title: "World Clock",
                titleIcon: "globe.americas.fill",
                description: "Cities shown in the strip at the bottom of the calendar popover."
            ) {
                WorldClockEditor(settings: settings)
            }

            SettingsCard(
                title: "Meeting Reminders",
                titleIcon: "bell.badge.fill",
                description: "Show a reminder before each meeting begins."
            ) {
                VStack(spacing: 14) {
                    // All three rows pin their trailing control inside
                    // a `Self.reminderControlWidth`-pt container so the
                    // right edges line up exactly. `fixedWidthPicker`
                    // wraps a Picker in an HStack with a leading Spacer
                    // — this forces the menu button to stretch to fill
                    // the container's width (Picker(.menu) ignores raw
                    // `.frame(width:)` and shrinks to content). The
                    // buttons row uses the same trailing width so its
                    // rightmost button sits at the identical X.
                    SettingRow(
                        icon: "clock.arrow.circlepath",
                        iconTint: .orange,
                        title: "Remind me",
                        description: "How far ahead the prompt appears."
                    ) {
                        // 150pt frame goes directly on the Picker
                        // itself (not on a wrapper HStack like the
                        // Full Screen row uses) — so the picker is
                        // the 150pt-wide child, trailing-aligned
                        // inside the SettingRow's natural-width
                        // parent. Plus a 1pt nudge to land its
                        // chevron at the same X as the controls below.
                        Picker("", selection: $settings.meetingReminderMinutes) {
                            Text("At start").tag(0)
                            Text("1 min").tag(1)
                            Text("5 min").tag(5)
                            Text("10 min").tag(10)
                            Text("15 min").tag(15)
                        }
                        .labelsHidden()
                        .frame(width: 150, alignment: .trailing)
                        .offset(x: 1)
                    }

                    Divider().opacity(0.3)

                    SettingRow(
                        icon: "rectangle.center.inset.filled",
                        iconTint: .pink,
                        title: "Reminder style",
                        description: "How the prompt presents itself."
                    ) {
                        fixedWidthPicker {
                            Picker("", selection: $settings.meetingReminderStyle) {
                                ForEach(SettingsManager.ReminderStyle.allCases, id: \.self) { style in
                                    Text(style.rawValue).tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }

                    // Full-screen background image picker — only meaningful
                    // when style is Full Screen; row still shows in both
                    // modes so the user can preset it.
                    // Fullscreen background only matters when the
                    // reminder style is `.fullscreen`. When the user
                    // is on Floating, this row is greyed out and
                    // non-interactive — but stays visible so the user
                    // can see the option exists for the other style.
                    let isFullScreen = settings.meetingReminderStyle == .fullscreen
                    Divider().opacity(0.3)
                    SettingRow(
                        icon: "photo.fill",
                        iconTint: .indigo,
                        title: "Fullscreen background",
                        // The filename used to render to the right of
                        // the buttons, which pushed Pick/Reset away
                        // from the column the dropdowns above align
                        // to. Surface it in the description instead
                        // so the action buttons sit in the same
                        // vertical column as the pickers.
                        description: fullscreenBackgroundDescription
                    ) {
                        // Same fixed-width trailing container as the
                        // two pickers above. The buttons sit at the
                        // right edge of this `reminderControlWidth`
                        // box; the Pick button is custom-styled at the
                        // exact same height as the Pickers (~22pt) so
                        // the visual row reads as a uniform column.
                        HStack(spacing: 6) {
                            if settings.reminderBackgroundImagePath != nil {
                                Button("Reset") {
                                    settings.reminderBackgroundImagePath = nil
                                }
                            }
                            Button { pickReminderBackground() } label: {
                                Text("Pick…")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 4)
                            }
                            .background(ForgeTheme.Colors.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .buttonStyle(.plain)
                        }
                        .frame(width: Self.reminderControlWidth, alignment: .trailing)
                    }
                    // Grey out + block clicks when the user has picked
                    // Floating — there's no fullscreen surface to put a
                    // background image on in that mode. The row stays
                    // visible so the option is discoverable, just
                    // visibly inert.
                    .disabled(!isFullScreen)
                    .opacity(isFullScreen ? 1 : 0.45)
                }
            }

            // Linked Calendars removed — Google native + EventKit is the single
            // source of truth now. Color is picked when connecting Google;
            // EventKit calendars use their native colors.

            SettingsCard(
                title: "Google Calendar (Native)",
                titleIcon: "g.circle.fill",
                description: "Sign into Google to give Forge native access — needed for declining meetings with a note, and richer event editing."
            ) {
                GoogleAccountsEditor()
            }
        }
    }


    // MARK: - Key Remap

    /// Settings panel for the Key Remap module — lets the user view
    /// existing key→key mappings, toggle them, delete them, and add new
    /// ones via a capture sheet. The actual remapping logic lives in
    /// `KeyRemapModule` (a CGEventTap that's already running); this UI
    /// just CRUDs the `remappings` array on the module.
    /// Eye Care settings page — combined Pomodoro/20-20-20 timer
    /// plus screen-filter (color temp + brightness) controls. Lives
    /// inside `EyeCareSettingsView`; this wrapper just locates the
    /// live module instance from the registry and degrades gracefully
    /// if it's not present (shouldn't happen in production, but the
    /// fallback keeps the page from crashing in previews).
    private var eyeCareSettings: some View {
        Group {
            if let module = moduleRegistry.module(ofType: EyeCareModule.self) {
                EyeCareSettingsView(module: module)
            } else {
                Text("Eye Care module is not registered.")
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Launchers settings page — list of user-defined shortcuts
    /// bound to app / document / URL targets.
    private var launchersSettings: some View {
        Group {
            if let module = moduleRegistry.module(ofType: LaunchersModule.self) {
                LaunchersSettingsView(module: module)
            } else {
                Text("Launchers module is not registered.")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var keyRemapSettings: some View {
        // Look up the module from the registry. We render the UI lazily
        // and gracefully degrade if KeyRemap isn't registered for some
        // reason (e.g. user disabled it via the Modules tab).
        Group {
            if let module = moduleRegistry.module(ofType: KeyRemapModule.self) {
                KeyRemapEditor(module: module)
            } else {
                Text("Key Remap module is unavailable.")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Text Expander

    /// Settings panel for the Text Expander module. Same pattern as
    /// Key Remap above — look up the module lazily, render its
    /// dedicated SwiftUI editor, fall back to a placeholder if it
    /// isn't registered.
    private var textExpanderSettings: some View {
        Group {
            if let module = moduleRegistry.module(ofType: TextExpanderModule.self) {
                TextExpanderSettingsView(module: module)
            } else {
                Text("Text Expander module is unavailable.")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Menu Bar

    private var menuBarSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(
                title: "Menu Bar Icon",
                titleIcon: "face.smiling",
                description: "Pick any emoji to replace the default hammer in the menu bar. Press Ctrl + ⌘ + Space inside the field for the emoji picker."
            ) {
                MenuBarEmojiEditor(settings: settings)
            }

            SettingsCard(
                title: "Build your menu bar",
                titleIcon: "menubar.rectangle",
                description: "Mix and match tokens — date, event, countdown, progress bars, clock — in any combo."
            ) {
                MenuBarTokenGrid(settings: settings)
            }

            SettingsCard(
                title: "Time format",
                titleIcon: "clock.fill",
                description: "Used by the Time and World Clock tokens. Standard NSDateFormatter syntax."
            ) {
                MenuBarFormatEditor(settings: settings)
            }

            SettingsCard(
                title: "Separator",
                titleIcon: "ellipsis"
            ) {
                MenuBarSeparatorEditor(settings: settings)
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Lead-in helper — each row in the cards below has its
            // own description, so we only need a single overall hint.
            HStack(spacing: 6) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 11))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                Text("Toggle to enable / disable. Click a binding to record a new combo, Escape to cancel. Gesture rows show their built-in trigger.")
                    .font(.system(size: 11))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
            }
            .padding(.horizontal, 4)

            // One card per group — gestures live inline in their own
            // group's card so related actions stay together. Empty
            // groups are skipped so we don't show ghost cards if a
            // group's actions are ever removed.
            ForEach(ShortcutBinding.ShortcutGroup.allCases) { group in
                let actions = ShortcutBinding.actions(in: group)
                if !actions.isEmpty {
                    SettingsCard(
                        title: group.rawValue,
                        titleIcon: group.iconName
                    ) {
                        VStack(spacing: 0) {
                            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                                if index > 0 {
                                    Divider().opacity(0.3)
                                }
                                ShortcutRow(action: action, settings: settings)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    settings.resetAllBindings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset all to defaults")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ForgeTheme.Colors.accent.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - About

}

// MARK: - Top Tab Bar

private struct SettingsTopTabs: View {
    @Binding var selected: SettingsView.SettingsSection

    var body: some View {
        HStack(spacing: 4) {
            // Forge logo (no text — squircle with white hammer)
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ForgeTheme.Colors.accent)
                    .frame(width: 28, height: 28)
                Image(systemName: "hammer.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(-12))   // playful tilt — feels more "forge"
            }
            .padding(.trailing, 10)

            // Tabs
            ForEach(SettingsView.SettingsSection.allCases) { section in
                TopTabButton(
                    section: section,
                    isSelected: selected == section,
                    action: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selected = section
                        }
                    }
                )
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct TopTabButton: View {
    let section: SettingsView.SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: section.iconName)
                    .font(.system(size: 11, weight: .semibold))
                Text(section.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(
                isSelected
                    ? ForgeTheme.Colors.accent
                    : (hovering ? .primary : .secondary)
            )
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        isSelected
                            ? ForgeTheme.Colors.accent.opacity(0.13)
                            : (hovering ? Color.black.opacity(0.04) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Preview pane

private struct SettingsPreviewPane: View {
    let section: SettingsView.SettingsSection
    @ObservedObject var settings: SettingsManager
    @ObservedObject var moduleRegistry: ModuleRegistry
    @Binding var previewIsDark: Bool

    var body: some View {
        // Calendar gets a bit more breathing room: the mini-month grid
        // needs about 280pt of pure card real estate, plus 20pt of
        // padding on each side so it doesn't touch the pane edges.
        let horizontalPadding: CGFloat = (section == .calendar) ? 22 : 18

        return VStack(spacing: 0) {
            // Header — just the "PREVIEW" label; previews always follow the
            // app's actual theme (no separate sun/moon override).
            HStack {
                Text("Preview")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, 14)

            // Per-section preview body — wrapped in a left-aligned full-
            // width container so each preview sits flush left and spans
            // the whole pane (no centered pills with cut edges).
            VStack(alignment: .leading, spacing: 14) {
                switch section {
                case .general:      GeneralPreview(settings: settings, isDark: previewIsDark)
                case .calendar:     CalendarPreviewCard(settings: settings, isDark: previewIsDark)
                case .eyeCare:      EmptyView()
                case .launchers:    EmptyView()
                case .keyRemap:     EmptyView()
                case .textExpander: EmptyView()
                case .menuBar:      MenuBarPreview(settings: settings, isDark: previewIsDark)
                case .shortcuts:    ShortcutsPreview(settings: settings, isDark: previewIsDark)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: section)

            Spacer()

            Text("Changes apply instantly")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Per-section preview cards

/// Common card wrapper for the preview content. Uses the adaptive
/// `surfaceCard` token so it stays visually consistent with the rest of the
/// Settings window regardless of the preview's sun/moon toggle.
///
/// The card stretches to fill the preview pane width (minus the pane's
/// own horizontal padding) instead of being locked at a fixed 280pt
/// — that way the Calendar tab's wider pane gives the mini-month grid
/// the room it needs without leaving an awkward gutter on the right.
private struct PreviewCard<Content: View>: View {
    let isDark: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ForgeTheme.Colors.surfaceCard)
                    .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
            )
    }
}

private struct GeneralPreview: View {
    @ObservedObject var settings: SettingsManager
    let isDark: Bool
    var body: some View {
        PreviewCard(isDark: isDark) {
            VStack(alignment: .leading, spacing: 10) {
                Text("APPEARANCE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundColor(.secondary)
                HStack {
                    Text("Theme")
                        .font(.system(size: 11))
                        .foregroundColor(isDark ? .white : .primary)
                    Spacer()
                    Text(settings.theme.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.accent)
                }
                Divider().opacity(0.2)
                HStack {
                    Text("24-hour time")
                        .font(.system(size: 11))
                        .foregroundColor(isDark ? .white : .primary)
                    Spacer()
                    Text(settings.use24HourTime ? "On" : "Off")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(settings.use24HourTime ? ForgeTheme.Colors.accent : .secondary)
                }
            }
            .padding(16)
        }
    }
}


private struct CalendarPreviewCard: View {
    @ObservedObject var settings: SettingsManager
    let isDark: Bool
    /// Real system color scheme — the `isDark` param is a leftover from
    /// when the preview had a sun/moon toggle. We now follow the actual
    /// app theme so the pill blends with the rest of the Settings
    /// window instead of glowing white in dark mode.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            // Mini menu bar
            HStack(spacing: 6) {
                if settings.menuBarEmoji.isEmpty {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                } else {
                    Text(settings.menuBarEmoji).font(.system(size: 11))
                }
                Text(menuBarText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(
                Capsule().fill(ForgeTheme.Colors.surfaceCard)
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                        radius: 4, y: 1
                    )
            )
            .overlay(
                Capsule().strokeBorder(ForgeTheme.Colors.borderDefault, lineWidth: 0.5)
            )

            PreviewCard(isDark: isDark) {
                MiniCalendarPreview(settings: settings, isDark: isDark)
            }
        }
    }
    private var menuBarText: String {
        let f = DateFormatter()
        f.dateFormat = settings.use24HourTime ? "EEE, d MMM · HH:mm" : "EEE, d MMM · h:mm a"
        return f.string(from: Date())
    }
}

private struct MenuBarPreview: View {
    @ObservedObject var settings: SettingsManager
    let isDark: Bool
    /// Follow the real app theme — see `CalendarPreviewCard` for why
    /// the `isDark` param is no longer enough.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Left-aligned, full-width preview card. Content inside the pill
        // can wrap to a second line via lineLimit(nil) so a wide token list
        // never gets clipped at the right edge.
        VStack(alignment: .leading, spacing: 10) {
            Text("MENU BAR")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.7)
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                if settings.menuBarEmoji.isEmpty {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ForgeTheme.Colors.accent)
                } else {
                    Text(settings.menuBarEmoji).font(.system(size: 13))
                }
                Text(tokenLine)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(ForgeTheme.Colors.surfaceCard)
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.35 : 0.1),
                        radius: 6, y: 2
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(ForgeTheme.Colors.borderDefault, lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// All non-icon tokens joined with the user's chosen separator —
    /// rendered as a single Text so the line can wrap cleanly.
    private var tokenLine: String {
        settings.menuBarTokens
            .filter { $0 != .icon }
            .map { tokenSample($0) }
            .filter { !$0.isEmpty }
            .joined(separator: settings.menuBarSeparator)
    }
    private func tokenSample(_ token: SettingsManager.MenuBarToken) -> String {
        let now = Date()
        switch token {
        case .icon:            return ""
        case .date:            let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: now)
        case .clock:           let f = DateFormatter(); f.dateFormat = settings.menuBarTimeFormat; return f.string(from: now)
        case .ongoingMeeting:  return "● Design Review · 23m left"
        case .nextEvent:       return "Standup · 12m"
        case .countdown:       return "12m"
        case .weekNumber:
            var c = Calendar(identifier: .iso8601)
            c.firstWeekday = settings.weekStartsOnMonday ? 2 : 1
            return "W\(c.component(.weekOfYear, from: now))"
        case .dayProgress:     return "57%"
        case .yearProgress:    return "32%"
        case .worldClock:      return "STK 14:34"
        case .timeLeft:        return "23m left"
        case .eventsLeft:      return "3 left"
        case .focusTime:       return "2h focus"
        }
    }
}

private struct ShortcutsPreview: View {
    @ObservedObject var settings: SettingsManager
    let isDark: Bool
    var body: some View {
        PreviewCard(isDark: isDark) {
            VStack(spacing: 8) {
                ForEach(ShortcutBinding.allActions.prefix(5), id: \.id) { action in
                    HStack {
                        Text(action.name)
                            .font(.system(size: 11))
                            .foregroundColor(isDark ? .white : .primary)
                        Spacer()
                        Text(settings.binding(for: action.id).displayString)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.05)))
                    }
                }
            }.padding(14)
        }
    }
}

private struct AboutPreview: View {
    let isDark: Bool
    var body: some View {
        PreviewCard(isDark: isDark) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ForgeTheme.Colors.accent)
                        .frame(width: 60, height: 60)
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                        .rotationEffect(.degrees(-12))
                }
                Text("Forge").font(.system(size: 16, weight: .bold))
                    .foregroundColor(isDark ? .white : .primary)
                Text("v1.0.0").font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }.padding(.vertical, 20).padding(.horizontal, 14)
        }
    }
}

private struct PreviewModeChip: View {
    let icon: String
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isOn ? ForgeTheme.Colors.accent : .secondary)
                .frame(width: 26, height: 22)
                .background(isOn ? Color.white : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct MiniCalendarPreview: View {
    @ObservedObject var settings: SettingsManager
    let isDark: Bool
    /// Real system color scheme — the `isDark` parameter is a leftover
    /// from when the preview pane had its own sun/moon toggle. The
    /// preview now follows the actual app theme so day numbers stay
    /// readable on a dark surface.
    @Environment(\.colorScheme) private var colorScheme

    private var fg: Color { ForgeTheme.Colors.textPrimary }
    private var fgMuted: Color { ForgeTheme.Colors.textTertiary }
    private var fgFaint: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.22)
            : Color.black.opacity(0.22)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Progress strips
            if settings.showYearProgress {
                miniProgressRow(label: "\(Int(yearProgress * 100))% of \(yearString)",
                                value: yearProgress)
            }
            if settings.showDayProgress {
                miniProgressRow(label: "\(Int(dayProgress * 100))% of today",
                                value: dayProgress)
            }

            // Month label
            Text(monthString)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(fg)
                .padding(.top, 2)

            // Day headers
            let headers = settings.weekStartsOnMonday
                ? ["M","T","W","T","F","S","S"]
                : ["S","M","T","W","T","F","S"]
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { idx, d in
                    Text(d)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(isWeekendIdx(idx) ? fgMuted.opacity(0.6) : fgMuted)
                        .frame(maxWidth: .infinity)
                }
            }

            // Full month grid — 6 rows × 7 columns of the current month.
            // Out-of-month days are dimmed so the focus stays on the
            // current month while the grid still reads as a real
            // calendar (matches the popover behavior).
            ForEach(monthRows.indices, id: \.self) { rowIdx in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { colIdx in
                        let day = monthRows[rowIdx][colIdx]
                        let isToday = calendar.isDateInToday(day.date)
                        ZStack {
                            // Today is always highlighted now — the
                            // toggle for it was removed in favor of
                            // an always-on default.
                            if isToday {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(ForgeTheme.Colors.accent)
                                    .frame(width: 22, height: 22)
                            }
                            Text("\(calendar.component(.day, from: day.date))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(dayColor(day: day, colIdx: colIdx, isToday: isToday))
                        }
                        .frame(maxWidth: .infinity, minHeight: 22)
                    }
                }
            }

            // World clock — single horizontal row, compact (matches popover).
            // Limited to 2 cities in the preview so labels never wrap inside
            // the narrow 280pt preview pane.
            if settings.showWorldClock && !settings.worldClockCities.isEmpty {
                Divider().opacity(0.2).padding(.vertical, 4)
                HStack(spacing: 10) {
                    ForEach(settings.worldClockCities.prefix(2)) { city in
                        HStack(spacing: 3) {
                            Text(city.label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(fgMuted)
                                .lineLimit(1)
                            Text(timeInZone(city.timeZone))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(fg.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
    }

    private func miniProgressRow(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(fgMuted)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(fgMuted.opacity(0.2)).frame(height: 2)
                    Capsule().fill(ForgeTheme.Colors.accent)
                        .frame(width: max(2, geo.size.width * value), height: 2)
                }
            }
            .frame(height: 2)
        }
    }

    /// Weekend = the last two columns of the displayed week,
    /// regardless of week-start. So:
    ///   • Week starts Mon → columns are [Mon..Sun] → weekend = Sat+Sun
    ///   • Week starts Sun → columns are [Sun..Sat] → weekend = Fri+Sat
    /// The second case matches the South-Asia / Middle-East working
    /// week (Sun = first working day, Fri+Sat off).
    private func isWeekendIdx(_ i: Int) -> Bool {
        i == 5 || i == 6
    }

    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = settings.weekStartsOnMonday ? 2 : 1
        return c
    }

    /// One cell in the mini month grid — the underlying date plus a
    /// flag for "is this in the displayed month or a neighbouring
    /// month's overflow day".
    private struct DayCell {
        let date: Date
        let isCurrentMonth: Bool
    }

    /// 6 rows of 7 days each, anchored to today's month. The leading
    /// edge is back-filled with the previous month's tail days so the
    /// grid always starts on the user's chosen weekday.
    private var monthRows: [[DayCell]] {
        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading: Int
        if settings.weekStartsOnMonday {
            leading = (weekday + 5) % 7
        } else {
            leading = (weekday - 1) % 7
        }
        let firstCell = calendar.date(byAdding: .day, value: -leading, to: monthStart) ?? monthStart
        let displayedMonth = calendar.component(.month, from: now)
        var rows: [[DayCell]] = []
        for row in 0..<6 {
            var cells: [DayCell] = []
            for col in 0..<7 {
                let d = calendar.date(byAdding: .day, value: row * 7 + col, to: firstCell) ?? firstCell
                cells.append(DayCell(
                    date: d,
                    isCurrentMonth: calendar.component(.month, from: d) == displayedMonth
                ))
            }
            rows.append(cells)
        }
        return rows
    }

    private func dayColor(day: DayCell, colIdx: Int, isToday: Bool) -> Color {
        if isToday { return .white }
        if !day.isCurrentMonth { return fgFaint }
        if isWeekendIdx(colIdx) { return fgMuted }
        return fg
    }

    private var yearProgress: Double {
        let now = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let next  = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        return now.timeIntervalSince(start) / next.timeIntervalSince(start)
    }
    private var dayProgress: Double {
        let cal = Calendar.current
        let now = Date()
        return now.timeIntervalSince(cal.startOfDay(for: now)) / 86400.0
    }
    private var yearString: String { "\(Calendar.current.component(.year, from: Date()))" }
    private var monthString: String {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"
        return f.string(from: Date())
    }
    private func timeInZone(_ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = settings.use24HourTime ? "HH:mm" : "h:mm a"
        return f.string(from: Date())
    }
}

// MARK: - Segmented Picker (Forge red accent)

/// Drop-in replacement for SwiftUI's `.pickerStyle(.segmented)` that uses
/// the Forge accent (vermillion red) for the selected segment instead of
/// the system gray. Pass a list of `(label, tag)` options and a binding.
private struct ForgeSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(label: String, value: Value)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { idx in
                let item = options[idx]
                let isSelected = selection == item.value
                Button {
                    withAnimation(ForgeTheme.Animation.smooth) {
                        selection = item.value
                    }
                } label: {
                    Text(item.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected
                                         ? .white
                                         : ForgeTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected
                                      ? ForgeTheme.Colors.accent
                                      : Color.clear)
                                .padding(2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ForgeTheme.Colors.surfaceInput.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 0.5)
        )
    }
}

// MARK: - Hero

private struct SectionHero: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.primary)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Card

// Made internal (was private) so module-specific Settings views in
// other files (e.g. `TextExpanderSettingsView`) can reuse the same
// card chrome without re-implementing the styling.
struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var titleIcon: String? = nil
    var description: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || description != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title = title {
                        HStack(spacing: 7) {
                            if let icon = titleIcon {
                                Image(systemName: icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(ForgeTheme.Colors.accent)
                            }
                            Text(title)
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    if let description = description {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ForgeTheme.Colors.surfaceCard)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }
}

// MARK: - Setting Row

private struct SettingRow<Control: View>: View {
    var icon: String? = nil
    var iconTint: Color = ForgeTheme.Colors.accent
    let title: String
    var description: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(iconTint)
                    .frame(width: 28, height: 28)
                    .background(iconTint.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let description = description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

// MARK: - Modules card row

private struct ModuleRowSetting: View {
    let module: any ForgeModule
    @ObservedObject var registry: ModuleRegistry
    @EnvironmentObject var settings: SettingsManager

    /// Hover state for the clickable-icon affordance. Local to this
    /// row so multiple rows don't fight over a single source.
    @State private var iconHovering = false

    var body: some View {
        let enabled = registry.isEnabled(module.id)
        let shortcut = shortcutForModule(id: module.id)
        let triggerable = Self.appDelegate?.hasPrimaryAction(forModuleId: module.id) ?? false

        return HStack(alignment: .center, spacing: 10) {
            // Icon: clickable button on modules with a primary action,
            // a plain image otherwise. The Toggle on the right is a
            // separate control so the user can enable/disable the
            // module without ever firing it (your "separately
            // clickable" requirement).
            if triggerable {
                // Plain `.onTapGesture` + `.onHover` instead of a
                // SwiftUI `Button` — the Tools panel embeds inside an
                // NSScrollView-backed scroll container, and Button's
                // hit-test tracking swallows scroll-wheel events on
                // macOS. The bare gestures give us the same click
                // behavior without breaking scroll.
                iconView(enabled: enabled, hovering: iconHovering)
                    .contentShape(Rectangle())
                    .onHover { iconHovering = $0 }
                    .onTapGesture {
                        _ = Self.appDelegate?.triggerPrimaryAction(forModuleId: module.id)
                    }
                    .help("Run \(module.name)")
            } else {
                iconView(enabled: enabled, hovering: false)
            }

            Text(module.name)
                .font(.system(size: 12, weight: .medium))

            if let shortcut = shortcut {
                Text(shortcut)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(ForgeTheme.Colors.borderSubtle))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 0.5)
                    )
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { registry.isEnabled(module.id) },
                set: { _ in registry.toggleModule(module.id) }
            ))
            .toggleStyle(.forge)
            .labelsHidden()
            .tint(ForgeTheme.Colors.accent)
            .controlSize(.small)
        }
        .padding(.vertical, 5)
    }

    /// The square icon chip. Pulled out so the triggerable / static
    /// branches above share the exact same visual.
    @ViewBuilder
    private func iconView(enabled: Bool, hovering: Bool) -> some View {
        Image(systemName: module.iconName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(enabled ? ForgeTheme.Colors.accent : .secondary)
            .frame(width: 24, height: 24)
            // Background brightens slightly on hover so the user gets
            // a hint that the chip is clickable. Static rows keep the
            // base tint forever.
            .background(
                (enabled ? ForgeTheme.Colors.accent : Color.gray)
                    .opacity(hovering ? 0.22 : 0.12)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Thin accent ring on hover — the "this is clickable"
            // signal. Drawn on top of the background so it's visible
            // against either fill color.
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        hovering ? ForgeTheme.Colors.accent.opacity(0.65) : Color.clear,
                        lineWidth: 1
                    )
            )
            // A barely-there scale bump reinforces the affordance.
            .scaleEffect(hovering ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.14), value: hovering)
    }

    /// Reach for the live AppDelegate via its static `shared`
    /// reference so the icon button can route into the same
    /// primary-action map the hotkey system uses. Direct cast of
    /// `NSApp.delegate` won't work here — SwiftUI's
    /// `@NSApplicationDelegateAdaptor` wraps our delegate in a
    /// `SwiftUI.AppDelegate` proxy, and the cast to our type silently
    /// fails (see the doc comment on `AppDelegate.shared`).
    private static var appDelegate: AppDelegate? { AppDelegate.shared }

    private func shortcutForModule(id: String) -> String? {
        let bindingId: String?
        switch id {
        case "colorPicker":        bindingId = "colorPicker"
        case "screenRuler":        bindingId = "screenRuler"
        case "textExtractor":      bindingId = "textExtractor"
        case "zoomIt":             bindingId = "zoomIt"
        case "fancyZones":         bindingId = "fancyZones"
        case "windowManager":      bindingId = "pinWindow"
        case "meetingReminder":    bindingId = "joinMeeting"
        case "screenshotAnnotate": bindingId = "screenshot"
        // Mouse Highlight is gesture-only (double-tap right ⌘) — no
        // editable shortcut binding.
        default:                   bindingId = nil
        }
        guard let id = bindingId else { return nil }
        let s = settings.binding(for: id).displayString
        return s.isEmpty ? nil : s
    }
}

// MARK: - Building blocks

private struct ShortcutPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct StatPill: View {
    let value: String
    let label: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(tint)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
        }
    }
}

private struct TokenRow: View {
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: active ? "line.3.horizontal" : "circle.dashed")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 13, weight: active ? .medium : .regular))
                .foregroundColor(active ? .primary : .secondary)
            Spacer()
            Button(action: action) {
                Image(systemName: active ? "minus.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(active ? .secondary : ForgeTheme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(active ? 0.03 : 0.0))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Menu Bar Token Grid (Dot-style click-to-toggle chips)

private struct MenuBarTokenGrid: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Live preview row
            HStack(spacing: 6) {
                if settings.menuBarTokens.contains(.icon) {
                    if settings.menuBarEmoji.isEmpty {
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.primary)
                    } else {
                        Text(settings.menuBarEmoji).font(.system(size: 13))
                    }
                }
                Text(previewText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )

            // Chip grid — width measured by GeometryReader and explicitly
            // passed to FlowLayout so chips reliably wrap to a new row.
            WrappingChipGrid(settings: settings, toggle: toggle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Click tokens to add or remove them")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private func toggle(_ token: SettingsManager.MenuBarToken) {
        if let idx = settings.menuBarTokens.firstIndex(of: token) {
            settings.menuBarTokens.remove(at: idx)
        } else {
            settings.menuBarTokens.append(token)
        }
    }

    /// Approximation of what the menu bar will render (for the preview row).
    private var previewText: String {
        let now = Date()
        let fmt = DateFormatter()
        var parts: [String] = []
        for token in settings.menuBarTokens where token != .icon {
            switch token {
            case .date:
                fmt.dateFormat = "EEE, MMM d"
                parts.append(fmt.string(from: now))
            case .clock:
                fmt.dateFormat = settings.menuBarTimeFormat
                parts.append(fmt.string(from: now))
            case .ongoingMeeting: parts.append("● Design Review · 23m left")
            case .nextEvent:    parts.append("Standup · 12m")
            case .countdown:    parts.append("12m")
            case .weekNumber:
                var c = Calendar(identifier: .iso8601)
                c.firstWeekday = settings.weekStartsOnMonday ? 2 : 1
                parts.append("W\(c.component(.weekOfYear, from: now))")
            case .dayProgress:  parts.append("57%")
            case .yearProgress: parts.append("32% of \(Calendar.current.component(.year, from: now))")
            case .worldClock:
                if let city = settings.worldClockCities.first(where: { !$0.isLocal }) {
                    fmt.timeZone = city.timeZone
                    fmt.dateFormat = settings.menuBarTimeFormat
                    parts.append("\(String(city.label.prefix(3)).uppercased()) \(fmt.string(from: now))")
                }
            case .timeLeft:     parts.append("23m left")
            case .eventsLeft:   parts.append("3 left")
            case .focusTime:    parts.append("2h focus")
            case .icon: break
            }
        }
        return parts.joined(separator: settings.menuBarSeparator)
    }
}

private struct TokenChip: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(active ? .white : (hovering ? .primary : .secondary))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        active
                            ? Color(white: 0.15)
                            : (hovering ? Color.black.opacity(0.05) : Color.clear)
                    )
                )
                .overlay(
                    Capsule().stroke(
                        active ? Color.clear : Color.black.opacity(0.10),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Chip grid wrapper that measures its width via `GeometryReader` and feeds
/// it to `FlowLayout` as an explicit `maxWidth`, plus tracks the natural
/// wrapped height via a `PreferenceKey` so the parent stack reserves the
/// right vertical space.
private struct WrappingChipGrid: View {
    @ObservedObject var settings: SettingsManager
    let toggle: (SettingsManager.MenuBarToken) -> Void

    @State private var availableWidth: CGFloat = 0
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            FlowLayout(spacing: 6, maxWidth: geo.size.width) {
                ForEach(SettingsManager.MenuBarToken.allCases) { token in
                    TokenChip(
                        title: token.displayName,
                        active: settings.menuBarTokens.contains(token),
                        action: { toggle(token) }
                    )
                }
            }
            .background(
                GeometryReader { inner in
                    Color.clear.preference(
                        key: ChipGridHeightKey.self,
                        value: inner.size.height
                    )
                }
            )
            .onAppear { availableWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, newValue in
                availableWidth = newValue
            }
        }
        .frame(height: max(contentHeight, 36))
        .onPreferenceChange(ChipGridHeightKey.self) { contentHeight = $0 }
    }
}

private struct ChipGridHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Lightweight flow layout for chips. Takes an explicit `maxWidth` (driven
// from a GeometryReader at the call-site) so wrapping always works even when
// the parent passes a `nil` / unspecified width proposal — that's what was
// causing the "Time Left" chip to overflow past the card's right edge.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cap = max(maxWidth, 1)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > cap, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: cap, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Menu Bar format & separator editors

// MARK: - Menu Bar Emoji Editor

/// Lets the user pick a single emoji that replaces the hammer SF Symbol in
/// the menu bar (and every place the hammer appears in the UI / previews).
private struct MenuBarEmojiEditor: View {
    @ObservedObject var settings: SettingsManager
    @FocusState private var emojiFieldFocused: Bool

    /// Quick-pick row — common productivity icons. Click to set.
    private let quickPicks: [String] = ["🔨", "⚒️", "🛠️", "⚡", "🚀", "🔥",
                                        "🎯", "💼", "📅", "⏰", "🗓️", "✨",
                                        "🌟", "🧠", "💡", "🍅"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top row: preview tile + text field + reset
            HStack(spacing: 14) {
                // Big preview tile showing what'll appear in the menu bar
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(ForgeTheme.Colors.surfaceInput)
                        .frame(width: 56, height: 56)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
                        )

                    if settings.menuBarEmoji.isEmpty {
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(ForgeTheme.Colors.accent)
                    } else {
                        Text(settings.menuBarEmoji)
                            .font(.system(size: 30))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Type or paste an emoji", text: Binding(
                            get: { settings.menuBarEmoji },
                            set: { newValue in
                                // Keep just the first grapheme cluster — so
                                // "🔨🚀" or "🔨 hello" collapses to "🔨".
                                settings.menuBarEmoji = String(newValue.prefix(1))
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 18))
                        .frame(width: 140)
                        .focused($emojiFieldFocused)

                        Button {
                            emojiFieldFocused = true
                            // Open the system emoji & symbols palette. The
                            // user picks a glyph; it lands in the focused
                            // field via the system IME.
                            NSApp.orderFrontCharacterPalette(nil)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "face.smiling")
                                Text("Open emoji picker")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(ForgeTheme.Colors.accent)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(ForgeTheme.Colors.accent.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        if !settings.menuBarEmoji.isEmpty {
                            Button {
                                settings.menuBarEmoji = ""
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text("Reset")
                                }
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Use the default hammer icon")
                        }
                    }

                    Text(settings.menuBarEmoji.isEmpty
                         ? "Currently using the default hammer."
                         : "Live in your menu bar.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            Divider().opacity(0.3)

            // Quick picks
            VStack(alignment: .leading, spacing: 6) {
                Text("QUICK PICKS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    ForEach(quickPicks, id: \.self) { emoji in
                        Button {
                            settings.menuBarEmoji = emoji
                        } label: {
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(settings.menuBarEmoji == emoji
                                              ? ForgeTheme.Colors.accent.opacity(0.15)
                                              : Color.black.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(settings.menuBarEmoji == emoji
                                                ? ForgeTheme.Colors.accent.opacity(0.6)
                                                : Color.clear,
                                                lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Use \(emoji)")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct MenuBarFormatEditor: View {
    @ObservedObject var settings: SettingsManager
    private let presets = ["HH:mm", "h:mm a", "HH:mm:ss", "yyyy-MM-dd"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("HH:mm", text: $settings.menuBarTimeFormat)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .font(.system(size: 12, design: .monospaced))

                Text(formattedNow)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(ForgeTheme.Colors.accent)
                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        settings.menuBarTimeFormat = preset
                    } label: {
                        Text(preset)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(settings.menuBarTimeFormat == preset ? .white : .secondary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    settings.menuBarTimeFormat == preset
                                        ? Color(white: 0.15)
                                        : Color.black.opacity(0.04)
                                )
                            )
                            .overlay(
                                Capsule().stroke(
                                    settings.menuBarTimeFormat == preset
                                        ? Color.clear
                                        : Color.black.opacity(0.08),
                                    lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var formattedNow: String {
        let f = DateFormatter()
        f.dateFormat = settings.menuBarTimeFormat
        return f.string(from: Date())
    }
}

private struct MenuBarSeparatorEditor: View {
    @ObservedObject var settings: SettingsManager
    private let presets: [(label: String, value: String)] = [
        ("|",     " | "),
        ("·",     " · "),
        ("—",     " — "),
        ("space", "  "),
    ]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(presets, id: \.value) { p in
                Button {
                    settings.menuBarSeparator = p.value
                } label: {
                    Text(p.label)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(settings.menuBarSeparator == p.value ? .white : .secondary)
                        .frame(minWidth: 44, minHeight: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7).fill(
                                settings.menuBarSeparator == p.value
                                    ? Color(white: 0.15)
                                    : Color.black.opacity(0.04)
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7).stroke(
                                settings.menuBarSeparator == p.value
                                    ? Color.clear
                                    : Color.black.opacity(0.08),
                                lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - Google Calendar Accounts Editor (native OAuth)

private struct GoogleAccountsEditor: View {
    @ObservedObject private var service = GoogleCalendarService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Connected accounts
            if service.accounts.isEmpty {
                HStack {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundColor(.secondary)
                    Text("No Google accounts connected yet.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(service.accounts) { account in
                        GoogleAccountRow(account: account)
                    }
                }
            }

            // Connect button (uses bundled client ID — user never sees one)
            HStack(spacing: 10) {
                Button { service.connect() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.fill.badge.plus")
                        Text(service.accounts.isEmpty
                             ? "Connect Google account"
                             : "Connect another account")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(ForgeTheme.Colors.accent))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            if let err = service.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.orange)
            }

            Text("Native Google events flow into the calendar live. A color is auto-assigned when you connect — tap the dot next to an account to change it.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
    }

}

// MARK: Google account row + color picker

private struct GoogleAccountRow: View {
    let account: GoogleAccount
    @ObservedObject private var service = GoogleCalendarService.shared
    @State private var showPalette = false

    var body: some View {
        HStack(spacing: 10) {
            // Colored badge — click to change color
            Button { showPalette.toggle() } label: {
                ZStack {
                    Circle()
                        .fill(Color(hex: account.colorHex))
                        .frame(width: 24, height: 24)
                    Image(systemName: "g.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
                .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPalette, arrowEdge: .bottom) {
                GoogleColorPalettePopover(account: account)
            }
            .help("Change color")

            VStack(alignment: .leading, spacing: 1) {
                Text(account.name ?? account.email)
                    .font(.system(size: 12, weight: .semibold))
                Text(account.email)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                service.disconnect(email: account.email)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Disconnect this Google account")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(ForgeTheme.Colors.borderSubtle))
    }
}

private struct GoogleColorPalettePopover: View {
    let account: GoogleAccount
    @ObservedObject private var service = GoogleCalendarService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color for \(account.email)")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 6) {
                ForEach(CalendarColorPreset.allCases) { preset in
                    Button {
                        service.setColor(for: account.email, colorHex: preset.hex)
                    } label: {
                        ZStack {
                            Circle().fill(Color(hex: preset.hex))
                                .frame(width: 22, height: 22)
                            if account.colorHex.uppercased() == preset.hex.uppercased() {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Linked Calendars Editor

private struct LinkedCalendarsEditor: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject var moduleRegistry: ModuleRegistry

    /// All calendars EventKit currently knows about (from any macOS account).
    private var availableCalendars: [CalendarSource] {
        guard let cal = moduleRegistry.module(ofType: CalendarModule.self) else { return [] }
        let linkedIds = Set(settings.linkedCalendars.map { $0.calendarIdentifier })
        return cal.calendars
            .filter { !linkedIds.contains($0.calendarIdentifier) }
            .map { ek in
                CalendarSource(
                    id: ek.calendarIdentifier,
                    title: ek.title,
                    source: ek.source.title,
                    nativeColorHex: hexString(from: ek.cgColor)
                )
            }
    }

    private var isAtLimit: Bool {
        settings.linkedCalendars.count >= SettingsManager.maxLinkedCalendars
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stats header
            HStack {
                Text("\(settings.linkedCalendars.count) of \(SettingsManager.maxLinkedCalendars) linked")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundColor(.secondary)
                Spacer()
                if !availableCalendars.isEmpty && !isAtLimit {
                    addCalendarMenu
                }
            }

            // Linked rows
            if settings.linkedCalendars.isEmpty {
                EmptyStateView(
                    icon: "calendar.badge.plus",
                    title: "No calendars linked yet",
                    description: availableCalendars.isEmpty
                        ? "Add an account in System Settings to get started."
                        : "Tap “Add calendar” to link one."
                )
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(settings.linkedCalendars) { linked in
                        LinkedCalendarRow(
                            settings: settings,
                            linked: linked,
                            sourceLabel: sourceLabel(for: linked)
                        )
                    }
                }
            }

            Divider().opacity(0.3).padding(.top, 2)

            // Account management
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-preferences")!)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square.fill")
                        Text("Add account")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.accent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(ForgeTheme.Colors.accent.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help("Open System Settings → Internet Accounts")

                if isAtLimit {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Max 10 calendars — remove one to link another")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var addCalendarMenu: some View {
        Menu {
            // Group by source title
            let groups = Dictionary(grouping: availableCalendars) { $0.source }
            ForEach(groups.keys.sorted(), id: \.self) { sourceName in
                if let items = groups[sourceName] {
                    Section(sourceName) {
                        ForEach(items) { c in
                            Button {
                                link(c)
                            } label: {
                                HStack {
                                    Circle().fill(Color(hex: c.nativeColorHex)).frame(width: 8, height: 8)
                                    Text(c.title)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                Text("Add calendar")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(ForgeTheme.Colors.accent))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func link(_ source: CalendarSource) {
        guard settings.linkedCalendars.count < SettingsManager.maxLinkedCalendars else { return }
        let nextColor = CalendarColorPreset.nextUnused(in: settings.linkedCalendars).hex
        settings.linkedCalendars.append(
            LinkedCalendar(
                calendarIdentifier: source.id,
                displayName: source.title,
                colorHex: nextColor
            )
        )
    }

    private func sourceLabel(for linked: LinkedCalendar) -> String {
        guard let cal = moduleRegistry.module(ofType: CalendarModule.self)?
                .calendars.first(where: { $0.calendarIdentifier == linked.calendarIdentifier })
        else { return "Unavailable" }
        return cal.source.title
    }
}

/// Lightweight value type representing an EKCalendar entry for the picker.
private struct CalendarSource: Identifiable {
    let id: String          // calendarIdentifier
    let title: String
    let source: String      // EKSource.title
    let nativeColorHex: String
}

private struct LinkedCalendarRow: View {
    @ObservedObject var settings: SettingsManager
    let linked: LinkedCalendar
    let sourceLabel: String

    @State private var editingName: String = ""
    @State private var isEditingName: Bool = false
    @State private var showingColorPicker: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Color swatch — click to change
            Button {
                showingColorPicker.toggle()
            } label: {
                Circle()
                    .fill(Color(hex: linked.colorHex))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.black.opacity(0.1), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingColorPicker, arrowEdge: .bottom) {
                ColorPalettePopover(linked: linked, settings: settings)
            }

            // Name (editable on click)
            if isEditingName {
                TextField("Name", text: $editingName, onCommit: {
                    commitNameEdit()
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: 200)
                .onExitCommand { isEditingName = false }
            } else {
                Text(linked.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .onTapGesture {
                        editingName = linked.displayName
                        isEditingName = true
                    }
            }

            Text("· \(sourceLabel)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            // Edit name button
            Button {
                editingName = linked.displayName
                isEditingName.toggle()
                if !isEditingName { commitNameEdit() }
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.black.opacity(0.04)))
            }
            .buttonStyle(.plain)

            // Remove
            Button {
                settings.linkedCalendars.removeAll { $0.id == linked.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.03))
        )
    }

    private func commitNameEdit() {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { isEditingName = false; return }
        if let idx = settings.linkedCalendars.firstIndex(where: { $0.id == linked.id }) {
            settings.linkedCalendars[idx].displayName = trimmed
        }
        isEditingName = false
    }
}

private struct ColorPalettePopover: View {
    let linked: LinkedCalendar
    @ObservedObject var settings: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick a color")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                ForEach(CalendarColorPreset.allCases) { preset in
                    Button {
                        if let idx = settings.linkedCalendars.firstIndex(where: { $0.id == linked.id }) {
                            settings.linkedCalendars[idx].colorHex = preset.hex
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(hex: preset.hex))
                                .frame(width: 22, height: 22)
                            if linked.colorHex.uppercased() == preset.hex.uppercased() {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .overlay(
                            Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

/// Convert CGColor → hex (#RRGGBB).
private func hexString(from cg: CGColor) -> String {
    let comps = cg.components ?? []
    let r = Int((comps.count > 0 ? comps[0] : 0) * 255)
    let g = Int((comps.count > 1 ? comps[1] : 0) * 255)
    let b = Int((comps.count > 2 ? comps[2] : 0) * 255)
    return String(format: "#%02X%02X%02X", r, g, b)
}

// (Color(hex:) lives in ForgeTheme.swift)

// MARK: - World Clock Editor

private struct WorldClockEditor: View {
    @ObservedObject var settings: SettingsManager

    private var unusedPresets: [WorldClockCity] {
        WorldClockCity.presets.filter { preset in
            !settings.worldClockCities.contains { $0.timeZoneId == preset.timeZoneId }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Active cities
            if settings.worldClockCities.isEmpty {
                Text("No cities yet — add one below.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(settings.worldClockCities) { city in
                    HStack(spacing: 10) {
                        Image(systemName: city.isLocal ? "location.circle.fill" : "globe")
                            .font(.system(size: 12))
                            .foregroundColor(city.isLocal ? ForgeTheme.Colors.accent : .secondary)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(city.label)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            if !city.isLocal {
                                Text(city.timeZoneId)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)

                        // Time pill — fixed: never truncates ("19:52" needs ~38pt).
                        Text(currentTime(in: city.timeZone))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.04))
                            .clipShape(Capsule())

                        Button {
                            settings.worldClockCities.removeAll { $0.id == city.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(city.label)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }

            // Add row
            HStack(spacing: 8) {
                if !settings.worldClockCities.contains(where: { $0.isLocal }) {
                    Button {
                        settings.worldClockCities.append(
                            WorldClockCity(label: "Local", timeZoneId: "")
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "location.circle.fill")
                            Text("Add Local")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ForgeTheme.Colors.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(ForgeTheme.Colors.accent.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    if unusedPresets.isEmpty {
                        Text("All preset cities added")
                    } else {
                        ForEach(unusedPresets) { preset in
                            Button {
                                settings.worldClockCities.append(preset)
                            } label: {
                                HStack {
                                    Text(preset.label)
                                    Spacer()
                                    Text(currentTime(in: preset.timeZone))
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add city")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ForgeTheme.Colors.accent.opacity(0.12))
                    .clipShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                if settings.worldClockCities != WorldClockCity.defaults {
                    Button {
                        settings.worldClockCities = WorldClockCity.defaults
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset")
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Restore Local + Dhaka")
                }
            }
            .padding(.top, 4)
        }
    }

    private func currentTime(in tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}

private struct EmptyStateView: View {
    let icon: String
    let title: String
    let description: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

private struct AboutFact: View {
    let icon: String
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.accent)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Shortcut Row (editable)

/// Unified row used by Settings → Shortcuts. Handles both keystroke
/// shortcuts (with an editable binding + Forge red record button) and
/// gesture shortcuts (with a static monospaced label). Either way the
/// row carries an enable / disable toggle on the left so the user can
/// silence an individual action without messing with the binding.
struct ShortcutRow: View {
    let action: ShortcutBinding.Action
    @ObservedObject var settings: SettingsManager
    @State private var isRecording = false
    @State private var hoveringEdit = false

    private var binding: ShortcutBinding {
        settings.binding(for: action.id)
    }

    private var isDefault: Bool {
        binding == ShortcutBinding.defaults[action.id]
    }

    private var conflict: String? {
        guard !action.isGesture else { return nil }
        return MacOSShortcutConflicts.description(
            keyCode: binding.keyCode,
            modifiers: binding.nsModifiers
        )
    }

    private var isEnabled: Bool {
        settings.isActionEnabled(action.id)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Enable / disable toggle — silences an action without
            // changing its binding. Disabled rows are visually dimmed.
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { settings.setActionEnabled(action.id, $0) }
            ))
            .toggleStyle(.forge)
            .labelsHidden()

            // Name + description + optional conflict warning
            VStack(alignment: .leading, spacing: 3) {
                Text(action.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                Text(action.description)
                    .font(.system(size: 11))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let conflict = conflict {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("Conflicts with \(conflict)")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.orange)
                }
            }

            Spacer(minLength: 12)

            // Trailing column — either the gesture label chip OR the
            // recorder + edit button.
            if action.isGesture {
                Text(action.gestureLabel ?? "")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(ForgeTheme.Colors.surfaceHover))
                    .overlay(
                        Capsule().strokeBorder(ForgeTheme.Colors.borderDefault, lineWidth: 0.5)
                    )
            } else {
                HStack(spacing: 8) {
                    if !isDefault {
                        Button {
                            settings.resetBinding(for: action.id)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.black.opacity(0.04)))
                        }
                        .buttonStyle(.plain)
                        .help("Reset to default")
                    }
                    ShortcutRecorderView(
                        currentBinding: binding,
                        isRecording: $isRecording,
                        onRecord: { keyCode, modifiers in
                            settings.updateBinding(for: action.id,
                                                   keyCode: keyCode,
                                                   modifiers: modifiers)
                            isRecording = false
                        },
                        onCancel: { isRecording = false }
                    )
                    .frame(width: 140, height: 28)
                    Button {
                        isRecording.toggle()
                    } label: {
                        Image(systemName: isRecording ? "xmark" : "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isRecording ? .white : ForgeTheme.Colors.accent)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle().fill(
                                    isRecording
                                        ? ForgeTheme.Colors.accent
                                        : (hoveringEdit
                                            ? ForgeTheme.Colors.accent.opacity(0.18)
                                            : ForgeTheme.Colors.accent.opacity(0.10))
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringEdit = $0 }
                    .help(isRecording ? "Stop recording" : "Edit shortcut")
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .opacity(isEnabled ? 1.0 : 0.55)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
    }
}

// MARK: - macOS shortcut conflict detection

enum MacOSShortcutConflicts {
    /// Returns a human-readable name of the conflicting macOS shortcut,
    /// or nil if there's no known conflict.
    static func description(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        let mods = modifiers.intersection([.command, .shift, .option, .control])

        struct Conflict { let keyCode: UInt16; let mods: NSEvent.ModifierFlags; let name: String }
        let known: [Conflict] = [
            // Key codes: 49=Space, 48=Tab, 36=Return, 53=Esc,
            // 0=A, 1=S, 2=D, 3=F, 5=G, 6=Z, 8=C, 9=V, 12=Q, 13=W, 15=R, 17=T,
            // 31=O, 35=P, 38=J, 45=N, 46=M, 50=`
            Conflict(keyCode: 49, mods: [.command],                 name: "macOS Spotlight"),
            Conflict(keyCode: 49, mods: [.command, .shift],         name: "macOS input source"),
            Conflict(keyCode: 49, mods: [.control],                 name: "macOS Spotlight (alt)"),
            Conflict(keyCode: 48, mods: [.command],                 name: "macOS app switcher"),
            Conflict(keyCode: 48, mods: [.command, .shift],         name: "macOS app switcher (reverse)"),
            Conflict(keyCode: 50, mods: [.command],                 name: "macOS window cycle"),
            Conflict(keyCode: 53, mods: [.command, .option],        name: "Force Quit"),
            Conflict(keyCode: 12, mods: [.command],                 name: "Quit app"),
            Conflict(keyCode: 13, mods: [.command],                 name: "Close window"),
            Conflict(keyCode: 13, mods: [.command, .option],        name: "Close all windows"),
            Conflict(keyCode: 0,  mods: [.command],                 name: "Select all"),
            Conflict(keyCode: 8,  mods: [.command],                 name: "Copy"),
            Conflict(keyCode: 9,  mods: [.command],                 name: "Paste"),
            Conflict(keyCode: 7,  mods: [.command],                 name: "Cut"),
            Conflict(keyCode: 6,  mods: [.command],                 name: "Undo"),
            Conflict(keyCode: 6,  mods: [.command, .shift],         name: "Redo"),
            Conflict(keyCode: 1,  mods: [.command],                 name: "Save"),
            Conflict(keyCode: 35, mods: [.command],                 name: "Print"),
            Conflict(keyCode: 31, mods: [.command],                 name: "Open"),
            Conflict(keyCode: 45, mods: [.command],                 name: "New"),
            Conflict(keyCode: 3,  mods: [.command],                 name: "Find"),
            Conflict(keyCode: 4,  mods: [.command],                 name: "Hide app"),
            Conflict(keyCode: 46, mods: [.command],                 name: "Minimize"),
            Conflict(keyCode: 3,  mods: [.control, .command],       name: "Full screen"),
            Conflict(keyCode: 17, mods: [.command],                 name: "New tab"),
            Conflict(keyCode: 13, mods: [.command, .shift],         name: "Reopen last closed tab"),
        ]

        if let match = known.first(where: { $0.keyCode == keyCode && $0.mods == mods }) {
            return match.name
        }
        return nil
    }
}

// MARK: - Shortcut Recorder (click to capture new key combo)

struct ShortcutRecorderView: NSViewRepresentable {
    let currentBinding: ShortcutBinding
    @Binding var isRecording: Bool
    /// When true, single-key presses (no modifiers) are accepted — used
    /// by the KeyRemap capture sheet where `a → b` is a valid mapping.
    /// Defaults to false so the global Shortcuts tab still enforces a
    /// modifier and bare letters can't capture system-wide hotkeys.
    var allowsBareKey: Bool = false
    let onRecord: (UInt16, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.displayString = currentBinding.displayString
        view.allowsBareKey = allowsBareKey
        view.onRecord = onRecord
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.displayString = currentBinding.displayString
        nsView.allowsBareKey = allowsBareKey
        if isRecording && !nsView.isRecording {
            nsView.startRecording()
        } else if !isRecording && nsView.isRecording {
            nsView.stopRecording()
        }
    }
}

/// AppKit view that captures keyboard events when clicked
final class ShortcutRecorderNSView: NSView {
    var displayString: String = "" { didSet { needsDisplay = true } }
    var isRecording: Bool = false { didSet { needsDisplay = true } }
    /// See `ShortcutRecorderView.allowsBareKey`. Controls whether
    /// modifier-less key presses are accepted in `startRecording`.
    var allowsBareKey: Bool = false
    var onRecord: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?

    private var localMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 120, height: 28)
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
            onCancel?()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)

        // Monitor key events to capture the shortcut
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.isRecording else { return event }

            // Escape cancels recording
            if event.keyCode == 53 {
                self.stopRecording()
                self.onCancel?()
                return nil
            }

            // Bare-letter gating — required for global hotkeys (otherwise
            // pressing "a" while typing would capture a system shortcut)
            // but disabled for KeyRemap, where `a → b` is the whole point.
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if !self.allowsBareKey && mods.isEmpty { return nil }

            self.onRecord?(UInt16(event.keyCode), mods)
            self.stopRecording()
            return nil // Consume the event
        }

        needsDisplay = true
    }

    func stopRecording() {
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

        if isRecording {
            // Recording state: highlighted border, pulsing bg
            NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
            path.fill()
            NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 2
            path.stroke()

            let text = "Press shortcut…"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.systemBlue
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let size = str.size()
            str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        } else {
            // Normal state: show current shortcut
            NSColor(hex: "#F5F3EE").setFill()
            path.fill()
            NSColor(hex: "#E7E5E4").setStroke()
            path.lineWidth = 1
            path.stroke()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(hex: "#78716C")
            ]
            let str = NSAttributedString(string: displayString, attributes: attrs)
            let size = str.size()
            str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }
}

// MARK: - NSColor hex helper (for the recorder view)

private extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8) & 0xFF) / 255
        let b = CGFloat(int & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - Launch at login toggle

/// Settings toggle for launch-at-login, backed by `@State` initialized
/// from the live `SMAppService` status and reconciled after each change.
/// It always reflects reality — including snapping back if macOS defers a
/// request to `.requiresApproval` — which makes the control a dependable
/// two-way toggle instead of a write-only switch.
private struct LaunchAtLoginToggle: View {
    @State private var enabled = LaunchAtLogin.isEnabled

    var body: some View {
        Toggle("", isOn: $enabled)
            .toggleStyle(.forge)
            .labelsHidden()
            .tint(ForgeTheme.Colors.accent)
            .onChange(of: enabled) { _, newValue in
                let actual = LaunchAtLogin.setEnabled(newValue)
                if actual != newValue { enabled = actual }
            }
            .onAppear { enabled = LaunchAtLogin.isEnabled }
    }
}

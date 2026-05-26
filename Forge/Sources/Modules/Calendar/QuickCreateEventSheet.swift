import SwiftUI
import AppKit

// MARK: - Public sheet

/// Minimal one-shot "type what you want" event creator — modelled on
/// the Dot/Cron-style quick-create. The user types a natural-language
/// phrase ("Fundraising chat at 2pm today; repeats weekly") and we
/// parse it live into a structured preview underneath. Hitting ⌘↩
/// (or clicking Create) saves through `GoogleCalendarService`.
///
/// The expanded editor (`NewEventSheet`) is still available for
/// per-field control — quick-create is the everyday path.
struct QuickCreateEventSheet: View {
    let defaultStart: Date
    let onDone: (CalendarEvent?) -> Void

    @State private var input: String = ""
    @State private var parsed: ParsedEvent
    @State private var calendarAccount: String = ""
    @State private var isSaving = false
    @State private var errorText: String?
    /// When true, ask Google to mint a fresh Meet link on save (via
    /// `conferenceData.createRequest`). Auto-toggled on when the user
    /// types "with meet" / "google meet" / "add meet" — they can still
    /// flip it manually from the toggle row.
    @State private var addGoogleMeet: Bool = false
    @FocusState private var inputFocused: Bool

    // MARK: - Per-field live state
    //
    // Each editable preview row has its own `@State` value initialised
    // from the parser. We keep a "touched" flag per field so that once
    // the user manually edits a value, subsequent natural-language re-
    // parses don't clobber their input. This mirrors how Apple Calendar
    // and Google Calendar's quick-create handle inline edits.

    @State private var liveLocation: String = ""
    @State private var liveMeetingURL: String = ""
    @State private var liveNotes: String = ""
    @State private var liveReminderMinutes: Int? = 5

    @State private var touchedLocation = false
    @State private var touchedMeetingURL = false
    @State private var touchedNotes = false
    @State private var touchedReminder = false

    /// Currently expanded inline editor — only one field is in edit
    /// mode at a time so the layout stays compact.
    @State private var editingField: EditingField?
    enum EditingField { case location, meetingURL, notes }

    @FocusState private var locationFocused: Bool
    @FocusState private var meetingURLFocused: Bool
    @FocusState private var notesFocused: Bool

    @ObservedObject private var google = GoogleCalendarService.shared

    init(defaultStart: Date, onDone: @escaping (CalendarEvent?) -> Void) {
        self.defaultStart = defaultStart
        self.onDone = onDone
        _parsed = State(initialValue: ParsedEvent.empty(defaultStart: defaultStart))
        _calendarAccount = State(initialValue:
            GoogleCalendarService.shared.accounts.first?.email ?? ""
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                inputField
                previewSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 16)
            footer
        }
        .frame(width: 520)
        .background(ForgeTheme.Colors.surfaceCard)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                inputFocused = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("New Event")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
            Spacer()
            Text("ESC")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ForgeTheme.Colors.surfaceHover)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(ForgeTheme.Colors.borderDefault, lineWidth: 0.5)
                )
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    // MARK: - Input

    private var inputField: some View {
        // Large, headline-style multiline input. We use a TextField that
        // grows with content (.lineLimit(2...4) on macOS 14+).
        TextField("e.g. \"Fundraising chat at 2pm today\"", text: $input, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .regular))
            .foregroundColor(ForgeTheme.Colors.textPrimary)
            .lineLimit(1...3)
            .focused($inputFocused)
            .onChange(of: input) { newValue in
                parsed = NaturalLanguageEventParser.parse(
                    newValue,
                    defaultStart: defaultStart
                )
                // Mirror the parser's Meet intent into the toggle, but
                // only when it transitions to true — don't fight a
                // user who manually toggled the switch off.
                if parsed.wantsMeet, !addGoogleMeet {
                    addGoogleMeet = true
                }
                // Re-sync live fields from the parser, but only when
                // the user hasn't touched them. The "touched" flag is
                // cleared if they go back to an empty value.
                if !touchedLocation { liveLocation = parsed.location }
                if !touchedMeetingURL { liveMeetingURL = parsed.meetingURL }
                if !touchedNotes { liveNotes = parsed.notes }
                if !touchedReminder { liveReminderMinutes = parsed.reminderMinutes }
            }
            .onSubmit { Task { await save() } }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title row (extracted from input)
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(accountColor)
                    .frame(width: 8, height: 8)
                Text(parsed.title.isEmpty ? "Event title" : parsed.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(parsed.title.isEmpty
                                     ? ForgeTheme.Colors.textPrimary.opacity(0.35)
                                     : ForgeTheme.Colors.textPrimary)
                    .lineLimit(1)
            }

            // Date + time line — accent-colored numerals, matching the
            // rest of Forge's CTA palette.
            HStack(spacing: 6) {
                Text(parsed.dayLabel)
                    .font(.system(size: 13))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                Text("·")
                    .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.5))
                Text(parsed.startTimeLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.accent)
                Text("–")
                    .font(.system(size: 12))
                    .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.5))
                Text(parsed.endTimeLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.accent)
            }

            // Recurrence chips
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(parsed.recurrence == nil
                                     ? ForgeTheme.Colors.textSecondary.opacity(0.6)
                                     : ForgeTheme.Colors.accent)
                if let rec = parsed.recurrence {
                    HStack(spacing: 4) {
                        Text(rec.label)
                            .font(.system(size: 12, weight: .semibold))
                        Button {
                            parsed.recurrence = nil
                            input = stripRecurrencePhrases(from: input)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundColor(ForgeTheme.Colors.accent)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(ForgeTheme.Colors.accent.opacity(0.12)))
                } else {
                    ForEach(RecurrenceOption.allCases) { option in
                        Button {
                            parsed.recurrence = option
                        } label: {
                            Text(option.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.7))
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(Capsule().fill(ForgeTheme.Colors.surfaceHover))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Editable rows — tap to expand into an inline editor.
            // Location & Meeting Link are single-line TextFields; the
            // Reminder row uses a Menu; Notes is a multi-line editor.
            locationRow
            meetingURLRow

            // Google Meet toggle — only shown when we have an account
            // that can mint a link. Mirrors the toggle in the full
            // editor (`NewEventSheet`) so behavior is identical.
            if !google.accounts.isEmpty {
                meetToggleRow
            }

            reminderRow
            notesRow

            if let err = errorText {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - Editable rows

    private var locationRow: some View {
        editableTextRow(
            icon: "paperplane",
            placeholder: "Location",
            text: $liveLocation,
            isEditing: editingField == .location,
            focusBinding: $locationFocused,
            startEdit: {
                editingField = .location
                DispatchQueue.main.async { locationFocused = true }
            },
            commit: {
                touchedLocation = !liveLocation.isEmpty
                editingField = nil
            }
        )
    }

    private var meetingURLRow: some View {
        editableTextRow(
            icon: "link",
            placeholder: "Meeting link",
            text: $liveMeetingURL,
            isEditing: editingField == .meetingURL,
            focusBinding: $meetingURLFocused,
            startEdit: {
                // Manually-typed link doesn't make sense alongside
                // "Add Google Meet" — turning the meet toggle off when
                // the user starts typing a URL is the least surprising
                // behavior.
                if addGoogleMeet { addGoogleMeet = false }
                editingField = .meetingURL
                DispatchQueue.main.async { meetingURLFocused = true }
            },
            commit: {
                touchedMeetingURL = !liveMeetingURL.isEmpty
                editingField = nil
            }
        )
    }

    private var reminderRow: some View {
        // Reminder is a Menu — pick "At start", 5 / 10 / 15 / 30 min,
        // 1 hr, 1 day, or "Default" (calendar default, no override).
        Menu {
            reminderOption(label: "Default reminder", minutes: nil)
            Divider()
            reminderOption(label: "At start of event", minutes: 0)
            reminderOption(label: "5 minutes before", minutes: 5)
            reminderOption(label: "10 minutes before", minutes: 10)
            reminderOption(label: "15 minutes before", minutes: 15)
            reminderOption(label: "30 minutes before", minutes: 30)
            reminderOption(label: "1 hour before", minutes: 60)
            reminderOption(label: "1 day before", minutes: 1440)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bell")
                    .font(.system(size: 12))
                    .foregroundColor(ForgeTheme.Colors.accent)
                    .frame(width: 16)
                Text(reminderDisplayLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private func reminderOption(label: String, minutes: Int?) -> some View {
        Button {
            liveReminderMinutes = minutes
            touchedReminder = true
        } label: {
            HStack {
                Text(label)
                if liveReminderMinutes == minutes {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private var notesRow: some View {
        // Notes — collapsed-row → tap to expand into a multi-line
        // TextEditor with a Done button. Keeps the sheet compact when
        // the field is empty.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 12))
                    .foregroundColor(liveNotes.isEmpty
                                     ? ForgeTheme.Colors.textSecondary.opacity(0.5)
                                     : ForgeTheme.Colors.accent)
                    .frame(width: 16)
                if editingField == .notes {
                    Text("Notes")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                    Spacer()
                    Button {
                        touchedNotes = !liveNotes.isEmpty
                        editingField = nil
                    } label: {
                        Text("Done")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(ForgeTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(liveNotes.isEmpty
                         ? "Notes"
                         : liveNotes.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 13,
                                      weight: liveNotes.isEmpty ? .regular : .semibold))
                        .foregroundColor(liveNotes.isEmpty
                                         ? ForgeTheme.Colors.textSecondary.opacity(0.6)
                                         : ForgeTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                editingField = .notes
                DispatchQueue.main.async { notesFocused = true }
            }

            if editingField == .notes {
                TextEditor(text: $liveNotes)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .focused($notesFocused)
                    .frame(minHeight: 60, maxHeight: 110)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ForgeTheme.Colors.surfaceHover)
                    )
                    .padding(.leading, 26)
            }
        }
    }

    /// Shared row factory for single-line editable fields (Location +
    /// Meeting link). Display mode shows the icon + value/placeholder;
    /// edit mode swaps in a TextField that auto-commits on Enter or
    /// when the user starts editing a different field.
    @ViewBuilder
    private func editableTextRow(
        icon: String,
        placeholder: String,
        text: Binding<String>,
        isEditing: Bool,
        focusBinding: FocusState<Bool>.Binding,
        startEdit: @escaping () -> Void,
        commit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(text.wrappedValue.isEmpty
                                 ? ForgeTheme.Colors.textSecondary.opacity(0.5)
                                 : ForgeTheme.Colors.accent)
                .frame(width: 16)
            if isEditing {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                    .focused(focusBinding)
                    .onSubmit(commit)
            } else {
                Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue)
                    .font(.system(size: 13,
                                  weight: text.wrappedValue.isEmpty ? .regular : .semibold))
                    .foregroundColor(text.wrappedValue.isEmpty
                                     ? ForgeTheme.Colors.textSecondary.opacity(0.6)
                                     : ForgeTheme.Colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            if isEditing && !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing {
                commit()
            } else {
                startEdit()
            }
        }
    }

    /// Display string for the bell-icon reminder row. Mirrors
    /// ParsedEvent.reminderLabel but uses the live state so the row
    /// updates the moment the user picks a different option.
    private var reminderDisplayLabel: String {
        guard let m = liveReminderMinutes else { return "Default reminder" }
        if m == 0 { return "At start" }
        if m >= 60 && m % 60 == 0 {
            let h = m / 60
            return h == 1 ? "1 hour before" : "\(h) hours before"
        }
        if m == 1440 { return "1 day before" }
        return "\(m) min before"
    }

    /// Google Meet toggle row — same icon + helper-text layout as the
    /// rest of the preview rows, plus a Forge-styled switch on the
    /// right. Stays disabled-looking until the user has at least one
    /// connected Google account (handled by the call-site guard).
    private var meetToggleRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "video")
                .font(.system(size: 12))
                .foregroundColor(addGoogleMeet
                                 ? ForgeTheme.Colors.accent
                                 : ForgeTheme.Colors.textSecondary.opacity(0.6))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Add Google Meet")
                    .font(.system(size: 13, weight: addGoogleMeet ? .semibold : .regular))
                    .foregroundColor(addGoogleMeet
                                     ? ForgeTheme.Colors.textPrimary
                                     : ForgeTheme.Colors.textSecondary.opacity(0.7))
                Text(addGoogleMeet
                     ? "Forge will mint a fresh meet.google.com link on Create."
                     : "Off — no video link will be attached.")
                    .font(.system(size: 10))
                    .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.6))
            }
            Spacer()
            Toggle("", isOn: $addGoogleMeet)
                .toggleStyle(.forge)
                .labelsHidden()
        }
    }

    private func previewRow(icon: String, text: String, isPlaceholder: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(isPlaceholder
                                 ? ForgeTheme.Colors.textSecondary.opacity(0.5)
                                 : ForgeTheme.Colors.accent)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 13, weight: isPlaceholder ? .regular : .semibold))
                .foregroundColor(isPlaceholder
                                 ? ForgeTheme.Colors.textSecondary.opacity(0.6)
                                 : ForgeTheme.Colors.textPrimary)
                .lineLimit(1)
            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let acc = google.accounts.first(where: { $0.email == calendarAccount }) {
                Menu {
                    ForEach(google.accounts) { other in
                        Button {
                            calendarAccount = other.email
                        } label: {
                            HStack {
                                Circle().fill(Color(hex: other.colorHex)).frame(width: 8, height: 8)
                                Text(other.email)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: acc.colorHex)).frame(width: 8, height: 8)
                        Text(displayName(for: acc))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                HStack(spacing: 6) {
                    Circle().fill(Color.gray).frame(width: 8, height: 8)
                    Text("Local")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().controlSize(.small) }
                    Text("Create")
                        .font(.system(size: 13, weight: .semibold))
                    Text("⌘↩")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(ForgeTheme.Colors.accent))
            }
            .buttonStyle(.plain)
            .disabled(parsed.title.isEmpty || isSaving)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            Rectangle()
                .fill(ForgeTheme.Colors.surfaceSubtle)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(ForgeTheme.Colors.borderDefault),
                    alignment: .top
                )
        )
    }

    // MARK: - Helpers

    private var accountColor: Color {
        if let acc = google.accounts.first(where: { $0.email == calendarAccount }) {
            return Color(hex: acc.colorHex)
        }
        return .blue
    }

    /// Friendly account name: prefer the user's first name, fallback to
    /// the email's local-part with dots → spaces.
    private func displayName(for acc: GoogleAccount) -> String {
        if let name = acc.name?.split(separator: " ").first {
            return String(name)
        }
        let local = acc.email.split(separator: "@").first.map(String.init) ?? acc.email
        return local.capitalized
    }

    /// Remove recurrence keywords from the input when the user clicks
    /// the × on the recurrence chip — so the parsed state stays in
    /// sync with the visible text.
    private func stripRecurrencePhrases(from text: String) -> String {
        var t = text
        let patterns = [
            "; repeats daily", "; repeats weekly", "; repeats monthly",
            "; daily", "; weekly", "; monthly",
            " repeats daily", " repeats weekly", " repeats monthly",
            " every day", " every week", " every month",
        ]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: .caseInsensitive)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Save

    private func save() async {
        guard !parsed.title.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        // Live values win over the parser's initial guess — once the
        // user has clicked any of the editable rows, that's the
        // authoritative input.
        let locationOut = liveLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetingURLOut = liveMeetingURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesOut = liveNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let remindersOut = liveReminderMinutes.map { [$0] } ?? []

        // No connected account → local-only preview
        guard let account = google.accounts.first(where: { $0.email == calendarAccount }) else {
            onDone(CalendarEvent(
                id: "local:\(UUID().uuidString)",
                title: parsed.title,
                startDate: parsed.start,
                endDate: parsed.end,
                isAllDay: false,
                calendarColor: .blue,
                calendarTitle: "Local",
                location: locationOut.isEmpty ? nil : locationOut,
                notes: notesOut.isEmpty ? nil : notesOut,
                meetingURL: meetingURLOut.isEmpty ? nil : URL(string: meetingURLOut),
                attendeeCount: 0,
                remindersMinutes: remindersOut
            ))
            return
        }

        do {
            let result = try await GoogleCalendarService.shared.createEvent(
                on: account.email,
                title: parsed.title,
                start: parsed.start,
                end: parsed.end,
                isAllDay: false,
                location: locationOut.isEmpty ? nil : locationOut,
                notes: notesOut.isEmpty ? nil : notesOut,
                meetingURL: addGoogleMeet
                    ? nil
                    : (meetingURLOut.isEmpty ? nil : meetingURLOut),
                generateMeet: addGoogleMeet,
                attendees: [],
                attachments: [],
                remindersMinutes: remindersOut
            )
            // If we asked Google to mint a Meet link, prefer that one
            // over whatever the user typed (they probably typed nothing).
            let finalMeetingURL = result.meetingURL
                ?? (meetingURLOut.isEmpty ? nil : meetingURLOut)
            let preview = CalendarEvent(
                id: "google:\(result.eventId)",
                title: parsed.title,
                startDate: parsed.start,
                endDate: parsed.end,
                isAllDay: false,
                calendarColor: Color(hex: account.colorHex),
                calendarTitle: account.email,
                location: locationOut.isEmpty ? nil : locationOut,
                notes: notesOut.isEmpty ? nil : notesOut,
                meetingURL: finalMeetingURL.flatMap { URL(string: $0) },
                attendeeCount: 0,
                googleRouting: .init(
                    accountEmail: result.accountEmail,
                    calendarId: result.calendarId,
                    eventId: result.eventId
                ),
                remindersMinutes: remindersOut
            )
            onDone(preview)
        } catch {
            errorText = "Couldn't create: \(error.localizedDescription)"
        }
    }
}

// MARK: - Parsed model

/// What `NaturalLanguageEventParser` extracts. Always populated to
/// some default so the preview can render before the user types
/// anything meaningful.
struct ParsedEvent {
    var title: String
    var start: Date
    var end: Date
    var location: String
    var meetingURL: String
    var notes: String
    /// nil ⇒ event uses calendar default reminder (most users like
    /// 10 min before, but we don't override that here).
    var reminderMinutes: Int?
    var recurrence: RecurrenceOption?
    /// True when the input contained a Meet-intent keyword
    /// ("with meet", "google meet", "add meet"). The sheet flips its
    /// Meet toggle on when this turns true.
    var wantsMeet: Bool

    static func empty(defaultStart: Date) -> ParsedEvent {
        let cal = Calendar.current
        let rounded = nextRoundHour(after: defaultStart)
        return ParsedEvent(
            title: "",
            start: rounded,
            end: cal.date(byAdding: .hour, value: 1, to: rounded) ?? rounded,
            location: "",
            meetingURL: "",
            notes: "",
            reminderMinutes: 5,
            recurrence: nil,
            wantsMeet: false
        )
    }

    var dayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(start)    { return "Today" }
        if cal.isDateInTomorrow(start) { return "Tomorrow" }
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: start)
    }

    var startTimeLabel: String { Self.hhmm(start) }
    var endTimeLabel: String   { Self.hhmm(end) }
    var reminderLabel: String {
        guard let m = reminderMinutes else { return "Default reminder" }
        if m == 0 { return "At start" }
        if m >= 60 && m % 60 == 0 {
            let h = m / 60
            return "\(h)h before"
        }
        return "\(m)m before"
    }

    private static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private static func nextRoundHour(after date: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        comps.hour = (comps.hour ?? 9) + 1
        comps.minute = 0
        return cal.date(from: comps) ?? date
    }
}

// MARK: - Recurrence

enum RecurrenceOption: String, CaseIterable, Identifiable, Equatable {
    case daily, weekly, monthly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

// MARK: - Parser

/// Lightweight natural-language → ParsedEvent converter. Handles the
/// patterns the user reference shows ("at 2pm today", "repeats
/// weekly", "tomorrow 3pm") plus a few extras. Apple's `NSDataDetector`
/// could do most of this, but it's locale-dependent and pulls the
/// whole text-recognition framework — keeping it hand-rolled here
/// avoids the overhead and keeps behavior predictable.
enum NaturalLanguageEventParser {
    static func parse(_ text: String, defaultStart: Date) -> ParsedEvent {
        var working = text
        var parsed = ParsedEvent.empty(defaultStart: defaultStart)

        // 1) Recurrence keywords — strip them out before we look for
        //    title, so "Fundraising chat repeats weekly" → title is
        //    "Fundraising chat".
        if let rec = detectRecurrence(in: working) {
            parsed.recurrence = rec.option
            working = rec.stripped
        }

        // 1b) Google Meet intent — phrases like "with google meet",
        //     "add meet", "with meet". Lets the sheet auto-toggle the
        //     Meet switch as the user types. Keywords are stripped so
        //     they don't pollute the title.
        if let meetHit = detectMeetIntent(in: working) {
            parsed.wantsMeet = true
            working = meetHit
        }

        // 2) Day reference (today / tomorrow / Monday-Sunday / next Tuesday)
        if let dayHit = detectDay(in: working) {
            working = dayHit.stripped
            parsed.start = dayHit.date
        }

        // 3) Time of day ("at 2pm", "at 14:00", "9am-10am")
        if let timeHit = detectTime(in: working, anchor: parsed.start) {
            working = timeHit.stripped
            parsed.start = timeHit.start
            parsed.end = timeHit.end
        } else {
            // No time given → 1-hr block starting at the rounded hour
            parsed.end = Calendar.current.date(byAdding: .hour, value: 1, to: parsed.start) ?? parsed.start
        }

        // 4) Meeting URL — pull any http(s) URL into its own field.
        if let urlHit = detectURL(in: working) {
            working = urlHit.stripped
            parsed.meetingURL = urlHit.url
        }

        // 5) Location — "at <Place>" only if it's not a time
        //    ("at 2pm" was already consumed in step 3).
        if let locHit = detectLocation(in: working) {
            working = locHit.stripped
            parsed.location = locHit.place
        }

        // 6) Whatever remains is the title — trim filler punctuation.
        let title = working
            .replacingOccurrences(of: ";", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.; "))
        parsed.title = title

        return parsed
    }

    // MARK: Helpers

    /// "with google meet", "add meet", "with meet", "+ meet" — any of
    /// these in the input is treated as "yes, please mint a Meet link".
    /// Returns the stripped text (so the keywords don't end up in the
    /// title), or nil if no Meet intent is present.
    private static func detectMeetIntent(in text: String) -> String? {
        let phrases = [
            " with google meet",
            " add google meet",
            " google meet",
            " with meet",
            " add meet",
            " +meet",
            " +google meet",
        ]
        let lower = text.lowercased()
        for phrase in phrases {
            if let r = lower.range(of: phrase) {
                let stripped = removeRange(r, from: text, lower: lower)
                return stripped
            }
        }
        return nil
    }

    private static func detectRecurrence(in text: String) -> (option: RecurrenceOption, stripped: String)? {
        let map: [(String, RecurrenceOption)] = [
            ("repeats daily",   .daily),
            ("repeats weekly",  .weekly),
            ("repeats monthly", .monthly),
            ("every day",       .daily),
            ("every week",      .weekly),
            ("every month",     .monthly),
            (" daily",          .daily),
            (" weekly",         .weekly),
            (" monthly",        .monthly),
        ]
        let lower = text.lowercased()
        for (phrase, option) in map {
            if let range = lower.range(of: phrase) {
                let start = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.lowerBound))
                let end = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
                var stripped = text
                stripped.replaceSubrange(start..<end, with: "")
                stripped = stripped.replacingOccurrences(of: ";", with: " ")
                return (option, stripped.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }

    private static func detectDay(in text: String) -> (date: Date, stripped: String)? {
        let cal = Calendar.current
        let lower = text.lowercased()
        let now = Date()

        // Quick keywords first
        if let r = lower.range(of: "tomorrow") {
            let stripped = removeRange(r, from: text, lower: lower)
            return (cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!, stripped)
        }
        if let r = lower.range(of: "today") {
            let stripped = removeRange(r, from: text, lower: lower)
            return (cal.startOfDay(for: now), stripped)
        }
        if let r = lower.range(of: "tonight") {
            let stripped = removeRange(r, from: text, lower: lower)
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = 19
            return (cal.date(from: comps) ?? now, stripped)
        }

        // Weekday names — "monday", "next tuesday", etc.
        let weekdays = [
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7,
        ]
        for (name, weekday) in weekdays {
            // "next <day>" wins over bare "<day>"
            if let r = lower.range(of: "next \(name)") {
                let stripped = removeRange(r, from: text, lower: lower)
                if let d = nextWeekday(weekday, from: now, requireDifferentWeek: true) {
                    return (d, stripped)
                }
            }
            if let r = lower.range(of: name) {
                let stripped = removeRange(r, from: text, lower: lower)
                if let d = nextWeekday(weekday, from: now, requireDifferentWeek: false) {
                    return (d, stripped)
                }
            }
        }
        return nil
    }

    private static func nextWeekday(_ weekday: Int, from date: Date, requireDifferentWeek: Bool) -> Date? {
        var cal = Calendar.current
        cal.timeZone = .current
        var comps = DateComponents()
        comps.weekday = weekday
        let matched = cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime) ?? date
        if requireDifferentWeek,
           cal.isDate(matched, equalTo: date, toGranularity: .weekOfYear) {
            return cal.date(byAdding: .day, value: 7, to: matched)
        }
        return matched
    }

    private static func detectTime(in text: String, anchor: Date) -> (start: Date, end: Date, stripped: String)? {
        // Matches "at 2pm", "at 14:00", "2pm", "9-10am", "14:00-15:30"
        let cal = Calendar.current
        let lower = text.lowercased()
        let patterns: [(String, Bool)] = [
            // (regex, has range)
            (#"\bat (\d{1,2})(?::(\d{2}))? ?(am|pm)?\b"#, false),
            (#"\b(\d{1,2})(?::(\d{2}))? ?(am|pm) ?[-–to] ?(\d{1,2})(?::(\d{2}))? ?(am|pm)?\b"#, true),
            (#"\b(\d{1,2}):(\d{2}) ?[-–to] ?(\d{1,2}):(\d{2})\b"#, true),
            (#"\b(\d{1,2})(?::(\d{2}))? ?(am|pm)\b"#, false),
        ]
        for (pattern, _) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(lower.startIndex..., in: lower)
            guard let m = re.firstMatch(in: lower, options: [], range: range) else { continue }
            // Extract by reading the matched substring back through DateFormatter.
            let matched = (lower as NSString).substring(with: m.range)
            if let parsedRange = parseTimeRange(matched, anchor: anchor) {
                let stripped = removeNSRange(m.range, from: text, lower: lower)
                let cleaned = stripped
                    .replacingOccurrences(of: "  ", with: " ")
                    .replacingOccurrences(of: " at ", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let endDate = parsedRange.end ?? (cal.date(byAdding: .hour, value: 1, to: parsedRange.start) ?? parsedRange.start)
                return (parsedRange.start, endDate, cleaned)
            }
        }
        return nil
    }

    private static func parseTimeRange(_ phrase: String, anchor: Date) -> (start: Date, end: Date?)? {
        // Hand-rolled rather than DateFormatter — we accept many shapes.
        let normalized = phrase
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: " to ", with: "-")
            .replacingOccurrences(of: " at ", with: "")
            .replacingOccurrences(of: " ", with: "")
        let parts = normalized.split(separator: "-").map(String.init)
        let cal = Calendar.current
        let base = cal.startOfDay(for: anchor)

        func toMinutes(_ s: String, fallbackPM: Bool) -> Int? {
            let lower = s.lowercased()
            let isPM: Bool
            var body = lower
            if lower.hasSuffix("pm") { isPM = true; body.removeLast(2) }
            else if lower.hasSuffix("am") { isPM = false; body.removeLast(2) }
            else { isPM = fallbackPM }
            let pieces = body.split(separator: ":").map(String.init)
            guard let hourStr = pieces.first, let hour = Int(hourStr) else { return nil }
            let minute = pieces.count > 1 ? (Int(pieces[1]) ?? 0) : 0
            var h = hour
            if isPM && h < 12 { h += 12 }
            if !isPM && h == 12 { h = 0 }
            // Heuristic for "14" without am/pm: treat 13-23 as 24-hour
            if !lower.hasSuffix("am"), !lower.hasSuffix("pm"), hour >= 13, hour <= 23 {
                h = hour
            }
            return h * 60 + minute
        }

        guard parts.count >= 1 else { return nil }
        // PM heuristic: "9-10am" → both PM/AM use the trailing meridiem.
        let trailingIsPM = parts.last?.lowercased().hasSuffix("pm") ?? false
        guard let startMin = toMinutes(parts[0], fallbackPM: trailingIsPM) else { return nil }
        let start = cal.date(byAdding: .minute, value: startMin, to: base) ?? anchor

        guard parts.count >= 2 else {
            return (start, nil)
        }
        guard let endMin = toMinutes(parts[1], fallbackPM: trailingIsPM) else {
            return (start, nil)
        }
        let end = cal.date(byAdding: .minute, value: endMin, to: base) ?? start
        return (start, end)
    }

    private static func detectURL(in text: String) -> (url: String, stripped: String)? {
        guard let re = try? NSRegularExpression(pattern: #"https?://\S+"#, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range),
              let r = Range(m.range, in: text) else { return nil }
        let url = String(text[r])
        var stripped = text
        stripped.removeSubrange(r)
        return (url, stripped.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func detectLocation(in text: String) -> (place: String, stripped: String)? {
        // Naive "at <Place>" detection — only fires if the phrase
        // doesn't look like a time. Times are removed before we get
        // here, so any remaining "at X" is a location.
        guard let re = try? NSRegularExpression(
            pattern: #"\bat ([A-Z][\w &'-]+)\b"#,
            options: []
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges >= 2,
              let r = Range(m.range, in: text),
              let placeR = Range(m.range(at: 1), in: text) else { return nil }
        let place = String(text[placeR])
        var stripped = text
        stripped.removeSubrange(r)
        return (place, stripped.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func removeRange(_ r: Range<String.Index>, from text: String, lower: String) -> String {
        let start = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))
        let end = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.upperBound))
        var stripped = text
        stripped.replaceSubrange(start..<end, with: "")
        return stripped
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeNSRange(_ range: NSRange, from text: String, lower: String) -> String {
        guard let r = Range(range, in: lower) else { return text }
        return removeRange(r, from: text, lower: lower)
    }
}

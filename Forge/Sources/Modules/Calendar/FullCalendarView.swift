import SwiftUI
import AppKit

/// Notion-Calendar-style full-window calendar. Week view with hourly grid.
/// Read-only in this iteration; editing/sync will arrive in follow-up work.
struct FullCalendarView: View {
    @EnvironmentObject var calendarModule: CalendarModule
    @EnvironmentObject var settings: SettingsManager

    @State private var anchorDate: Date = Date()        // first day of week shown
    @State private var selectedEvent: CalendarEvent?
    @State private var now: Date = Date()
    @State private var newEventSlot: NewEventSlot?      // empty-slot tap → create sheet
    @State private var editingEvent: CalendarEvent?     // event-tap "Edit" → edit sheet

    private let hourHeight: CGFloat = 60
    private let hourColumnWidth: CGFloat = 60
    private let sidePanelWidth: CGFloat = 320
    private let dayHeaderHeight: CGFloat = 56
    private let allDayBandHeight: CGFloat = 28

    private var cal: Calendar {
        var c = Calendar.current
        c.firstWeekday = settings.weekStartsOnMonday ? 2 : 1
        return c
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            if let event = selectedEvent {
                EventDetailSidePanel(
                    event: event,
                    onClose: { selectedEvent = nil },
                    onEdit: {
                        // Stash the event for editing and close the panel.
                        editingEvent = event
                        selectedEvent = nil
                    }
                )
                .frame(width: sidePanelWidth)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(ForgeTheme.Colors.pageBg)
        .preferredColorScheme(settings.theme.colorScheme)
        .onAppear {
            anchorDate = startOfWeek(for: Date())
            startTimer()
        }
        .animation(.easeOut(duration: 0.2), value: selectedEvent?.id)
        .sheet(item: $newEventSlot) { slot in
            NewEventSheet(start: slot.start) { newEvent in
                // Optimistic insert; CalendarModule.loadEvents() will catch up
                if let ev = newEvent {
                    calendarModule.events.append(ev)
                }
                newEventSlot = nil
            }
        }
        .sheet(item: $editingEvent) { event in
            NewEventSheet(start: event.startDate, editing: event) { result in
                // result == nil ⇒ deleted (or cancelled). On real cancel
                // there's no API call, so removing-by-id is a no-op for
                // events that still exist on the server — the next
                // refresh will re-insert if necessary.
                if let updated = result {
                    // Replace in place
                    if let idx = calendarModule.events.firstIndex(where: { $0.id == updated.id }) {
                        calendarModule.events[idx] = updated
                    }
                } else {
                    // Treat nil as "event no longer exists" — remove it
                    // locally so the UI updates instantly. A real refresh
                    // will reconcile.
                    calendarModule.events.removeAll { $0.id == event.id }
                }
                editingEvent = nil
                // Kick a real refresh to reconcile state with Google.
                calendarModule.loadEvents()
            }
        }
    }

    struct NewEventSlot: Identifiable {
        let id = UUID()
        let start: Date
    }

    // MARK: - Main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            toolbar
            weekHeader
            allDayBand
            Divider().opacity(0.12)
            // NSScrollView-backed so scroll wheel events reliably work.
            // Trade-off: lost ScrollViewReader auto-scroll to current hour;
            // user opens to the top by default for now.
            ScrollableContainer {
                ZStack(alignment: .topLeading) {
                    hourGrid
                    eventsLayer
                    if cal.isDate(now, equalTo: anchorDate, toGranularity: .weekOfYear) ||
                       cal.isDate(now, inSameDayAs: weekDays.first ?? Date()) ||
                       weekDays.contains(where: { cal.isDate($0, inSameDayAs: now) }) {
                        currentTimeLine
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(weekTitle)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(ForgeTheme.Colors.textPrimary)

            Spacer()

            HStack(spacing: 6) {
                Button { goToToday() } label: {
                    Text("Today")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.05)))
                        .overlay(Capsule().stroke(Color.black.opacity(0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)

                chevronButton(icon: "chevron.left",  action: { shiftWeek(by: -1) })
                chevronButton(icon: "chevron.right", action: { shiftWeek(by:  1) })
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(ForgeTheme.Colors.pageBgWarm)
    }

    private func chevronButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.black.opacity(0.04)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Week header (7 day columns)

    private var weekHeader: some View {
        HStack(spacing: 0) {
            // Spacer aligned with hour column
            Color.clear.frame(width: hourColumnWidth, height: dayHeaderHeight)
            ForEach(weekDays, id: \.self) { day in
                let isToday = cal.isDateInToday(day)
                VStack(spacing: 4) {
                    Text(dayOfWeekLabel(day))
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.6)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    ZStack {
                        if isToday {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(ForgeTheme.Colors.accent)
                                .frame(width: 26, height: 26)
                        }
                        Text("\(cal.component(.day, from: day))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isToday ? .white : ForgeTheme.Colors.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: dayHeaderHeight)
        .background(ForgeTheme.Colors.pageBgWarm.opacity(0.6))
    }

    // MARK: - All-day band

    private var allDayBand: some View {
        HStack(spacing: 0) {
            Text("all-day")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.5)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .frame(width: hourColumnWidth, height: allDayBandHeight, alignment: .trailing)
                .padding(.trailing, 6)

            ForEach(weekDays, id: \.self) { day in
                let events = allDayEvents(on: day)
                ZStack(alignment: .leading) {
                    Color.clear
                    if !events.isEmpty {
                        HStack(spacing: 2) {
                            ForEach(events.prefix(2), id: \.id) { ev in
                                Text(ev.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(ev.calendarColor.opacity(0.85))
                                    )
                                    .onTapGesture { selectedEvent = ev }
                            }
                            if events.count > 2 {
                                Text("+\(events.count - 2)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: allDayBandHeight)
    }

    // MARK: - Hour grid

    private var hourGrid: some View {
        HStack(spacing: 0) {
            // Hours column
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    HStack {
                        Spacer()
                        Text(hourLabel(hour))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.trailing, 8)
                            .padding(.top, -6)  // align with grid line
                    }
                    .frame(height: hourHeight, alignment: .top)
                    .id("hour-\(hour)")
                }
            }
            .frame(width: hourColumnWidth)

            // Day columns
            ForEach(weekDays, id: \.self) { day in
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        Rectangle()
                            .fill(ForgeTheme.Colors.borderSubtle)
                            .frame(height: 1)
                        // Empty-slot row — tap to create event at this hour
                        Color.clear
                            .frame(height: hourHeight - 1)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                print("[Forge Calendar] empty-slot tap day=\(day) hour=\(hour)")
                                let cal2 = self.cal
                                let comps = cal2.dateComponents([.year, .month, .day], from: day)
                                var c = comps
                                c.hour = hour
                                c.minute = 0
                                if let start = cal2.date(from: c) {
                                    newEventSlot = NewEventSlot(start: start)
                                    print("[Forge Calendar] newEventSlot set to \(start)")
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay(
                    Rectangle()
                        .fill(ForgeTheme.Colors.borderDefault)
                        .frame(width: 1),
                    alignment: .leading
                )
            }
        }
    }

    // MARK: - Events overlay layer
    //
    // We layer two passes here, in z-order:
    //   1. Empty-slot tap targets (one per hour×day) — bottom of this layer
    //   2. EventBlock buttons — top
    //
    // Both live in the SAME GeometryReader so they share coordinates. The empty
    // tap targets are above the visual hourGrid below, so taps land here first.

    private var eventsLayer: some View {
        GeometryReader { geo in
            let dayWidth = (geo.size.width - hourColumnWidth) / CGFloat(7)
            ZStack(alignment: .topLeading) {
                // 1. Empty-slot tap targets — fire when no event covers the cell
                ForEach(Array(weekDays.enumerated()), id: \.offset) { (dayIdx, day) in
                    ForEach(0..<24, id: \.self) { hour in
                        Color.clear
                            .frame(width: dayWidth, height: hourHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                print("[Forge Calendar] empty-slot tap day=\(day) hour=\(hour)")
                                var c = cal.dateComponents([.year, .month, .day], from: day)
                                c.hour = hour; c.minute = 0
                                if let start = cal.date(from: c) {
                                    newEventSlot = NewEventSlot(start: start)
                                }
                            }
                            .offset(
                                x: hourColumnWidth + CGFloat(dayIdx) * dayWidth,
                                y: CGFloat(hour) * hourHeight
                            )
                    }
                }

                // 2. Event blocks above the cell tap targets
                ForEach(Array(weekDays.enumerated()), id: \.offset) { (dayIdx, day) in
                    let dayEvents = timedEvents(on: day)
                    ForEach(dayEvents, id: \.id) { event in
                        EventBlock(
                            event: event,
                            isSelected: selectedEvent?.id == event.id,
                            onTap: { selectedEvent = event }
                        )
                        .frame(width: dayWidth - 6, height: eventHeight(for: event))
                        .offset(
                            x: hourColumnWidth + CGFloat(dayIdx) * dayWidth + 3,
                            y: eventYOffset(for: event)
                        )
                    }
                }
            }
            .frame(width: geo.size.width, height: CGFloat(24) * hourHeight, alignment: .topLeading)
        }
        .frame(height: CGFloat(24) * hourHeight)
    }

    // MARK: - Current-time red line

    private var currentTimeLine: some View {
        GeometryReader { geo in
            let dayWidth = (geo.size.width - hourColumnWidth) / CGFloat(7)
            let hourFraction = CGFloat(cal.component(.hour, from: now)) +
                CGFloat(cal.component(.minute, from: now)) / 60.0
            let y = hourFraction * hourHeight
            let todayIndex = weekDays.firstIndex(where: { cal.isDate($0, inSameDayAs: now) })

            ZStack(alignment: .topLeading) {
                if let idx = todayIndex {
                    HStack(spacing: 0) {
                        // The pill on the hours column
                        Text(currentTimeString)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(ForgeTheme.Colors.accent))
                            .offset(x: hourColumnWidth - 50, y: -8)

                        // The red line across the day column
                        Spacer().frame(width: max(0, hourColumnWidth + CGFloat(idx) * dayWidth - (hourColumnWidth - 50) - 36))
                        Rectangle()
                            .fill(ForgeTheme.Colors.accent)
                            .frame(width: dayWidth, height: 1.5)
                    }
                    .offset(y: y)
                }
            }
            .frame(width: geo.size.width)
        }
        .frame(height: CGFloat(24) * hourHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Computed helpers

    private var weekDays: [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: anchorDate) }
    }

    private var weekTitle: String {
        let f = DateFormatter()
        if let first = weekDays.first, let last = weekDays.last {
            if cal.component(.month, from: first) == cal.component(.month, from: last) {
                f.dateFormat = "MMMM yyyy"
                return f.string(from: first)
            } else {
                f.dateFormat = "MMM"
                return "\(f.string(from: first)) – \(f.string(from: last))"
            }
        }
        return ""
    }

    private var currentTimeString: String {
        let f = DateFormatter()
        f.dateFormat = settings.use24HourTime ? "HH:mm" : "h:mm a"
        return f.string(from: now)
    }

    private func dayOfWeekLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: day)
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "12 AM" }
        if hour == 12 { return "12 PM" }
        if settings.use24HourTime { return String(format: "%02d:00", hour) }
        return hour < 12 ? "\(hour) AM" : "\(hour - 12) PM"
    }

    private func timedEvents(on day: Date) -> [CalendarEvent] {
        calendarModule.events
            .filter { !$0.isAllDay }
            .filter { cal.isDate($0.startDate, inSameDayAs: day) }
            .sorted { $0.startDate < $1.startDate }
    }

    private func allDayEvents(on day: Date) -> [CalendarEvent] {
        calendarModule.events.filter { event in
            event.isAllDay && cal.isDate(event.startDate, inSameDayAs: day)
        }
    }

    private func eventYOffset(for event: CalendarEvent) -> CGFloat {
        let hour = CGFloat(cal.component(.hour, from: event.startDate))
        let minute = CGFloat(cal.component(.minute, from: event.startDate))
        return (hour + minute / 60.0) * hourHeight
    }

    private func eventHeight(for event: CalendarEvent) -> CGFloat {
        let duration = event.endDate.timeIntervalSince(event.startDate)
        let h = CGFloat(duration / 3600.0) * hourHeight
        return max(24, h - 2)
    }

    private func startOfWeek(for date: Date) -> Date {
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }

    private func shiftWeek(by delta: Int) {
        if let new = cal.date(byAdding: .weekOfYear, value: delta, to: anchorDate) {
            anchorDate = new
            calendarModule.selectedDate = new
            calendarModule.loadEvents()
        }
    }

    private func goToToday() {
        anchorDate = startOfWeek(for: Date())
        calendarModule.selectedDate = Date()
        calendarModule.loadEvents()
    }

    // MARK: - Timer for current-time line

    private func startTimer() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            self.now = Date()
        }
    }
}

// MARK: - Event Block

private struct EventBlock: View {
    let event: CalendarEvent
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(event.calendarColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeString)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                    Text(event.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                    if event.attendeeCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 7))
                            Text("\(event.attendeeCount)")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.75))
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(event.calendarColor.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
            )
            .shadow(color: isSelected ? .black.opacity(0.2) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: event.startDate)) – \(f.string(from: event.endDate))"
    }
}

// MARK: - Side Detail Panel

private struct EventDetailSidePanel: View {
    let event: CalendarEvent
    let onClose: () -> Void
    let onEdit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Event")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.black.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }

                // Title row + calendar dot
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(event.calendarColor).frame(width: 10, height: 10).padding(.top, 5)
                    Text(event.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                }

                // Calendar + time
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .foregroundColor(.secondary)
                        Text(event.calendarTitle)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .foregroundColor(.secondary)
                        Text(timeRangeString)
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(ForgeTheme.Colors.textSecondary)

                // Join button
                if event.hasMeetingLink, let url = event.meetingURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        HStack {
                            Image(systemName: "video.fill")
                            Text("Join Meeting")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Capsule().fill(Color(red: 0.06, green: 0.45, blue: 0.95)))
                    }
                    .buttonStyle(.plain)
                }

                // Location
                if let loc = event.location, !loc.isEmpty {
                    sectionLabel("Location")
                    Text(loc)
                        .font(.system(size: 12))
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                }

                // Notes
                if let notes = event.notes, !notes.isEmpty {
                    sectionLabel("Notes")
                    Text(notes)
                        .font(.system(size: 12))
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Participants stub
                if event.attendeeCount > 0 {
                    sectionLabel("Participants")
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .foregroundColor(.secondary)
                        Text("\(event.attendeeCount) invited")
                            .font(.system(size: 12))
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                    }
                }

                Spacer(minLength: 20)

                // Edit button (only meaningful for Google events — the
                // editor sheet can only round-trip those right now).
                if event.isGoogleEvent {
                    Button(action: onEdit) {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil")
                            Text("Edit event")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Capsule().fill(ForgeTheme.Colors.accent))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("This event lives in EventKit — open the system Calendar to edit.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(18)
        }
        .background(ForgeTheme.Colors.pageBgWarm.opacity(0.6))
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(width: 1),
            alignment: .leading
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(.secondary)
            .padding(.top, 6)
    }

    private var timeRangeString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "\(f.string(from: event.startDate)) – \(DateFormatter.localizedString(from: event.endDate, dateStyle: .none, timeStyle: .short))"
    }
}

// MARK: - New Event sheet (Dot-style minimal create dialog)

struct NewEventSheet: View {
    /// Pass `start` to create a new event in an empty slot, OR `editing`
    /// to load an existing event into the form for edit + delete.
    let start: Date
    let editing: CalendarEvent?
    let onDone: (CalendarEvent?) -> Void

    @State private var title: String = ""
    @State private var startDate: Date
    @State private var duration: Int = 30      // minutes — default to a half-hour slot
    @State private var location: String = ""
    @State private var meetingURL: String = ""
    @State private var calendarAccount: String = ""
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var errorText: String?
    @State private var confirmDelete = false
    /// When true, send `conferenceData.createRequest` so Google mints a
    /// Meet room. The generated URL replaces the manual `meetingURL`
    /// field on save.
    @State private var addGoogleMeet: Bool = false

    @ObservedObject private var google = GoogleCalendarService.shared

    init(start: Date,
         editing: CalendarEvent? = nil,
         onDone: @escaping (CalendarEvent?) -> Void) {
        self.start = start
        self.editing = editing
        self.onDone = onDone
        if let ev = editing {
            // Pre-populate from the existing event
            _title = State(initialValue: ev.title)
            _startDate = State(initialValue: ev.startDate)
            _duration = State(initialValue: max(
                15,
                Int(ev.endDate.timeIntervalSince(ev.startDate) / 60)
            ))
            _location = State(initialValue: ev.location ?? "")
            _meetingURL = State(initialValue: ev.meetingURL?.absoluteString ?? "")
            _calendarAccount = State(initialValue:
                ev.googleRouting?.accountEmail
                ?? GoogleCalendarService.shared.accounts.first?.email
                ?? ""
            )
        } else {
            _startDate = State(initialValue: start)
            _calendarAccount = State(initialValue:
                GoogleCalendarService.shared.accounts.first?.email ?? ""
            )
        }
    }

    /// True when the sheet is in edit mode AND the event came from Google
    /// (so we have routing info to PATCH/DELETE).
    private var isEditingGoogleEvent: Bool {
        editing?.googleRouting != nil
    }

    /// Sub-text shown under the "Add Google Meet" toggle so the user
    /// knows what flipping it on actually does in the current context.
    private var meetSubtitle: String {
        if editing != nil, editing?.meetingURL != nil {
            return "Replaces the existing meeting link with a new Meet room."
        }
        return "Generates a fresh meet.google.com link when you save."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "New event" : "Edit event")
                .font(.system(size: 18, weight: .bold))

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium))

            HStack(spacing: 10) {
                DatePicker("Start", selection: $startDate)
                    .labelsHidden()
                    .datePickerStyle(.field)
                Picker("Duration", selection: $duration) {
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("45 min").tag(45)
                    Text("1 hour").tag(60)
                    Text("90 min").tag(90)
                    Text("2 hours").tag(120)
                }
                .labelsHidden()
                .frame(width: 120)
            }

            TextField("Location (optional)", text: $location)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            TextField("Meeting URL (optional)", text: $meetingURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .disabled(addGoogleMeet)
                .opacity(addGoogleMeet ? 0.4 : 1)

            // "Add Google Meet" toggle — uses Forge's compact pill switch
            // (the system .switch style stretches its label-area width and
            // looked off here). When ON, Google mints a fresh Meet room
            // on save and the manual URL field is ignored; for edits it
            // attaches a Meet to events that don't have one.
            if !google.accounts.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.0, green: 0.67, blue: 0.42))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Add Google Meet")
                            .font(.system(size: 12, weight: .medium))
                        Text(meetSubtitle)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $addGoogleMeet)
                        .toggleStyle(.forge)
                        .labelsHidden()
                        .tint(ForgeTheme.Colors.accent)
                }
            }

            // Calendar destination
            if !google.accounts.isEmpty {
                HStack(spacing: 8) {
                    Text("Calendar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Picker("", selection: $calendarAccount) {
                        ForEach(google.accounts) { acc in
                            HStack {
                                Circle().fill(Color(hex: acc.colorHex)).frame(width: 8, height: 8)
                                Text(acc.email)
                            }
                            .tag(acc.email)
                        }
                    }
                    .labelsHidden()
                }
            } else {
                Text("No Google account connected — event will only show locally.")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            if let err = errorText {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            HStack {
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)

                // Delete button (edit mode + Google routing only)
                if isEditingGoogleEvent {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        HStack(spacing: 5) {
                            if isDeleting {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text("Delete")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(
                            Capsule().fill(Color.red.opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting || isSaving)
                    .confirmationDialog(
                        "Delete this event?",
                        isPresented: $confirmDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Delete event", role: .destructive) {
                            Task { await deleteFromGoogle() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This permanently removes the event from your Google calendar.")
                    }
                }

                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Text(editing == nil ? "Create event" : "Save changes")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(ForgeTheme.Colors.accent))
                }
                .buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving || isDeleting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Delete the event from Google, then dismiss the sheet. The calendar
    /// module will pick up the deletion on its next refresh; we also
    /// forward a `nil` result so callers know to remove it from memory.
    private func deleteFromGoogle() async {
        guard let routing = editing?.googleRouting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await GoogleCalendarService.shared.deleteEvent(
                accountEmail: routing.accountEmail,
                calendarId: routing.calendarId,
                eventId: routing.eventId
            )
            // Signal "deletion" by closing with nil — the caller treats
            // nil-on-edit as "the event no longer exists, refresh".
            onDone(nil)
        } catch {
            errorText = "Couldn't delete: \(error.localizedDescription)"
        }
    }

    private func save() async {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        let end = startDate.addingTimeInterval(TimeInterval(duration * 60))

        // EDIT MODE — PATCH the existing Google event
        if let routing = editing?.googleRouting {
            do {
                let result = try await GoogleCalendarService.shared.updateEvent(
                    accountEmail: routing.accountEmail,
                    calendarId: routing.calendarId,
                    eventId: routing.eventId,
                    title: trimmed,
                    start: startDate,
                    end: end,
                    location: location.isEmpty ? nil : location,
                    notes: nil,
                    meetingURL: meetingURL.isEmpty ? nil : meetingURL,
                    generateMeet: addGoogleMeet
                )
                // If Google minted a Meet URL, use that. Otherwise fall
                // back to whatever the user typed (or kept) in the field.
                let finalMeetingURLString = result.meetingURL
                    ?? (meetingURL.isEmpty ? nil : meetingURL)
                let finalMeetingURL = finalMeetingURLString.flatMap { URL(string: $0) }
                // Hand back an updated CalendarEvent so the UI can refresh
                // immediately without waiting for the next fetch.
                let updated = CalendarEvent(
                    id: editing!.id,
                    title: trimmed,
                    startDate: startDate,
                    endDate: end,
                    isAllDay: editing!.isAllDay,
                    calendarColor: editing!.calendarColor,
                    calendarTitle: editing!.calendarTitle,
                    location: location.isEmpty ? nil : location,
                    notes: editing!.notes,
                    meetingURL: finalMeetingURL,
                    attendeeCount: editing!.attendeeCount,
                    googleRouting: routing
                )
                onDone(updated)
            } catch {
                errorText = "Couldn't save: \(error.localizedDescription)"
            }
            return
        }

        // CREATE MODE — push to Google if an account is selected
        if !calendarAccount.isEmpty,
           let account = google.accounts.first(where: { $0.email == calendarAccount }) {
            do {
                let result = try await GoogleCalendarService.shared.createEvent(
                    on: account.email,
                    title: trimmed,
                    start: startDate,
                    end: end,
                    location: location.isEmpty ? nil : location,
                    meetingURL: meetingURL.isEmpty ? nil : meetingURL,
                    generateMeet: addGoogleMeet
                )
                // Prefer the Google-minted Meet URL when present, fall
                // back to whatever the user typed in the field.
                let finalMeetingURLString = result.meetingURL
                    ?? (meetingURL.isEmpty ? nil : meetingURL)
                let finalMeetingURL = finalMeetingURLString.flatMap { URL(string: $0) }
                let preview = CalendarEvent(
                    id: "google:\(result.eventId)",
                    title: trimmed,
                    startDate: startDate,
                    endDate: end,
                    isAllDay: false,
                    calendarColor: Color(hex: account.colorHex),
                    calendarTitle: account.email,
                    location: location.isEmpty ? nil : location,
                    notes: nil,
                    meetingURL: finalMeetingURL,
                    attendeeCount: 0,
                    googleRouting: .init(
                        accountEmail: result.accountEmail,
                        calendarId: result.calendarId,
                        eventId: result.eventId
                    )
                )
                onDone(preview)
            } catch {
                errorText = "Couldn't create on Google: \(error.localizedDescription)"
            }
        } else {
            // No Google account — just show locally for now
            let preview = CalendarEvent(
                id: "local:\(UUID().uuidString)",
                title: trimmed,
                startDate: startDate,
                endDate: end,
                isAllDay: false,
                calendarColor: ForgeTheme.Colors.accent,
                calendarTitle: "Local",
                location: location.isEmpty ? nil : location,
                notes: nil,
                meetingURL: meetingURL.isEmpty ? nil : URL(string: meetingURL),
                attendeeCount: 0
            )
            onDone(preview)
        }
    }
}

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
            // Quick natural-language create. The full editor is still
            // the path for edits, but creating goes through the
            // minimal Cron-style flow.
            QuickCreateEventSheet(defaultStart: slot.start) { newEvent in
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

/// Hover/detail card for a single event — modelled on the reference
/// screenshots. Floats inside the right-rail with rounded corners,
/// shows a countdown badge (NOW / in 1h 23m), a prominent Join button,
/// an attachment-icons row, the raw meeting URL, notes, and a footer
/// with Edit / Reminder / Copy / Delete actions.
///
/// Theme is honoured: light surface uses `surfaceCard`, dark uses a
/// deep-blue surface to match the dark reference frame.
private struct EventDetailSidePanel: View {
    let event: CalendarEvent
    let onClose: () -> Void
    let onEdit: () -> Void

    @EnvironmentObject private var calendarModule: CalendarModule
    @Environment(\.colorScheme) private var colorScheme
    @State private var now: Date = Date()
    @State private var didCopyToast: String?
    @State private var confirmDelete = false
    @State private var isDeleting = false

    var body: some View {
        VStack(spacing: 0) {
            // The card itself is inset from the rail edges so it reads
            // as a floating object — matches the reference layout.
            ScrollView {
                cardBody
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
        }
        .background(railBackground)
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(width: 1),
            alignment: .leading
        )
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: - Card

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: title + close
            HStack(alignment: .top) {
                Text(event.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(cardTextPrimary)
                    .lineLimit(3)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(cardTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(cardChipBg))
                }
                .buttonStyle(.plain)
            }

            // Calendar pill
            HStack(spacing: 6) {
                Circle().fill(event.calendarColor).frame(width: 6, height: 6)
                Text(event.calendarTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(cardTextSecondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(cardChipBg))
            .overlay(Capsule().strokeBorder(cardBorder, lineWidth: 0.5))

            // Date + time + countdown badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(longDateString)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(cardTextPrimary)
                    HStack(spacing: 6) {
                        Text(timeRangeString)
                            .font(.system(size: 12))
                            .foregroundColor(cardTextSecondary)
                        Text("·")
                            .foregroundColor(cardTextSecondary.opacity(0.4))
                        Text(durationString)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(cardTextSecondary)
                    }
                }
                Spacer()
                countdownBadge
            }

            Divider().opacity(0.12)

            // Join button — MeetingLauncher prefers native Zoom /
            // Teams / Webex when those apps are installed. `.join`
            // also fires `.meetingJoined` so the reminder banner
            // drops this event from its watch list.
            if event.hasMeetingLink, let url = event.meetingURL {
                Button { MeetingLauncher.join(event) } label: {
                    HStack(spacing: 10) {
                        MeetingIconBadge(url: url)
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Join")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(cardTextPrimary)
                            Text(url.host ?? url.absoluteString)
                                .font(.system(size: 11))
                                .foregroundColor(cardTextSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(cardTextSecondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(cardChipBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(cardBorder, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }

            // Attachment icons row — Figma/Notion/GitHub etc.
            if !event.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(event.attachments.prefix(6)) { att in
                        AttachmentIconChip(attachment: att, isDark: colorScheme == .dark)
                    }
                    if event.attachments.count > 6 {
                        Text("+\(event.attachments.count - 6)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(cardTextSecondary)
                    }
                }
            }

            // Raw meeting URL (the paper-plane row from the reference)
            if let url = event.meetingURL?.absoluteString {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                        .frame(width: 14)
                    Text(url)
                        .font(.system(size: 11))
                        .foregroundColor(cardTextPrimary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            // Location
            if let loc = event.location, !loc.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 11))
                        .foregroundColor(cardTextSecondary)
                        .frame(width: 14)
                    Text(loc)
                        .font(.system(size: 11))
                        .foregroundColor(cardTextPrimary)
                        .lineLimit(2)
                }
            }

            // Notes
            if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
               !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 11))
                            .foregroundColor(cardTextSecondary)
                            .frame(width: 14)
                        Text("Notes")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(cardTextSecondary)
                    }
                    Text(notes)
                        .font(.system(size: 12))
                        .foregroundColor(cardTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(4)
                }
            }

            // Attendees count
            if event.attendeeCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                        .foregroundColor(cardTextSecondary)
                        .frame(width: 14)
                    Text("\(event.attendeeCount) invited · \(event.confirmedAttendeeCount) accepted")
                        .font(.system(size: 11))
                        .foregroundColor(cardTextSecondary)
                }
            }

            Divider().opacity(0.12)

            footerActions
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.08),
                radius: 18, y: 6)
        .overlay(alignment: .top) {
            if let toast = didCopyToast {
                Text(toast)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.top, -12)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack(spacing: 14) {
            if event.isGoogleEvent {
                footerButton(icon: "pencil", label: "Edit", action: onEdit)
            }
            // Reminder summary — first override or default. Tap opens
            // the full editor where the user can change it.
            footerButton(
                icon: "bell",
                label: reminderLabel,
                action: { if event.isGoogleEvent { onEdit() } }
            )
            // Copy menu
            Menu {
                Button("Copy Event Details") { copy(detailsBlob) }
                Button("Copy Title")         { copy(event.title) }
                if let loc = event.location, !loc.isEmpty {
                    Button("Copy Location")  { copy(loc) }
                }
                if let url = event.meetingURL?.absoluteString {
                    Button("Copy Meeting Link") { copy(url) }
                }
                if let notes = event.notes, !notes.isEmpty {
                    Button("Copy Notes")     { copy(notes) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                    Text("Copy")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(cardTextPrimary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()
            if event.isGoogleEvent {
                Button {
                    confirmDelete = true
                } label: {
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    "Delete this event?",
                    isPresented: $confirmDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete event", role: .destructive) {
                        Task { await deleteEvent() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently removes \"\(event.title)\" from your Google calendar.")
                }
            }
        }
    }

    private func footerButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(cardTextPrimary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Theme tokens (light vs dark)

    private var cardBg: Color {
        colorScheme == .dark
            ? Color(red: 0.13, green: 0.17, blue: 0.27)   // deep midnight blue
            : ForgeTheme.Colors.surfaceCard
    }
    private var cardChipBg: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }
    private var cardBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
    private var cardTextPrimary: Color {
        colorScheme == .dark ? Color.white : ForgeTheme.Colors.textPrimary
    }
    private var cardTextSecondary: Color {
        colorScheme == .dark ? Color.white.opacity(0.65) : ForgeTheme.Colors.textSecondary
    }
    private var railBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.07, green: 0.10, blue: 0.18)
            : ForgeTheme.Colors.pageBgWarm.opacity(0.6)
    }

    // MARK: - Derived strings

    private var longDateString: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: event.startDate)
    }

    private var timeRangeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: event.startDate)) – \(f.string(from: event.endDate))"
    }

    private var durationString: String {
        let totalMins = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
        if totalMins >= 60 {
            let h = totalMins / 60
            let m = totalMins % 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(totalMins)m"
    }

    private var reminderLabel: String {
        guard let first = event.remindersMinutes.first else { return "Default" }
        if first == 0 { return "At start" }
        if first >= 60 && first % 60 == 0 {
            let h = first / 60
            return h == 1 ? "1h" : "\(h)h"
        }
        return "\(first)m"
    }

    @ViewBuilder
    private var countdownBadge: some View {
        if event.startDate <= now, event.endDate > now {
            // Now playing
            badgeView(text: "NOW", tint: .blue, fillStrong: true)
        } else if event.startDate > now {
            let secs = event.startDate.timeIntervalSince(now)
            let label = countdownLabel(seconds: secs)
            badgeView(text: label, tint: .blue.opacity(0.85), fillStrong: false)
        } else {
            EmptyView()
        }
    }

    private func badgeView(text: String, tint: Color, fillStrong: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(fillStrong ? .white : .blue)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                Capsule().fill(fillStrong ? tint : tint.opacity(0.15))
            )
    }

    private func countdownLabel(seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "in \(mins)m" }
        let hours = mins / 60
        let remMins = mins % 60
        if hours < 24 {
            return remMins > 0 ? "in \(hours)h \(remMins)m" : "in \(hours)h"
        }
        let days = hours / 24
        return "in \(days)d"
    }

    // MARK: - Actions

    private var detailsBlob: String {
        var lines: [String] = [event.title]
        lines.append("\(longDateString) · \(timeRangeString) (\(durationString))")
        if let loc = event.location, !loc.isEmpty { lines.append("Location: \(loc)") }
        if let url = event.meetingURL?.absoluteString { lines.append("Meeting: \(url)") }
        if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notes.isEmpty {
            lines.append("")
            lines.append(notes)
        }
        return lines.joined(separator: "\n")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { didCopyToast = "Copied" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { didCopyToast = nil }
        }
    }

    private func deleteEvent() async {
        guard let routing = event.googleRouting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await GoogleCalendarService.shared.deleteEvent(
                accountEmail: routing.accountEmail,
                calendarId: routing.calendarId,
                eventId: routing.eventId
            )
            await MainActor.run {
                calendarModule.events.removeAll { $0.id == event.id }
                onClose()
            }
        } catch {
            print("[Forge] delete failed: \(error)")
        }
    }
}

// MARK: - Meeting icon badge

/// Provider-coloured icon shown next to the Join row. Zoom → red,
/// Meet → green, Teams → purple, Webex → teal, fallback → grey.
private struct MeetingIconBadge: View {
    let url: URL
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint)
            Image(systemName: "video.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
    }
    private var tint: Color {
        let s = url.absoluteString.lowercased()
        if s.contains("zoom.us") { return Color(red: 0.91, green: 0.20, blue: 0.20) }
        if s.contains("meet.google") { return Color(red: 0.04, green: 0.61, blue: 0.36) }
        if s.contains("teams.microsoft") { return Color(red: 0.30, green: 0.34, blue: 0.78) }
        if s.contains("webex") { return Color(red: 0.0, green: 0.65, blue: 0.78) }
        return Color.gray
    }
}

// MARK: - Attachment icon chip

/// Square icon for an attachment row. Tries to use Google's iconLink
/// when present (Drive / Notion / GitHub favicons), falls back to an
/// SF symbol picked from the mime type.
private struct AttachmentIconChip: View {
    let attachment: EventAttachment
    let isDark: Bool

    var body: some View {
        Button {
            NSWorkspace.shared.open(attachment.fileURL)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
                if let iconURL = attachment.iconURL {
                    AsyncImage(url: iconURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } placeholder: {
                        Image(systemName: fallbackSymbol)
                            .font(.system(size: 13))
                            .foregroundColor(isDark ? .white : .black.opacity(0.6))
                    }
                } else {
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: 13))
                        .foregroundColor(isDark ? .white.opacity(0.85) : .black.opacity(0.65))
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(attachment.title)
    }

    private var fallbackSymbol: String {
        let host = attachment.fileURL.host?.lowercased() ?? ""
        if host.contains("figma") { return "f.cursive" }
        if host.contains("notion") { return "n.square" }
        if host.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if host.contains("docs.google") || host.contains("drive.google") { return "doc.text" }
        if let mime = attachment.mimeType {
            if mime.contains("pdf") { return "doc.richtext" }
            if mime.contains("image") { return "photo" }
            if mime.contains("video") { return "video" }
        }
        return "link"
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
    @State private var isAllDay: Bool = false
    @State private var location: String = ""
    @State private var meetingURL: String = ""
    @State private var notes: String = ""
    @State private var calendarAccount: String = ""
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var errorText: String?
    @State private var confirmDelete = false
    /// When true, send `conferenceData.createRequest` so Google mints a
    /// Meet room. The generated URL replaces the manual `meetingURL`
    /// field on save.
    @State private var addGoogleMeet: Bool = false

    // Attendees + new-attendee draft
    @State private var attendees: [EventAttendee] = []
    @State private var newAttendeeEmail: String = ""

    // Attachments + new-attachment draft
    @State private var attachments: [EventAttachment] = []
    @State private var newAttachmentTitle: String = ""
    @State private var newAttachmentURL: String = ""

    // Reminders (popup, minutes-before)
    @State private var reminders: [Int] = []

    // RSVP state — drives the Going/Maybe/Decline pill row in edit
    // mode for events the user is invited to. Optimistically updated
    // on tap, reverted by the catch block.
    @State private var myResponseStatus: String?
    @State private var isUpdatingRSVP = false

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
            _isAllDay = State(initialValue: ev.isAllDay)
            _location = State(initialValue: ev.location ?? "")
            _meetingURL = State(initialValue: ev.meetingURL?.absoluteString ?? "")
            // Strip the meeting URL line out of notes — we re-append it
            // on save so it doesn't show up twice in the body.
            _notes = State(initialValue:
                Self.notesWithoutMeetingURL(
                    notes: ev.notes ?? "",
                    meetingURL: ev.meetingURL?.absoluteString
                )
            )
            _attendees = State(initialValue: ev.attendees)
            _attachments = State(initialValue: ev.attachments)
            _reminders = State(initialValue: ev.remindersMinutes)
            _myResponseStatus = State(initialValue: ev.myResponseStatus)
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

    /// True when the current user was invited to this event (not the
    /// organizer). RSVP buttons appear only in this case.
    private var canRSVP: Bool {
        guard let ev = editing, let routing = ev.googleRouting else { return false }
        return ev.attendees.contains { $0.email.caseInsensitiveCompare(routing.accountEmail) == .orderedSame }
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
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(editing == nil ? "New event" : "Edit event")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                if let ev = editing,
                   let link = ev.googleRouting.flatMap({ _ in URL(string: "https://calendar.google.com") }) {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open in Google Calendar")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            // Scrollable form body — handles the many sections without
            // overflowing the screen height.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    titleAndTimeSection
                    if canRSVP { rsvpSection }
                    locationAndMeetingSection
                    descriptionSection
                    attendeesSection
                    attachmentsSection
                    remindersSection
                    calendarPickerSection
                    if let err = errorText {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 520)

            // Footer (always visible, doesn't scroll)
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    Rectangle()
                        .fill(ForgeTheme.Colors.surfaceCard.opacity(0.6))
                        .overlay(
                            Rectangle()
                                .frame(height: 1)
                                .foregroundColor(ForgeTheme.Colors.borderDefault),
                            alignment: .top
                        )
                )
        }
        .frame(width: 500)
    }

    // MARK: - Sections

    private var titleAndTimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium))

            HStack(spacing: 10) {
                DatePicker("Start",
                           selection: $startDate,
                           displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                if !isAllDay {
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
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Text("All day")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Toggle("", isOn: $isAllDay)
                        .toggleStyle(.forge)
                        .labelsHidden()
                }
            }
        }
    }

    private var rsvpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your response")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 6) {
                rsvpPill(label: "Going",   icon: "checkmark", value: "accepted",   tint: .green)
                rsvpPill(label: "Maybe",   icon: "questionmark", value: "tentative", tint: .orange)
                rsvpPill(label: "Decline", icon: "xmark",    value: "declined",  tint: .red)
                if isUpdatingRSVP { ProgressView().controlSize(.small) }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func rsvpPill(label: String, icon: String, value: String, tint: Color) -> some View {
        let selected = (myResponseStatus == value)
        Button {
            Task { await updateRSVP(to: value) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(selected ? .white : tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(selected ? tint : tint.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .disabled(isUpdatingRSVP)
    }

    private var locationAndMeetingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Location (optional)", text: $location)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            TextField("Meeting URL (optional)", text: $meetingURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .disabled(addGoogleMeet)
                .opacity(addGoogleMeet ? 0.4 : 1)

            // "Add Google Meet" toggle — uses Forge's compact pill switch.
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
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(ForgeTheme.Colors.borderDefault, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(ForgeTheme.Colors.surfaceCard)
                    )
                TextEditor(text: $notes)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 70, maxHeight: 110)
                if notes.isEmpty {
                    Text("Agenda, links, prep notes…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.55))
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var attendeesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Attendees")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if !attendees.isEmpty {
                    Text("\(attendees.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer()
            }

            if !attendees.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(attendees) { att in
                        AttendeeChip(attendee: att) {
                            attendees.removeAll { $0.id == att.id }
                        }
                    }
                }
            }

            // Name-first autocomplete — surfaces recent collaborators
            // from past Google events. Falls back to "add as email" if
            // the user types a brand-new address.
            AttendeePickerField(
                query: $newAttendeeEmail,
                existing: attendees,
                onPick: { record in
                    addAttendee(
                        email: record.email,
                        displayName: record.displayName ?? record.displayLabel
                    )
                },
                onAddRaw: {
                    addAttendee(
                        email: newAttendeeEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                        displayName: nil
                    )
                }
            )
        }
    }

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Attachments")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if !attachments.isEmpty {
                    Text("\(attachments.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer()
            }

            ForEach(attachments) { att in
                HStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(att.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(att.fileURL.absoluteString)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        attachments.removeAll { $0.id == att.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(ForgeTheme.Colors.surfaceCard)
                )
            }

            HStack(spacing: 6) {
                TextField("Title", text: $newAttachmentTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 130)
                TextField("https://…", text: $newAttachmentURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { addAttachment() }
                Button { addAttachment() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(
                            Capsule().fill(ForgeTheme.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(URL(string: newAttachmentURL) == nil || newAttachmentURL.isEmpty)
            }
        }
    }

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Reminders")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Menu {
                    Button("At time of event") { addReminder(0) }
                    Button("5 min before")  { addReminder(5) }
                    Button("10 min before") { addReminder(10) }
                    Button("15 min before") { addReminder(15) }
                    Button("30 min before") { addReminder(30) }
                    Button("1 hr before")   { addReminder(60) }
                    Button("1 day before")  { addReminder(1440) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("Add").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(ForgeTheme.Colors.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(
                        Capsule().fill(ForgeTheme.Colors.accent.opacity(0.12))
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if reminders.isEmpty {
                Text("Using calendar default")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(reminders, id: \.self) { mins in
                        HStack(spacing: 5) {
                            Image(systemName: "bell.fill").font(.system(size: 9))
                            Text(Self.reminderLabel(mins))
                                .font(.system(size: 11, weight: .medium))
                            Button {
                                reminders.removeAll { $0 == mins }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundColor(ForgeTheme.Colors.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(
                            Capsule().fill(ForgeTheme.Colors.accent.opacity(0.12))
                        )
                    }
                }
            }
        }
    }

    private var calendarPickerSection: some View {
        Group {
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
                    .disabled(editing != nil)  // can't move events across accounts
                }
            } else {
                Text("No Google account connected — event will only show locally.")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
    }

    private var footer: some View {
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

    // MARK: - Section actions

    /// Add a person to the attendees list. Takes both email and a
    /// best-effort displayName so the chip can show the friendly
    /// label even before Google enriches the response.
    private func addAttendee(email: String, displayName: String?) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isLikelyEmail(trimmed) else { return }
        // Dedupe — already added? Just clear the query.
        guard !attendees.contains(where: { $0.email.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            newAttendeeEmail = ""
            return
        }
        attendees.append(EventAttendee(
            email: trimmed,
            displayName: displayName,
            responseStatus: "needsAction",
            isOrganizer: false
        ))
        newAttendeeEmail = ""
    }

    private func addAttachment() {
        let urlStr = newAttachmentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlStr), !urlStr.isEmpty else { return }
        let title = newAttachmentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        attachments.append(EventAttachment(
            title: title.isEmpty ? url.lastPathComponent : title,
            fileURL: url,
            mimeType: nil,
            iconURL: nil
        ))
        newAttachmentTitle = ""
        newAttachmentURL = ""
    }

    private func addReminder(_ minutes: Int) {
        guard !reminders.contains(minutes) else { return }
        reminders.append(minutes)
        reminders.sort()
    }

    /// Update the user's RSVP via the Google API. Optimistically updates
    /// the local state; reverts on failure so the UI doesn't lie.
    private func updateRSVP(to value: String) async {
        guard
            let ev = editing,
            let routing = ev.googleRouting,
            let rsvp = GoogleCalendarService.RSVPStatus(rawValue: value)
        else { return }
        let previous = myResponseStatus
        myResponseStatus = value
        isUpdatingRSVP = true
        defer { isUpdatingRSVP = false }
        do {
            try await GoogleCalendarService.shared.setRSVP(
                accountEmail: routing.accountEmail,
                calendarId: routing.calendarId,
                eventId: routing.eventId,
                status: rsvp
            )
        } catch {
            myResponseStatus = previous
            errorText = "Couldn't update RSVP: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private static func isLikelyEmail(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = t.firstIndex(of: "@") else { return false }
        let domain = t[t.index(after: at)...]
        return !domain.isEmpty && domain.contains(".")
    }

    private static func reminderLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0:    return "At start"
        case 1440: return "1 day"
        case let m where m % 60 == 0:
            let h = m / 60
            return h == 1 ? "1 hr" : "\(h) hr"
        default:   return "\(minutes) min"
        }
    }

    /// Strip the meeting URL line out of notes so the editor doesn't show
    /// it duplicated alongside the dedicated Meeting URL field.
    private static func notesWithoutMeetingURL(notes: String, meetingURL: String?) -> String {
        guard let url = meetingURL, !url.isEmpty else { return notes }
        return notes
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(url) }
            .joined(separator: "\n")
    }

    // MARK: - Delete

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
            onDone(nil)
        } catch {
            errorText = "Couldn't delete: \(error.localizedDescription)"
        }
    }

    // MARK: - Save

    private func save() async {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        // All-day events: end = start + 1 day (Google expects exclusive end).
        let end = isAllDay
            ? Calendar.current.date(byAdding: .day, value: 1, to: startDate)!
            : startDate.addingTimeInterval(TimeInterval(duration * 60))
        let attendeeEmails = attendees.map(\.email)

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
                    isAllDay: isAllDay,
                    location: location.isEmpty ? nil : location,
                    notes: notes.isEmpty ? "" : notes,
                    meetingURL: meetingURL.isEmpty ? nil : meetingURL,
                    generateMeet: addGoogleMeet,
                    attendees: attendeeEmails,
                    attachments: attachments,
                    remindersMinutes: reminders
                )
                let finalMeetingURLString = result.meetingURL
                    ?? (meetingURL.isEmpty ? nil : meetingURL)
                let finalMeetingURL = finalMeetingURLString.flatMap { URL(string: $0) }
                let updated = CalendarEvent(
                    id: editing!.id,
                    title: trimmed,
                    startDate: startDate,
                    endDate: end,
                    isAllDay: isAllDay,
                    calendarColor: editing!.calendarColor,
                    calendarTitle: editing!.calendarTitle,
                    location: location.isEmpty ? nil : location,
                    notes: notes.isEmpty ? nil : notes,
                    meetingURL: finalMeetingURL,
                    attendeeCount: attendees.count,
                    googleRouting: routing,
                    myResponseStatus: myResponseStatus,
                    confirmedAttendeeCount: editing!.confirmedAttendeeCount,
                    attachments: attachments,
                    attendees: attendees,
                    remindersMinutes: reminders
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
                    isAllDay: isAllDay,
                    location: location.isEmpty ? nil : location,
                    notes: notes.isEmpty ? nil : notes,
                    meetingURL: meetingURL.isEmpty ? nil : meetingURL,
                    generateMeet: addGoogleMeet,
                    attendees: attendeeEmails,
                    attachments: attachments,
                    remindersMinutes: reminders
                )
                let finalMeetingURLString = result.meetingURL
                    ?? (meetingURL.isEmpty ? nil : meetingURL)
                let finalMeetingURL = finalMeetingURLString.flatMap { URL(string: $0) }
                let preview = CalendarEvent(
                    id: "google:\(result.eventId)",
                    title: trimmed,
                    startDate: startDate,
                    endDate: end,
                    isAllDay: isAllDay,
                    calendarColor: Color(hex: account.colorHex),
                    calendarTitle: account.email,
                    location: location.isEmpty ? nil : location,
                    notes: notes.isEmpty ? nil : notes,
                    meetingURL: finalMeetingURL,
                    attendeeCount: attendees.count,
                    googleRouting: .init(
                        accountEmail: result.accountEmail,
                        calendarId: result.calendarId,
                        eventId: result.eventId
                    ),
                    myResponseStatus: nil,
                    confirmedAttendeeCount: 0,
                    attachments: attachments,
                    attendees: attendees,
                    remindersMinutes: reminders
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
                isAllDay: isAllDay,
                calendarColor: ForgeTheme.Colors.accent,
                calendarTitle: "Local",
                location: location.isEmpty ? nil : location,
                notes: notes.isEmpty ? nil : notes,
                meetingURL: meetingURL.isEmpty ? nil : URL(string: meetingURL),
                attendeeCount: attendees.count,
                attachments: attachments,
                attendees: attendees,
                remindersMinutes: reminders
            )
            onDone(preview)
        }
    }
}

// MARK: - Attendee chip

/// Compact chip rendering one attendee with a status pip + remove button.
/// Status colors: green = accepted, orange = tentative, red = declined,
/// grey = needs action.
private struct AttendeeChip: View {
    let attendee: EventAttendee
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(attendee.displayName ?? attendee.email)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if attendee.isOrganizer {
                Text("organizer")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary.opacity(0.65))
        }
        .foregroundColor(ForgeTheme.Colors.textPrimary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            Capsule().fill(ForgeTheme.Colors.surfaceCard)
        )
        .overlay(
            Capsule().strokeBorder(ForgeTheme.Colors.borderDefault, lineWidth: 0.5)
        )
    }

    private var statusColor: Color {
        switch attendee.responseStatus {
        case "accepted":  return .green
        case "tentative": return .orange
        case "declined":  return .red
        default:          return .secondary.opacity(0.55)
        }
    }
}

// MARK: - Flow layout (chip wrapping)

/// Minimal flow layout — wraps children to the next row when they don't
/// fit horizontally. SwiftUI's `Layout` protocol (macOS 13+) makes this a
/// dozen lines instead of a full `GeometryReader` dance.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

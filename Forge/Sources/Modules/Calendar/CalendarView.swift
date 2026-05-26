import SwiftUI

/// The calendar view inside the menu bar popover.
/// Pixel-perfect match of Dot's layout:
/// - Day summary banner with greeting
/// - Month nav with chevrons
/// - 7-column grid: 28px wide cells, 33px tall, 13px font-semibold
/// - Today: dark circle (#1C1917) + white text + pulse animation
/// - Event indicator dots: 3px colored circles below dates
/// - Event list with 3px colored sidebar indicator
/// - World clock strip at bottom
struct CalendarView: View {
    @EnvironmentObject var calendarModule: CalendarModule
    @EnvironmentObject var settings: SettingsManager
    @State private var hoveredDate: Date?
    @State private var todayPulse = false
    /// Carries the start time for a pending create-event sheet. nil ⇒
    /// no sheet open. Set by the "+ ⌘N" button (default start) or by
    /// right-clicking a day cell (cell's date at 9 AM).
    @State private var pendingCreateStart: CreateStart?
    @State private var editingEvent: CalendarEvent?
    /// When set, an inline detail card popover is anchored to the
    /// tapped event row. The Edit / Copy / Delete actions inside that
    /// card route through `editingEvent` (full editor) or directly via
    /// the Google service.
    @State private var detailEvent: CalendarEvent?

    /// Wrapper for `.sheet(item:)` — Date doesn't conform to Identifiable.
    struct CreateStart: Identifiable {
        let id = UUID()
        let date: Date
    }

    private let calendar = Calendar.current

    /// Day-of-week headers, ordered per user's "week starts on" preference.
    private var dayHeaders: [String] {
        settings.weekStartsOnMonday
            ? ["M", "T", "W", "T", "F", "S", "S"]
            : ["S", "M", "T", "W", "T", "F", "S"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Day summary banner
            daySummary

            // Progress strips (year / day) — new
            if settings.showYearProgress || settings.showDayProgress {
                progressStrips
                    .padding(.top, ForgeTheme.Spacing.sm)
            }

            // Month navigation + grid
            monthNavigation
            calendarGrid

            // Divider
            Rectangle()
                .fill(ForgeTheme.Colors.borderSubtle)
                .frame(height: 1)

            // Event list for selected date
            eventList

            // World clock strip (toggleable)
            if settings.showWorldClock {
                worldClockStrip
            }
        }
        // alignment: .leading on the VStack + explicit `.leading` on the
        // outer frame guarantees each child pins to the popover's left
        // edge (matching where "Sun, May 24" sits in the header bar).
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Start today pulse animation
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                todayPulse = true
            }
        }
        // Create-event sheet — triggered by the "+ ⌘N" button next to the
        // TODAY header. Defaults the start time to the next round hour on
        // the currently selected date. Uses the natural-language quick-
        // create sheet; the expanded editor is reachable via the event
        // row's "Edit" action.
        .sheet(item: $pendingCreateStart) { slot in
            QuickCreateEventSheet(defaultStart: slot.date) { created in
                if let ev = created {
                    calendarModule.events.append(ev)
                }
                pendingCreateStart = nil
                calendarModule.loadEvents()
            }
        }
        // Edit-event sheet — triggered by tapping a Google event row.
        .sheet(item: $editingEvent) { event in
            NewEventSheet(start: event.startDate, editing: event) { result in
                if let updated = result {
                    if let idx = calendarModule.events.firstIndex(where: { $0.id == updated.id }) {
                        calendarModule.events[idx] = updated
                    }
                } else {
                    calendarModule.events.removeAll { $0.id == event.id }
                }
                editingEvent = nil
                calendarModule.loadEvents()
            }
        }
    }

    /// Sensible default start for a new event triggered from the popover:
    /// the next round hour on the selected day (e.g. 3:00 PM if it's
    /// currently 2:34 PM on the selected date). For non-today dates we
    /// drop in at 9:00 AM as a safe default.
    private func defaultNewEventStart() -> Date {
        let selected = calendarModule.selectedDate
        let isToday = calendar.isDateInToday(selected)
        let cal = Calendar.current
        if isToday {
            let now = Date()
            let next = cal.date(byAdding: .hour, value: 1, to: now) ?? now
            var comps = cal.dateComponents([.year, .month, .day, .hour], from: next)
            comps.minute = 0
            comps.second = 0
            return cal.date(from: comps) ?? next
        } else {
            var comps = cal.dateComponents([.year, .month, .day], from: selected)
            comps.hour = 9
            comps.minute = 0
            return cal.date(from: comps) ?? selected
        }
    }

    // MARK: - Progress Strips (Year + Day)

    private var progressStrips: some View {
        VStack(spacing: 8) {
            if settings.showYearProgress {
                progressRow(
                    leadingText: "\(Int(yearProgress * 100))% of \(currentYearString)",
                    trailingText: "\(daysLeftInYear) days left",
                    value: yearProgress
                )
            }
            if settings.showDayProgress {
                progressRow(
                    leadingText: "\(Int(dayProgress * 100))% of today",
                    trailingText: timeLeftInDayString,
                    value: dayProgress
                )
            }
        }
        .padding(.bottom, 6)
    }

    private func progressRow(leadingText: String, trailingText: String, value: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(leadingText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                Spacer()
                Text(trailingText)
                    .font(.system(size: 10))
                    .foregroundColor(ForgeTheme.Colors.textTertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ForgeTheme.Colors.borderSubtle)
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ForgeTheme.Colors.accent)
                        .frame(width: max(2, geo.size.width * value), height: 3)
                }
            }
            .frame(height: 3)
        }
    }

    // MARK: - Day Summary — compact single-line (greeting + counts + focus)

    private var daySummary: some View {
        HStack(spacing: 8) {
            Image(systemName: greetingIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ForgeTheme.Colors.accent)

            Text(compactSummary)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .background(ForgeTheme.Colors.pageBgWarm)
    }

    private var greetingIcon: String {
        let hour = calendar.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "sunrise.fill"
        case 12..<17: return "sun.max.fill"
        case 17..<21: return "sunset.fill"
        default:      return "moon.fill"
        }
    }

    /// One-line: "1 event today · 1h focus" (combined, no separate chips)
    private var compactSummary: String {
        let count = calendarModule.todayEvents.count
        let eventStr: String = {
            switch count {
            case 0: return "No events today"
            case 1: return "1 event today"
            default: return "\(count) events today"
            }
        }()
        let focus = calendarModule.focusTimeToday
        let hours = Int(focus / 3600)
        let minutes = Int((focus.truncatingRemainder(dividingBy: 3600)) / 60)
        let focusStr: String
        if hours > 0 {
            focusStr = minutes > 0 ? "\(hours)h \(minutes)m focus" : "\(hours)h focus"
        } else if minutes > 0 {
            focusStr = "\(minutes)m focus"
        } else {
            focusStr = ""
        }
        return focusStr.isEmpty ? eventStr : "\(eventStr) · \(focusStr)"
    }

    private var focusTimeString: String {
        let hours = Int(calendarModule.focusTimeToday / 3600)
        let minutes = Int((calendarModule.focusTimeToday.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m focus" : "\(hours)h focus"
        }
        return "\(minutes)m focus"
    }

    // MARK: - Month Navigation

    private var monthNavigation: some View {
        HStack(spacing: 4) {
            // Month label — left-aligned (Dot style)
            Text(monthYearString)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.textPrimary)

            Spacer()

            // Chevron group — compact, right-aligned
            HStack(spacing: 0) {
                chevronButton(systemName: "chevron.left", delta: -1)
                chevronButton(systemName: "chevron.right", delta: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func chevronButton(systemName: String, delta: Int) -> some View {
        Button {
            withAnimation(ForgeTheme.Animation.panel) {
                calendarModule.selectedDate = calendar.date(
                    byAdding: .month, value: delta,
                    to: calendarModule.selectedDate
                )!
                calendarModule.loadEvents()
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.textMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Calendar Grid (Dot: 7 columns, 28px wide, 33px tall)

    private var calendarGrid: some View {
        let days = generateMonthDays()
        let weekNumbers = computeWeekNumbers(for: days)

        return VStack(spacing: 0) {
            // Day headers (with optional week-number column)
            HStack(spacing: 0) {
                if settings.showWeekNumbers {
                    Text("W")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.textFaint)
                        .frame(width: 22,
                               height: ForgeTheme.Layout.calendarDayHeaderHeight)
                }
                ForEach(Array(dayHeaders.enumerated()), id: \.offset) { index, day in
                    Text(day)
                        .font(ForgeTheme.Typography.calendarDayHeader)
                        .foregroundColor(
                            isWeekendColumn(index)
                                ? ForgeTheme.Colors.textFaint.opacity(0.6)
                                : ForgeTheme.Colors.textFaint
                        )
                        // Flex: 7 columns split the available width equally
                        // so the grid spans edge-to-edge in the popover.
                        .frame(maxWidth: .infinity,
                               minHeight: ForgeTheme.Layout.calendarDayHeaderHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 6 rows × 7 cells, with optional week-number prefix per row.
            // Tight spacing — matches Dot's reference (no visible row gaps).
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        if settings.showWeekNumbers {
                            Text("\(weekNumbers[row])")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(ForgeTheme.Colors.textFaint)
                                .frame(width: 22,
                                       height: ForgeTheme.Layout.calendarCellHeight)
                        }
                        ForEach(0..<7, id: \.self) { col in
                            let date = days[row * 7 + col]
                            dayCellView(date: date, columnIndex: col)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Defensive — the outer grid VStack must commit to the full
        // proposed width so its inner HStacks can distribute it across the
        // 7 day columns.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, ForgeTheme.Spacing.md)
        .scaleEffect(settings.calendarTextScale, anchor: .top)
    }

    /// Which display-column indices are weekend columns, given the configured week start.
    /// Weekend = the last two columns of the displayed week. Holds
    /// across both week-start preferences:
    ///   • Mon first → columns are [Mon..Sun] → weekend = Sat+Sun
    ///   • Sun first → columns are [Sun..Sat] → weekend = Fri+Sat
    ///     (South-Asia / Middle-East working week — Sun is a working
    ///     day, Fri+Sat are off.)
    private func isWeekendColumn(_ index: Int) -> Bool {
        index == 5 || index == 6
    }

    /// Compute the ISO week-of-year for each of the 6 grid rows.
    private func computeWeekNumbers(for days: [Date]) -> [Int] {
        var result: [Int] = []
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = settings.weekStartsOnMonday ? 2 : 1
        for row in 0..<6 {
            let date = days[row * 7]
            result.append(cal.component(.weekOfYear, from: date))
        }
        return result
    }

    // MARK: - Day Cell (Dot's exact styling)
    // Today: bg-[#1C1917] text-white rounded-full + alive-pulse animation
    // Selected: bg-[#F5F5F4] rounded-full
    // Other month: text-[#A8A29E]

    private func dayCellView(date: Date, columnIndex: Int) -> some View {
        let isToday = calendar.isDateInToday(date)
        let isCurrentMonth = calendar.isDate(date, equalTo: calendarModule.selectedDate, toGranularity: .month)
        let isSelected = calendar.isDate(date, inSameDayAs: calendarModule.selectedDate) && !isToday
        let isHovered = hoveredDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        let dayEvents = eventsForDate(date)
        let isWeekend = isWeekendColumn(columnIndex)
        // Today is always highlighted — the per-user toggle was
        // removed in favor of a sensible always-on default.
        let highlightThisToday = isToday

        // Plain VStack + onTapGesture — using `Button { } label: { }` with
        // `.buttonStyle(.plain)` was sizing the cell to its label's natural
        // content (~28pt fixed highlight square) regardless of any frame
        // modifier applied to the button itself, producing a 196pt-wide
        // grid that centered itself in the popover. Dropping the Button
        // lets the cell genuinely take 1/7 of the row.
        return VStack(spacing: 1) {
            ZStack {
                if highlightThisToday {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(ForgeTheme.Colors.accent)
                        .frame(width: ForgeTheme.Layout.todayCircleSize,
                               height: ForgeTheme.Layout.todayCircleSize)
                        .shadow(
                            color: ForgeTheme.Colors.accent.opacity(todayPulse ? 0.25 : 0),
                            radius: todayPulse ? 5 : 0
                        )
                } else if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(ForgeTheme.Colors.surfaceHover)
                        .frame(width: ForgeTheme.Layout.todayCircleSize,
                               height: ForgeTheme.Layout.todayCircleSize)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(ForgeTheme.Colors.hoverBg)
                        .frame(width: ForgeTheme.Layout.todayCircleSize,
                               height: ForgeTheme.Layout.todayCircleSize)
                }

                Text("\(calendar.component(.day, from: date))")
                    .font(ForgeTheme.Typography.calendarDay)
                    .foregroundColor(dayNumberColor(
                        isToday: highlightThisToday,
                        isCurrentMonth: isCurrentMonth,
                        isWeekend: isWeekend
                    ))
            }

            eventDots(for: dayEvents)
                .frame(height: ForgeTheme.Layout.eventIndicatorSize)
        }
        .frame(maxWidth: .infinity,
               minHeight: ForgeTheme.Layout.calendarCellHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredDate = hovering ? date : nil
        }
        .onTapGesture {
            withAnimation(ForgeTheme.Animation.micro) {
                calendarModule.selectedDate = date
            }
        }
        .contextMenu {
            // Right-click → create an event on this specific day.
            // Defaults to 9 AM (we don't know the user's intent down
            // to the minute; they can adjust in the quick-create input).
            Button {
                pendingCreateStart = CreateStart(date: defaultStart(on: date))
            } label: {
                Label("Create Event", systemImage: "plus.circle")
            }
        }
    }

    /// 9 AM on the given date (or the next round hour if the user
    /// right-clicked on today during business hours, so the suggested
    /// time isn't already in the past).
    private func defaultStart(on day: Date) -> Date {
        let cal = Calendar.current
        if cal.isDateInToday(day) {
            return defaultNewEventStart()
        }
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = 9
        comps.minute = 0
        return cal.date(from: comps) ?? day
    }

    private func dayNumberColor(isToday: Bool, isCurrentMonth: Bool, isWeekend: Bool) -> Color {
        if isToday { return .white }
        if !isCurrentMonth { return ForgeTheme.Colors.textMuted }
        if isWeekend { return ForgeTheme.Colors.textMuted }
        return ForgeTheme.Colors.textPrimary
    }

    /// Render the event-presence indicator for a day. Always uses
    /// the multi-dot style (up to 3 colored circles, one per
    /// distinct calendar) — the per-user "Event dots" picker used
    /// to let people downgrade to a single dot or no dot at all,
    /// but the multi-dot version conveys the most information
    /// without taking more pixels, so it's now the only mode.
    @ViewBuilder
    private func eventDots(for events: [CalendarEvent]) -> some View {
        HStack(spacing: 1.5) {
            ForEach(events.prefix(3), id: \.id) { event in
                Circle()
                    .fill(event.calendarColor)
                    .frame(width: ForgeTheme.Layout.eventIndicatorSize,
                           height: ForgeTheme.Layout.eventIndicatorSize)
            }
        }
    }

    // MARK: - Event List

    private var eventList: some View {
        let dayEvents = eventsForDate(calendarModule.selectedDate)
            .sorted { $0.startDate < $1.startDate }
        let headerText = calendar.isDateInToday(calendarModule.selectedDate)
            ? "TODAY"
            : selectedDayHeaderText

        return VStack(alignment: .leading, spacing: 0) {
            // Section header — Dot style: small caps with create button on the right
            HStack {
                Text(headerText)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(ForgeTheme.Colors.accent)

                Spacer()

                // "+ ⌘N" inline create button — opens NewEventSheet on the
                // currently selected date. Also bound to ⌘N globally while
                // the popover is key.
                Button(action: { pendingCreateStart = CreateStart(date: defaultNewEventStart()) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                        Text("⌘N")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(ForgeTheme.Colors.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.03)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .help("Create a new event (⌘N)")
            }
            .padding(.top, 10)
            .padding(.bottom, 4)

            if dayEvents.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 22))
                        .foregroundColor(ForgeTheme.Colors.textMuted.opacity(0.5))
                    Text("No events")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ForgeTheme.Colors.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 28)
            } else {
                VStack(spacing: 0) {
                    ForEach(dayEvents) { event in
                        eventRow(event)
                    }
                }
            }
        }
        .padding(.vertical, ForgeTheme.Spacing.sm)
    }

    private var selectedDayHeaderText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: calendarModule.selectedDate).uppercased()
    }

    // MARK: - Event Row (Dot's event item with colored sidebar)
    // Dot: 3px rounded sidebar indicator, 13px title, 11px time

    private func eventRow(_ event: CalendarEvent) -> some View {
        let now = Date()
        let isHappeningNow = now >= event.startDate && now < event.endDate
        let isUpcoming = event.startDate > now
        let timeLeft = relativeTimeBadge(for: event, now: now)

        return HStack(alignment: .top, spacing: 10) {
            // Colored sidebar — Dot: 3px wide rounded, slightly inset
            RoundedRectangle(cornerRadius: 1.5)
                .fill(event.calendarColor)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 3) {
                // Top row: time + optional "NOW"/"in Xm" pill + attendee count
                HStack(spacing: 7) {
                    Text(eventTimeString(event))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(ForgeTheme.Colors.textTertiary)

                    if let timeLeft = timeLeft {
                        Text(timeLeft)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(isHappeningNow ? .white : ForgeTheme.Colors.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    isHappeningNow
                                        ? ForgeTheme.Colors.accent
                                        : ForgeTheme.Colors.accent.opacity(0.12)
                                )
                            )
                    }

                    if event.attendeeCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 8))
                            Text("\(event.attendeeCount)")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(ForgeTheme.Colors.textMuted)
                    }
                }

                // Title — bigger, bolder, Dot style
                Text(event.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // Right-side action: Join button if meeting link + currently or soon
            if event.hasMeetingLink, isHappeningNow || isUpcoming {
                Button {
                    // Routes through MeetingLauncher.join() so the
                    // reminder banner gets the .meetingJoined signal
                    // and won't re-fire for this event.
                    MeetingLauncher.join(event)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Join")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(
                            isHappeningNow ? ForgeTheme.Colors.accent : Color(white: 0.18)
                        )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        // Tap an event row → show the floating detail card (NOT the
        // editor). The card's "Edit" button is the path to the
        // editor sheet. This matches the full-calendar's behavior.
        .onTapGesture {
            detailEvent = event
        }
        // Attach the detail popover to each row so it anchors next to
        // the event the user clicked.
        .popover(
            isPresented: Binding(
                get: { detailEvent?.id == event.id },
                set: { if !$0 { detailEvent = nil } }
            ),
            arrowEdge: .trailing
        ) {
            EventDetailCardPopover(
                event: event,
                onClose: { detailEvent = nil },
                onEdit: {
                    detailEvent = nil
                    if event.isGoogleEvent {
                        editingEvent = event
                    }
                }
            )
            .environmentObject(calendarModule)
        }
    }

    /// Returns "NOW", "Xm left", "in Xm", "in Xh Ym" — or nil if too far away
    private func relativeTimeBadge(for event: CalendarEvent, now: Date) -> String? {
        if now >= event.startDate && now < event.endDate {
            let remaining = event.endDate.timeIntervalSince(now)
            let mins = Int(remaining / 60)
            return mins < 60 ? "\(mins)m left" : "NOW"
        }
        if event.startDate > now {
            let toStart = event.startDate.timeIntervalSince(now)
            if toStart < 3600 {
                let mins = max(1, Int(toStart / 60))
                return "in \(mins)m"
            }
            if toStart < 86400 {
                let hours = Int(toStart / 3600)
                let mins = Int((toStart.truncatingRemainder(dividingBy: 3600)) / 60)
                return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h"
            }
        }
        return nil
    }

    // MARK: - World Clock Strip (Dot's sky strip at bottom)

    /// Visible state for the world clock manager popover. Opened by
    /// double-clicking the strip itself — no separate affordance, since
    /// the strip is the only thing it could possibly act on.
    @State private var worldClockManagerOpen: Bool = false
    /// Manual horizontal scroll offset for the strip. Driven by a
    /// `DragGesture` instead of a SwiftUI `ScrollView` — the latter
    /// swallows scroll-wheel events inside the NSPopover and breaks
    /// the parent's vertical scrolling (`MenuBarView` is wrapped in
    /// `ScrollableContainer`, an NSScrollView shim that only works
    /// when nothing above it captures wheel input).
    @State private var clockStripOffset: CGFloat = 0
    @State private var clockStripDragStart: CGFloat = 0
    @State private var clockStripContentWidth: CGFloat = 0
    @State private var clockStripVisibleWidth: CGFloat = 0

    private var worldClockStrip: some View {
        // Viewport: a `Color.clear` row that takes the full popover
        // width but no more. The HStack of cities is drawn as an
        // `.overlay` — overlays don't contribute to the parent's
        // layout, so the row stays exactly the popover width even
        // when the HStack inside is much wider. Anything past the
        // edge is clipped and revealed only by dragging.
        //
        // We avoid SwiftUI's `ScrollView` because it swallows scroll-
        // wheel events inside the NSPopover, which breaks the parent
        // vertical scroller (`MenuBarView` is hosted in
        // `ScrollableContainer`, an NSScrollView shim).
        Color.clear
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { clockStripVisibleWidth = geo.size.width }
                        .onChange(of: geo.size.width) { w in clockStripVisibleWidth = w }
                }
            )
            .overlay(alignment: .leading) {
                HStack(spacing: ForgeTheme.Spacing.lg) {
                    ForEach(settings.worldClockCities) { city in
                        worldClockItem(city: city.label, timeZone: city.timeZone)
                    }
                    if settings.worldClockCities.isEmpty {
                        Text("Double-click to add cities")
                            .font(.system(size: 10))
                            .foregroundColor(ForgeTheme.Colors.textMuted)
                    }
                }
                .padding(.horizontal, ForgeTheme.Spacing.sm)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { contentGeo in
                        Color.clear
                            .onAppear { clockStripContentWidth = contentGeo.size.width }
                            .onChange(of: contentGeo.size.width) { w in clockStripContentWidth = w }
                    }
                )
                .offset(x: clockStripOffset)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        // Clamp to [-(content - visible), 0] so the
                        // user can never drag past either edge. When
                        // everything fits, both bounds collapse to 0
                        // and the strip stays put.
                        let overflow = max(0, clockStripContentWidth - clockStripVisibleWidth)
                        let next = clockStripDragStart + value.translation.width
                        clockStripOffset = min(0, max(-overflow, next))
                    }
                    .onEnded { _ in
                        clockStripDragStart = clockStripOffset
                    }
            )
            .onTapGesture(count: 2) {
                worldClockManagerOpen = true
            }
            .help("Drag to see more · double-click to reorder")
            .padding(.top, ForgeTheme.Spacing.sm)
            .padding(.bottom, 2)
            .background(ForgeTheme.Colors.pageBgWarm)
            .popover(isPresented: $worldClockManagerOpen, arrowEdge: .top) {
                WorldClockManagerPopover()
                    .environmentObject(settings)
            }
    }

    private func worldClockItem(city: String, timeZone: TimeZone) -> some View {
        let hour = Calendar.current.dateComponents(in: timeZone, from: Date()).hour ?? 12
        let isDaytime = hour >= 6 && hour < 18

        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = settings.use24HourTime ? "HH:mm" : "h:mm"
        let timeString = formatter.string(from: Date())

        return HStack(spacing: 5) {
            // Day/night icon — Dot's amber sun / purple moon
            Image(systemName: isDaytime ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 10))
                .foregroundColor(isDaytime ? ForgeTheme.Colors.warning : ForgeTheme.Colors.accentPurple)

            Text(city)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(ForgeTheme.Colors.textMuted)

            Text(timeString)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
        }
    }

    // MARK: - Helpers

    private func generateMonthDays() -> [Date] {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: calendarModule.selectedDate))!

        // weekday: Sun=1 ... Sat=7
        let weekday = calendar.component(.weekday, from: monthStart)
        // How many days to back up so the grid's first column is the user's chosen "start of week".
        let leading: Int
        if settings.weekStartsOnMonday {
            leading = (weekday + 5) % 7   // Mon=0, Tue=1, …, Sun=6
        } else {
            leading = (weekday - 1) % 7   // Sun=0, Mon=1, …, Sat=6
        }

        let startDate = calendar.date(byAdding: .day, value: -leading, to: monthStart)!

        return (0..<42).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: startDate)
        }
    }

    // MARK: - Progress helpers

    private var yearProgress: Double {
        let now = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        guard
            let startOfYear = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
            let startOfNextYear = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))
        else { return 0 }
        let total = startOfNextYear.timeIntervalSince(startOfYear)
        let elapsed = now.timeIntervalSince(startOfYear)
        return min(1, max(0, elapsed / total))
    }

    private var dayProgress: Double {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let secondsSinceStart = now.timeIntervalSince(startOfDay)
        return min(1, max(0, secondsSinceStart / 86400.0))
    }

    private var daysLeftInYear: Int {
        let cal = Calendar.current
        let year = cal.component(.year, from: Date())
        guard let startOfNextYear = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return 0 }
        let comps = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: startOfNextYear)
        return comps.day ?? 0
    }

    private var currentYearString: String {
        "\(Calendar.current.component(.year, from: Date()))"
    }

    private var timeLeftInDayString: String {
        let cal = Calendar.current
        let now = Date()
        let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let seconds = endOfDay.timeIntervalSince(now)
        let hours = Int(seconds / 3600)
        let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(hours)h \(mins)m left"
    }

    private func eventsForDate(_ date: Date) -> [CalendarEvent] {
        // Read from `activeEvents` so declined meetings don't appear
        // in the menu-bar day list — same rule the ongoing/upcoming
        // tokens follow.
        calendarModule.activeEvents.filter { calendar.isDate($0.startDate, inSameDayAs: date) }
    }

    private func eventTimeString(_ event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: event.startDate)) – \(formatter.string(from: event.endDate))"
    }

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: calendarModule.selectedDate)
    }

    private var greetingString: String {
        let hour = calendar.component(.hour, from: Date())
        let greeting: String
        switch hour {
        case 5..<12: greeting = "Good morning"
        case 12..<17: greeting = "Good afternoon"
        default: greeting = "Good evening"
        }

        let eventCount = calendarModule.todayEvents.count
        let focusHours = Int(calendarModule.focusTimeToday / 3600)
        return "\(greeting). \(eventCount) events today, \(focusHours)h focus time."
    }
}

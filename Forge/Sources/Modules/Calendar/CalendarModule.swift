import SwiftUI
import EventKit

/// Calendar module — Forge's home screen.
/// Reads from EventKit (iCloud, Google, Outlook, Exchange via macOS Internet Accounts).
/// Provides month grid, event list, meeting join, world clock.
final class CalendarModule: ForgeModule, ObservableObject {
    let id = "calendar"
    let name = "Calendar"
    let description = "Menu bar calendar with meetings"
    let iconName = "calendar"
    let category: ModuleCategory = .calendar
    var isEnabled: Bool = true

    // MARK: - State

    @Published var selectedDate: Date = Date()
    @Published var events: [CalendarEvent] = []
    @Published var calendars: [EKCalendar] = []
    @Published var hiddenCalendarIds: Set<String> = []

    private let eventStore = EKEventStore()
    private var updateTimer: Timer?

    // MARK: - Computed

    /// `events` minus anything the current user has declined. This is
    /// the list every "what's coming up" view should iterate — if the
    /// user said "no" to a meeting, it shouldn't show in their
    /// menu-bar countdown, ongoing slot, or upcoming list. Events
    /// the user is the organizer of (or that came from EventKit
    /// without an RSVP) keep `myResponseStatus == nil` and pass
    /// through unaffected.
    var activeEvents: [CalendarEvent] {
        let nonDeclined = events.filter { $0.myResponseStatus != "declined" }

        // Collect Out of Office blocks. Any non-OOO event whose time
        // range overlaps with an OOO block is suppressed — the user
        // has said "I'm away", so those meetings are irrelevant.
        let oooBlocks = nonDeclined.filter { $0.eventType == "outOfOffice" }
        guard !oooBlocks.isEmpty else { return nonDeclined }

        return nonDeclined.filter { event in
            // Keep OOO events themselves visible (so the user sees
            // their OOO status in the calendar / menu bar).
            if event.eventType == "outOfOffice" { return true }
            // Drop any event that overlaps with an OOO block.
            let dominated = oooBlocks.contains { ooo in
                event.startDate < ooo.endDate && ooo.startDate < event.endDate
            }
            return !dominated
        }
    }

    var nextEvent: CalendarEvent? {
        let now = Date()
        return activeEvents
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    /// The event currently happening RIGHT NOW (start ≤ now < end).
    /// Used by the menu-bar's `ongoingMeeting` token. If multiple
    /// events overlap, picks the one that started most recently —
    /// that's almost always the meeting the user is paying attention
    /// to (a long all-day "Working Day" loses to a 9:00 Standup).
    var ongoingEvent: CalendarEvent? {
        let now = Date()
        return activeEvents
            .filter { $0.startDate <= now && $0.endDate > now && !$0.isAllDay }
            .sorted { $0.startDate > $1.startDate }
            .first
    }

    var todayEvents: [CalendarEvent] {
        let calendar = Calendar.current
        return activeEvents.filter { calendar.isDateInToday($0.startDate) }
    }

    var focusTimeToday: TimeInterval {
        let calendar = Calendar.current
        let now = Date()
        let endOfDay = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
        let todayMeetings = todayEvents
            .filter { $0.startDate >= now && $0.startDate < endOfDay }
            .sorted { $0.startDate < $1.startDate }

        var focusTime: TimeInterval = 0
        var lastEnd = now

        for event in todayMeetings {
            let gap = event.startDate.timeIntervalSince(lastEnd)
            if gap >= 2700 { // 45 min minimum gap = focus time
                focusTime += gap
            }
            lastEnd = max(lastEnd, event.endDate)
        }

        // Add remaining time after last meeting
        let remaining = endOfDay.timeIntervalSince(lastEnd)
        if remaining >= 2700 {
            focusTime += remaining
        }

        return focusTime
    }

    // MARK: - Lifecycle

    func activate() {
        requestCalendarAccess()
        startUpdateTimer()
        // Event-driven refresh: macOS posts `.EKEventStoreChanged`
        // whenever the underlying calendar database mutates (an edit in
        // Calendar.app, a new invite syncing in via iCloud/Exchange).
        // Observing it means native-calendar changes appear instantly
        // instead of waiting up to a full poll interval. The timer below
        // is now only really needed for the Google network path (which
        // has no local change notification).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreChanged),
            name: .EKEventStoreChanged,
            object: eventStore
        )
    }

    func deactivate() {
        updateTimer?.invalidate()
        updateTimer = nil
        NotificationCenter.default.removeObserver(
            self, name: .EKEventStoreChanged, object: eventStore
        )
    }

    @objc private func eventStoreChanged() {
        // Coalesce: the system can fire this several times in a burst
        // during a sync. The reload itself is now off-main + cheap to
        // re-enter, but hop to main first since we touch @Published state.
        DispatchQueue.main.async { [weak self] in
            self?.loadCalendars()
            self?.loadEvents()
        }
    }

    // MARK: - Calendar Access

    private func requestCalendarAccess() {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                if granted {
                    DispatchQueue.main.async {
                        self?.loadCalendars()
                        self?.loadEvents()
                    }
                } else {
                    print("[Forge Calendar] Access denied: \(error?.localizedDescription ?? "unknown")")
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] granted, error in
                if granted {
                    DispatchQueue.main.async {
                        self?.loadCalendars()
                        self?.loadEvents()
                    }
                }
            }
        }
    }

    private func loadCalendars() {
        calendars = eventStore.calendars(for: .event)
    }

    func loadEvents() {
        let calendar = Calendar.current
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate))!
        let endOfMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth)!

        // Extend range to include adjacent months for grid display
        let startDate = calendar.date(byAdding: .weekOfYear, value: -1, to: startOfMonth)!
        let endDate = calendar.date(byAdding: .weekOfYear, value: 1, to: endOfMonth)!

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars.filter { !hiddenCalendarIds.contains($0.calendarIdentifier) }
        )

        // `events(matching:)` walks the calendar database and can take
        // 100–500ms on a busy account — far too long for the main
        // thread, where it would stall the popover/menu every refresh.
        // Run the query AND the EKEvent→CalendarEvent mapping on a
        // background queue so every EKEvent property read happens off
        // the same thread that fetched them (EKEvent is not thread-safe;
        // we never let one cross threads — only the value-type
        // CalendarEvent results and the extracted id Set do).
        let store = eventStore
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ekRaw = store.events(matching: predicate)
            let ekEvents = ekRaw.map { CalendarEvent(from: $0) }
            let ekExternalIds = Set(ekRaw.compactMap { $0.calendarItemExternalIdentifier })

            DispatchQueue.main.async {
                guard let self = self else { return }
                // Show EventKit events immediately, then merge in native
                // Google events when they arrive (dedupe by iCalUID —
                // Google events also present in macOS Calendar would
                // otherwise show twice).
                self.events = ekEvents

                Task { [weak self] in
                    let google = await GoogleCalendarService.shared.fetchAllEvents(
                        from: startDate, to: endDate
                    )
                    await MainActor.run {
                        guard let self = self else { return }
                        let uniqueGoogle = google.filter { event in
                            // event.id is "google:<eventId>"; Google's iCalUID
                            // equals EKEvent.calendarItemExternalIdentifier when
                            // the same account is also wired through macOS Calendar.
                            !ekExternalIds.contains(String(event.id.dropFirst("google:".count)))
                        }
                        self.events = ekEvents + uniqueGoogle

                        // Rebuild the contacts directory from the merged
                        // event list — used by attendee autocomplete in
                        // the event editor. Cheap: in-memory dedupe on email.
                        let myEmails = Set(
                            GoogleCalendarService.shared.accounts.map(\.email)
                        )
                        ContactsDirectory.shared.rebuild(from: self.events, myEmails: myEmails)
                    }
                }
            }
        }
    }

    // MARK: - Meeting Join

    func joinNextMeeting() {
        guard let next = nextEvent, next.meetingURL != nil else {
            print("[Forge Calendar] No upcoming meeting with a join link.")
            return
        }
        // Routes through `MeetingLauncher.join` (not `.open`) so the
        // reminder banner picks up the `.meetingJoined` signal and
        // stops nagging about this event.
        MeetingLauncher.join(next)
    }

    // MARK: - Timer

    private func startUpdateTimer() {
        // Now that native-calendar changes are event-driven (via
        // .EKEventStoreChanged), this timer's only real job is to pull
        // fresh Google data over the network, which has no local change
        // signal. 15s cadence keeps the menu bar snappy — edits made in
        // Google Calendar (web or mobile) show up within seconds instead
        // of waiting a full minute.
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.loadEvents()
        }
        timer.tolerance = 3
        updateTimer = timer
    }

    // MARK: - Module Protocol

    func menuBarView() -> AnyView {
        AnyView(
            CalendarView()
                .environmentObject(self)
        )
    }

}

// MARK: - Calendar Event Model

/// A file/link attached to a calendar event — typically Google Drive,
/// Notion, Figma, GitHub etc. Surfaced in the meeting reminder so the
/// user can click straight into prep material instead of digging through
/// the event description.
struct EventAttachment: Equatable, Identifiable {
    var id: String { fileURL.absoluteString }
    let title: String
    let fileURL: URL
    let mimeType: String?
    /// Small icon hosted by Google (favicon-like). When nil we fall back
    /// to an SF Symbol chosen from `mimeType`.
    let iconURL: URL?
}

/// One person invited to a calendar event. We keep the response status
/// so the UI can show accepted / declined / tentative pips next to
/// each name.
struct EventAttendee: Equatable, Identifiable {
    var id: String { email.lowercased() }
    let email: String
    let displayName: String?
    /// "accepted", "tentative", "declined", "needsAction", or nil.
    let responseStatus: String?
    /// True for the event organizer — usually drawn with a different
    /// chip color so the user can tell at a glance.
    let isOrganizer: Bool
}

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarColor: Color
    let calendarTitle: String
    let location: String?
    let notes: String?
    let meetingURL: URL?
    let attendeeCount: Int
    /// Drive / Notion / Figma / etc. files attached to the event via
    /// Google Calendar's `attachments` field.
    let attachments: [EventAttachment]

    /// Full attendees list (Google events only). Each entry has the
    /// person's email, optional display name, and current RSVP status.
    let attendees: [EventAttendee]

    /// Per-event override reminders (minutes before event start, popup
    /// notification only). Empty array ⇒ event uses calendar default.
    let remindersMinutes: [Int]

    /// Routing info for Google-sourced events so we can edit / delete via
    /// the Google Calendar v3 REST API. Nil for EventKit-only events.
    let googleRouting: GoogleRouting?

    /// Current user's response to this event ("accepted", "tentative",
    /// "declined", "needsAction"). Nil = the user isn't an attendee
    /// (they own the event, or it's an EventKit event without RSVP).
    let myResponseStatus: String?

    /// How many attendees have actually accepted (responseStatus =
    /// "accepted"). Used in the meeting reminder to show "👥 N".
    let confirmedAttendeeCount: Int

    /// Google Calendar event type — "default", "outOfOffice",
    /// "focusTime", "workingLocation", etc. Nil for EventKit events.
    /// Used to detect Out of Office blocks and suppress other events
    /// that overlap with them.
    let eventType: String?

    struct GoogleRouting: Equatable {
        let accountEmail: String   // OAuth account that owns this calendar
        let calendarId: String     // e.g. "primary" or the calendar's email
        let eventId: String        // the bare event id (without "google:" prefix)
    }

    /// True for events that came from a connected Google account and can be
    /// round-tripped to Google's API.
    var isGoogleEvent: Bool { googleRouting != nil }

    /// True when the current user is one of the attendees (vs. the
    /// organizer). RSVP affordances only make sense for invited events.
    var isInvited: Bool { myResponseStatus != nil }

    init(from ekEvent: EKEvent) {
        self.id = ekEvent.eventIdentifier
        self.title = ekEvent.title ?? "Untitled"
        self.startDate = ekEvent.startDate
        self.endDate = ekEvent.endDate
        self.isAllDay = ekEvent.isAllDay
        self.calendarColor = Color(cgColor: ekEvent.calendar.cgColor)
        self.calendarTitle = ekEvent.calendar.title
        self.location = ekEvent.location
        self.notes = ekEvent.notes
        self.attendeeCount = ekEvent.attendees?.count ?? 0
        self.confirmedAttendeeCount = ekEvent.attendees?.filter {
            $0.participantStatus == .accepted
        }.count ?? 0

        // Extract meeting URL from notes/location/URL
        self.meetingURL = CalendarEvent.extractMeetingURL(from: ekEvent)
        // EventKit events route through EventKit, not the Google API.
        self.googleRouting = nil
        // EventKit doesn't expose "my" status as a string cleanly here;
        // leave nil so the UI doesn't show RSVP affordances for EK events.
        self.myResponseStatus = nil
        // EventKit events don't have structured attachments — left empty.
        self.attachments = []
        // EventKit attendees and reminders aren't surfaced for editing
        // through Forge; we only round-trip Google events here.
        self.attendees = []
        self.remindersMinutes = []
        // EventKit doesn't surface Google's eventType field.
        self.eventType = nil
    }

    // Preview/mock initializer
    init(
        id: String = UUID().uuidString,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        calendarColor: Color = ForgeTheme.Colors.accentBlue,
        calendarTitle: String = "Calendar",
        location: String? = nil,
        notes: String? = nil,
        meetingURL: URL? = nil,
        attendeeCount: Int = 0,
        googleRouting: GoogleRouting? = nil,
        myResponseStatus: String? = nil,
        confirmedAttendeeCount: Int = 0,
        attachments: [EventAttachment] = [],
        attendees: [EventAttendee] = [],
        remindersMinutes: [Int] = [],
        eventType: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.calendarColor = calendarColor
        self.calendarTitle = calendarTitle
        self.location = location
        self.notes = notes
        self.meetingURL = meetingURL
        self.attendeeCount = attendeeCount
        self.googleRouting = googleRouting
        self.myResponseStatus = myResponseStatus
        self.confirmedAttendeeCount = confirmedAttendeeCount
        self.attachments = attachments
        self.attendees = attendees
        self.remindersMinutes = remindersMinutes
        self.eventType = eventType
    }

    /// True when this is a Google Calendar "Out of Office" event.
    var isOutOfOffice: Bool { eventType == "outOfOffice" }

    var hasMeetingLink: Bool { meetingURL != nil }

    var meetingService: String? {
        guard let url = meetingURL else { return nil }
        return MeetingLauncher.service(for: url) ?? "Video"
    }

    // MARK: - URL Extraction

    /// Substring fingerprints we accept as "this is a meeting URL".
    /// Ordered roughly by frequency — first match wins. Each Zoom /
    /// Teams / Webex pattern covers the common URL shapes those
    /// services actually mint (personal rooms, signed-in attendees,
    /// web-client redirects, etc.).
    private static let meetingPatterns: [String] = [
        // Zoom
        "zoom.us/j/",           // standard join
        "zoom.us/s/",           // signed-in attendee
        "zoom.us/my/",          // personal room
        "zoom.us/wc/join/",     // web client
        // Google Meet
        "meet.google.com/",
        // Microsoft Teams
        "teams.microsoft.com/l/meetup-join",
        "teams.microsoft.com/l/meeting",
        "teams.live.com/meet/",
        // Cisco Webex
        "webex.com/meet/",
        "webex.com/webappng/sites/",
        "webex.com/wbxmjs/joinservice",
        // Independents
        "whereby.com/",
        "around.co/",
        "tuple.app/",
    ]

    static func extractMeetingURL(from event: EKEvent) -> URL? {
        let sources = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }

        // Escape the pattern so regex meta-characters in our pattern
        // table (none today, but futureproof) don't break the search.
        for source in sources {
            for pattern in meetingPatterns {
                let escaped = NSRegularExpression.escapedPattern(for: pattern)
                if source.contains(pattern),
                   let range = source.range(
                       of: "https?://\\S*\(escaped)\\S*",
                       options: .regularExpression
                   ),
                   let url = URL(string: String(source[range])) {
                    return url
                }
            }
        }

        return event.url
    }
}

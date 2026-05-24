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

    var nextEvent: CalendarEvent? {
        let now = Date()
        return events
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    var todayEvents: [CalendarEvent] {
        let calendar = Calendar.current
        return events.filter { calendar.isDateInToday($0.startDate) }
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
    }

    func deactivate() {
        updateTimer?.invalidate()
        updateTimer = nil
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

        let ekRaw = eventStore.events(matching: predicate)
        let ekEvents = ekRaw.map { CalendarEvent(from: $0) }

        // Show EventKit events immediately, then merge in native Google events
        // when they arrive (dedupe by iCalUID — Google events that are ALSO in
        // macOS Calendar would otherwise show twice).
        self.events = ekEvents

        Task { [weak self] in
            let google = await GoogleCalendarService.shared.fetchAllEvents(
                from: startDate, to: endDate
            )
            await MainActor.run {
                guard let self = self else { return }
                // Build a set of EKEvent external identifiers (iCalUIDs) to dedupe.
                let ekExternalIds = Set(ekRaw.compactMap { $0.calendarItemExternalIdentifier })
                let uniqueGoogle = google.filter { event in
                    // event.id is "google:<eventId>" — strip prefix for matching
                    // Google's `iCalUID` equals EKEvent.calendarItemExternalIdentifier
                    // when the same account is also wired through macOS Calendar.
                    !ekExternalIds.contains(String(event.id.dropFirst("google:".count)))
                }
                self.events = ekEvents + uniqueGoogle
            }
        }
    }

    // MARK: - Meeting Join

    func joinNextMeeting() {
        guard let next = nextEvent, let url = next.meetingURL else {
            print("[Forge Calendar] No upcoming meeting with a join link.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Timer

    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.loadEvents()
        }
    }

    // MARK: - Module Protocol

    func menuBarView() -> AnyView {
        AnyView(
            CalendarView()
                .environmentObject(self)
        )
    }

    func commands() -> [ForgeCommand] {
        [
            ForgeCommand(
                id: "calendar.new",
                title: "New Event",
                subtitle: "Create a calendar event",
                iconName: "plus.circle",
                moduleId: id,
                action: { /* Open event creation */ },
                keywords: ["new", "event", "create", "calendar", "meeting"]
            ),
            ForgeCommand(
                id: "calendar.today",
                title: "Go to Today",
                subtitle: "Jump to today's date",
                iconName: "calendar.circle",
                moduleId: id,
                action: { [weak self] in self?.selectedDate = Date() },
                keywords: ["today", "now", "current"]
            ),
            ForgeCommand(
                id: "calendar.join",
                title: "Join Next Meeting",
                subtitle: nextEvent?.title ?? "No upcoming meeting",
                iconName: "video",
                moduleId: id,
                action: { [weak self] in self?.joinNextMeeting() },
                keywords: ["join", "meeting", "zoom", "meet", "teams"]
            )
        ]
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
        attachments: [EventAttachment] = []
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
    }

    var hasMeetingLink: Bool { meetingURL != nil }

    var meetingService: String? {
        guard let url = meetingURL?.absoluteString.lowercased() else { return nil }
        if url.contains("zoom.us") { return "Zoom" }
        if url.contains("meet.google") { return "Meet" }
        if url.contains("teams.microsoft") { return "Teams" }
        if url.contains("webex") { return "Webex" }
        return "Video"
    }

    // MARK: - URL Extraction

    private static let meetingPatterns = [
        "zoom.us/j/",
        "meet.google.com/",
        "teams.microsoft.com/l/meetup-join",
        "webex.com/meet/",
        "whereby.com/",
        "around.co/",
        "tuple.app/"
    ]

    static func extractMeetingURL(from event: EKEvent) -> URL? {
        let sources = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }

        for source in sources {
            for pattern in meetingPatterns {
                if source.contains(pattern),
                   let range = source.range(of: "https?://\\S+\(pattern)\\S*", options: .regularExpression),
                   let url = URL(string: String(source[range])) {
                    return url
                }
            }
        }

        return event.url
    }
}

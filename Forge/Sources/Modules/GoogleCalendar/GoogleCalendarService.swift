import Foundation
import SwiftUI
import AppKit
import AuthenticationServices
import CryptoKit
import Combine
import Network

// MARK: - Public Models

struct GoogleAccount: Identifiable, Codable, Equatable {
    /// The Google account email is the natural ID.
    var id: String { email }
    let email: String
    let name: String?
    let connectedAt: Date
    /// User-chosen color for every event from this account. Hex like "#0A84FF".
    var colorHex: String

    init(email: String, name: String?, connectedAt: Date, colorHex: String) {
        self.email = email
        self.name = name
        self.connectedAt = connectedAt
        self.colorHex = colorHex
    }

    // Back-compat decode — older saved accounts had no colorHex.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email       = try c.decode(String.self, forKey: .email)
        name        = try c.decodeIfPresent(String.self, forKey: .name)
        connectedAt = try c.decode(Date.self, forKey: .connectedAt)
        colorHex    = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#0A84FF"
    }
}

/// Set while a freshly-OAuth'd account is waiting for the user to pick a color.
struct PendingGoogleAccount: Identifiable, Equatable {
    var id: String { email }
    let email: String
    let name: String?
    let suggestedColor: String
}

// MARK: - Errors

enum GoogleAuthError: LocalizedError {
    case missingClientID
    case userCancelled
    case badCallback(String)
    case tokenExchange(String)
    case userInfo(String)
    case network(String)
    var errorDescription: String? {
        switch self {
        case .missingClientID:  return "Google Client ID isn't set — paste it in Settings → Calendar → Linked Calendars."
        case .userCancelled:    return "Sign-in was cancelled."
        case .badCallback(let s): return "Unexpected OAuth callback: \(s)"
        case .tokenExchange(let s): return "Token exchange failed: \(s)"
        case .userInfo(let s):  return "Couldn't fetch Google profile: \(s)"
        case .network(let s):   return s
        }
    }
}

// MARK: - Service

/// Native Google Calendar integration entrypoint.
/// Phase 1A (this turn): OAuth flow + Keychain token storage + connected
/// account list. API calls (list calendars / events) come in Phase 1B.
final class GoogleCalendarService: NSObject, ObservableObject {

    static let shared = GoogleCalendarService()

    /// Connected accounts (persisted in UserDefaults, no tokens here).
    @Published private(set) var accounts: [GoogleAccount] = []
    @Published var lastError: String?
    /// Set after OAuth succeeds — UI watches this and presents a color picker.
    @Published var pendingAccount: PendingGoogleAccount?

    // OAuth constants
    private let scope = "openid email profile https://www.googleapis.com/auth/calendar"
    private let authorizeURL  = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL      = "https://oauth2.googleapis.com/token"
    private let revokeURL     = "https://oauth2.googleapis.com/revoke"
    private let userinfoURL   = "https://openidconnect.googleapis.com/v1/userinfo"
    // Loopback redirect — Google's recommended flow for desktop apps.
    // Port is assigned per-attempt; we register the URI per-attempt with the OS,
    // so no URI registration in Google Cloud Console is needed.
    private var currentRedirectURI: String = ""

    /// Forge's bundled Google OAuth client ID. PKCE means it's safe to ship in
    /// the binary — it's not a secret. Users never see this; they just sign
    /// into their own Google account through the standard consent screen.
    /// Value lives in the gitignored Secrets.swift (see Secrets.swift.example).
    static let defaultClientID = Secrets.googleOAuthClientID
    /// Google requires the client_secret even for "installed" desktop clients
    /// using PKCE. Not actually secret — published in every desktop app's binary.
    /// Value lives in the gitignored Secrets.swift (see Secrets.swift.example).
    static let defaultClientSecret = Secrets.googleOAuthClientSecret

    /// Returns the user's override if set, otherwise the bundled default.
    /// 99% of users will never set the override.
    var clientID: String {
        get {
            let override = UserDefaults.standard.string(forKey: "google.clientID") ?? ""
            return override.isEmpty ? Self.defaultClientID : override
        }
        set {
            // Empty string clears the override (falls back to default).
            UserDefaults.standard.set(newValue, forKey: "google.clientID")
            objectWillChange.send()
        }
    }

    /// True when the user has explicitly overridden the bundled client ID.
    var hasCustomClientID: Bool {
        let override = UserDefaults.standard.string(forKey: "google.clientID") ?? ""
        return !override.isEmpty
    }

    private let accountsKey = "google.accounts"
    private var loopback: LoopbackOAuthServer?

    private override init() {
        super.init()
        loadAccounts()
    }

    // MARK: - Account persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let list = try? JSONDecoder().decode([GoogleAccount].self, from: data)
        else { return }
        self.accounts = list
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: accountsKey)
    }

    // MARK: - Public API

    /// Start the OAuth flow using Google's recommended **loopback** redirect
    /// for desktop apps. We spin up a local HTTP listener on an ephemeral port,
    /// open the user's default browser to Google, and catch the callback when
    /// Google redirects to http://127.0.0.1:PORT.
    func connect() {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            lastError = GoogleAuthError.missingClientID.localizedDescription
            return
        }

        // PKCE
        let codeVerifier  = Self.randomURLSafeString(length: 64)
        let codeChallenge = Self.sha256URLSafe(codeVerifier)
        let state         = Self.randomURLSafeString(length: 32)

        // Start loopback listener first so we know the port before opening browser
        let server = LoopbackOAuthServer()
        do {
            try server.start()
        } catch {
            lastError = "Couldn't open local OAuth listener: \(error.localizedDescription)"
            return
        }

        // Use `localhost` to exactly match the redirect_uris in the OAuth client
        // JSON config; the OS resolves localhost → 127.0.0.1 so our NWListener
        // (loopback) still receives the request.
        currentRedirectURI = "http://localhost:\(server.port)"
        loopback = server

        server.onResult = { [weak self] result in
            // Force everything onto main — @Published mutations must originate here.
            DispatchQueue.main.async {
                guard let self = self else { return }
                server.stop()
                self.loopback = nil

                switch result {
                case .success(let params):
                    if let err = params["error"] {
                        self.lastError = GoogleAuthError.badCallback(err).localizedDescription
                        return
                    }
                    guard params["state"] == state else {
                        self.lastError = GoogleAuthError.badCallback("state mismatch").localizedDescription
                        return
                    }
                    guard let code = params["code"] else {
                        self.lastError = GoogleAuthError.badCallback("no code").localizedDescription
                        return
                    }
                    Task { await self.exchange(code: code, codeVerifier: codeVerifier) }
                case .failure(let err):
                    self.lastError = err.localizedDescription
                }
            }
        }

        // Build Google auth URL with the loopback redirect URI
        var comps = URLComponents(string: authorizeURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "redirect_uri", value: currentRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]
        guard let url = comps.url else {
            lastError = "Failed to build OAuth URL"
            server.stop()
            loopback = nil
            return
        }

        // Open in the user's default browser
        NSWorkspace.shared.open(url)
    }

    func disconnect(email: String) {
        // Revoke the refresh token if we have it, then drop locally.
        if let refresh = GoogleKeychain.refreshToken(for: email) {
            Task { try? await revoke(token: refresh) }
        }
        GoogleKeychain.delete(for: email)
        accounts.removeAll { $0.email == email }
        saveAccounts()
    }

    // MARK: - Calendar API (Phase 1B)

    /// Fetches all events from every calendar the user has, between two dates,
    /// for every connected Google account. Returns Forge's `CalendarEvent`s.
    func fetchAllEvents(from start: Date, to end: Date) async -> [CalendarEvent] {
        var out: [CalendarEvent] = []
        for account in accounts {
            do {
                let events = try await fetchEvents(for: account, from: start, to: end)
                out.append(contentsOf: events)
            } catch {
                print("[Forge Google] fetch failed for \(account.email): \(error)")
            }
        }
        return out
    }

    private func fetchEvents(for account: GoogleAccount, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let token = try await validAccessToken(for: account.email)
        let cals = try await listCalendars(token: token)

        var all: [CalendarEvent] = []
        let accentColor = NSColor(SwiftUI.Color(hex: account.colorHex))

        for cal in cals where cal.selected != false {
            let dtos = try await listEvents(
                calendarId: cal.id,
                token: token,
                from: start, to: end
            )
            for dto in dtos {
                if let event = dto.toCalendarEvent(
                    accountColor: accentColor,
                    calendarTitle: cal.summary,
                    accountEmail: account.email,
                    calendarId: cal.id
                ) {
                    all.append(event)
                }
            }
        }
        return all
    }

    // MARK: API request models

    private struct CalendarListItem: Decodable {
        let id: String
        let summary: String
        let primary: Bool?
        let selected: Bool?
        let backgroundColor: String?
    }

    private struct CalendarListResponse: Decodable {
        let items: [CalendarListItem]
    }

    private struct EventDTO: Decodable {
        let id: String
        let iCalUID: String?
        let summary: String?
        let description: String?
        let location: String?
        let htmlLink: String?
        let start: TimeRef
        let end: TimeRef
        let attendees: [Attendee]?
        let hangoutLink: String?
        let conferenceData: ConferenceData?
        let attachments: [Attachment]?
        let reminders: Reminders?
        let status: String?

        struct TimeRef: Decodable {
            let dateTime: String?   // ISO 8601 with TZ
            let date: String?       // "YYYY-MM-DD" all-day
            let timeZone: String?
        }
        struct Attendee: Decodable {
            let email: String?
            let displayName: String?
            let responseStatus: String?
            let organizer: Bool?
        }
        struct ConferenceData: Decodable {
            let entryPoints: [EntryPoint]?
            struct EntryPoint: Decodable {
                let entryPointType: String?
                let uri: String?
            }
        }
        struct Attachment: Decodable {
            let fileUrl: String?
            let title: String?
            let mimeType: String?
            let iconLink: String?
            let fileId: String?
        }
        /// Google's `reminders` object — either uses the calendar default
        /// or carries an `overrides` array with per-event popup/email
        /// reminders. We surface popup reminders only.
        struct Reminders: Decodable {
            let useDefault: Bool?
            let overrides: [Override]?
            struct Override: Decodable {
                let method: String?    // "popup" | "email"
                let minutes: Int?
            }
        }

        func toCalendarEvent(
            accountColor: NSColor,
            calendarTitle: String,
            accountEmail: String,
            calendarId: String
        ) -> CalendarEvent? {
            guard status != "cancelled" else { return nil }
            guard let title = summary else { return nil }

            let isAllDay = (start.dateTime == nil && start.date != nil)

            guard
                let s = Self.parseDate(timeStr: start.dateTime, dateStr: start.date),
                let e = Self.parseDate(timeStr: end.dateTime, dateStr: end.date)
            else { return nil }

            // Pull a meeting URL: Google Meet (hangoutLink) > conferenceData > location
            let meetingURL = URL(string: hangoutLink ?? "")
                ?? conferenceData?.entryPoints?
                    .first(where: { $0.entryPointType == "video" })?
                    .uri.flatMap { URL(string: $0) }

            // RSVP info: if the authenticated account is in the attendees
            // list, expose their status so the UI can show RSVP controls.
            let myAttendee = attendees?.first { $0.email == accountEmail }
            let confirmed = attendees?.filter { $0.responseStatus == "accepted" }.count ?? 0

            // Attachments — Google Drive / Notion / Figma / GitHub links
            // attached to the event. We keep only ones with a usable URL.
            let mappedAttachments: [EventAttachment] = (attachments ?? []).compactMap { att in
                guard
                    let urlStr = att.fileUrl,
                    let url = URL(string: urlStr)
                else { return nil }
                return EventAttachment(
                    title: att.title ?? url.lastPathComponent,
                    fileURL: url,
                    mimeType: att.mimeType,
                    iconURL: att.iconLink.flatMap { URL(string: $0) }
                )
            }

            // Full attendees list — used by the event editor to show
            // chips and let the organizer edit invites.
            let mappedAttendees: [EventAttendee] = (attendees ?? []).compactMap { a in
                guard let email = a.email, !email.isEmpty else { return nil }
                return EventAttendee(
                    email: email,
                    displayName: a.displayName,
                    responseStatus: a.responseStatus,
                    isOrganizer: a.organizer ?? false
                )
            }

            // Per-event popup reminders (minutes-before). Email
            // reminders aren't surfaced — popup is the only kind Forge
            // can mirror locally.
            let popupReminders: [Int] = (reminders?.overrides ?? [])
                .filter { ($0.method ?? "popup") == "popup" }
                .compactMap { $0.minutes }

            return CalendarEvent(
                id: "google:\(id)",
                title: title,
                startDate: s,
                endDate: e,
                isAllDay: isAllDay,
                calendarColor: Color(accountColor),
                calendarTitle: calendarTitle,
                location: location,
                notes: description,
                meetingURL: meetingURL,
                attendeeCount: attendees?.count ?? 0,
                googleRouting: .init(
                    accountEmail: accountEmail,
                    calendarId: calendarId,
                    eventId: id
                ),
                myResponseStatus: myAttendee?.responseStatus,
                confirmedAttendeeCount: confirmed,
                attachments: mappedAttachments,
                attendees: mappedAttendees,
                remindersMinutes: popupReminders
            )
        }

        private static func parseDate(timeStr: String?, dateStr: String?) -> Date? {
            if let t = timeStr {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = f.date(from: t) { return d }
                f.formatOptions = [.withInternetDateTime]
                return f.date(from: t)
            }
            if let d = dateStr {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.timeZone = TimeZone(identifier: "UTC")
                return f.date(from: d)
            }
            return nil
        }
    }

    private struct EventsResponse: Decodable {
        let items: [EventDTO]
        let nextPageToken: String?
    }

    // MARK: API calls

    private func listCalendars(token: String) async throws -> [CalendarListItem] {
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.assertOK(resp, data: data)
        return try JSONDecoder().decode(CalendarListResponse.self, from: data).items
    }

    private func listEvents(calendarId: String,
                            token: String,
                            from start: Date,
                            to end: Date) async throws -> [EventDTO] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        var comps = URLComponents(string:
            "https://www.googleapis.com/calendar/v3/calendars/\(calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId)/events")!
        comps.queryItems = [
            URLQueryItem(name: "timeMin", value: f.string(from: start)),
            URLQueryItem(name: "timeMax", value: f.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "250"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.assertOK(resp, data: data)
        return try JSONDecoder().decode(EventsResponse.self, from: data).items
    }

    // MARK: - Write API (create event)

    /// Create an event on the user's primary Google calendar.
    /// Result of a create/update — exposes the Google event id so the
    /// caller can immediately re-fetch / route subsequent edits. When the
    /// caller asks for a Google Meet via `generateMeet: true`, the
    /// resolved `meetingURL` is also populated so the UI can show or copy
    /// it without an extra fetch.
    struct EventMutationResult {
        let eventId: String
        let calendarId: String
        let accountEmail: String
        let meetingURL: String?
    }

    /// Create a new event on the given account. Calendar id defaults to
    /// `"primary"`. Returns the created event id so the caller can edit
    /// or delete it later without re-fetching.
    ///
    /// When `generateMeet == true`, Google attaches a fresh Meet room via
    /// `conferenceData.createRequest` (we send `conferenceDataVersion=1`
    /// so the field is honored). The generated URL is returned in the
    /// `meetingURL` field of `EventMutationResult`.
    @discardableResult
    func createEvent(on email: String,
                     calendarId: String = "primary",
                     title: String,
                     start: Date,
                     end: Date,
                     isAllDay: Bool = false,
                     location: String?,
                     notes: String? = nil,
                     meetingURL: String?,
                     generateMeet: Bool = false,
                     attendees: [String] = [],
                     attachments: [EventAttachment] = [],
                     remindersMinutes: [Int] = []) async throws -> EventMutationResult {
        let token = try await validAccessToken(for: email)

        var body = Self.eventBody(
            title: title,
            start: start,
            end: end,
            isAllDay: isAllDay,
            location: location,
            notes: notes,
            // If Google is going to mint the URL, don't also bake the
            // user's empty string into description.
            meetingURL: generateMeet ? nil : meetingURL,
            attendees: attendees,
            attachments: attachments,
            remindersMinutes: remindersMinutes
        )
        if generateMeet {
            body["conferenceData"] = [
                "createRequest": [
                    "requestId": UUID().uuidString,
                    "conferenceSolutionKey": ["type": "hangoutsMeet"]
                ]
            ]
        }

        // `supportsAttachments=true` is REQUIRED by Google when we
        // attach Drive/URL files via the API. `sendUpdates=all` makes
        // invitees actually get the email.
        let url = Self.eventsCollectionURL(
            calendarId: calendarId,
            conferenceDataVersion: generateMeet ? 1 : nil,
            supportsAttachments: !attachments.isEmpty,
            sendUpdates: attendees.isEmpty ? nil : "all"
        )
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.assertOK(resp, data: data)

        let created = try JSONDecoder().decode(EventDTO.self, from: data)
        return EventMutationResult(
            eventId: created.id,
            calendarId: calendarId,
            accountEmail: email,
            meetingURL: Self.resolveMeetingURL(from: created)
        )
    }

    /// Pull the best meeting URL out of an event response. Google fills
    /// `hangoutLink` for Meet rooms; `conferenceData.entryPoints` is the
    /// generic fallback (also used for Zoom etc. via add-ons).
    private static func resolveMeetingURL(from dto: EventDTO) -> String? {
        if let link = dto.hangoutLink, !link.isEmpty { return link }
        if let entry = dto.conferenceData?.entryPoints?
            .first(where: { $0.entryPointType == "video" })?.uri,
           !entry.isEmpty {
            return entry
        }
        return nil
    }

    /// Update an existing event via PATCH (partial). Any non-nil field is
    /// included; nil fields are left as-is on the server.
    ///
    /// When `generateMeet == true`, a Meet room is attached via
    /// `conferenceData.createRequest` (works for events that don't yet
    /// have one). The new URL is returned in `EventMutationResult`.
    @discardableResult
    func updateEvent(accountEmail: String,
                     calendarId: String,
                     eventId: String,
                     title: String? = nil,
                     start: Date? = nil,
                     end: Date? = nil,
                     isAllDay: Bool? = nil,
                     location: String? = nil,
                     notes: String? = nil,
                     meetingURL: String? = nil,
                     generateMeet: Bool = false,
                     attendees: [String]? = nil,
                     attachments: [EventAttachment]? = nil,
                     remindersMinutes: [Int]? = nil) async throws -> EventMutationResult {
        let token = try await validAccessToken(for: accountEmail)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = TimeZone(identifier: "UTC")

        var body: [String: Any] = [:]
        if let title { body["summary"] = title }
        if let location { body["location"] = location }
        // Notes get the manually-entered Meet URL appended when Google
        // isn't minting one. Notes-nil + meetingURL-only means we still
        // write a description so the URL is clickable.
        if let notes, !notes.isEmpty {
            if !generateMeet, let url = meetingURL, !url.isEmpty {
                body["description"] = "\(notes)\n\(url)"
            } else {
                body["description"] = notes
            }
        } else if notes != nil {
            // Caller explicitly cleared notes
            body["description"] = ""
        } else if !generateMeet, let url = meetingURL, !url.isEmpty {
            body["description"] = url
        }

        // Date vs dateTime semantics for all-day events
        if let start {
            let useAllDay = isAllDay ?? false
            body["start"] = useAllDay
                ? ["date": dateOnly.string(from: start)]
                : ["dateTime": isoFormatter.string(from: start)]
        }
        if let end {
            let useAllDay = isAllDay ?? false
            body["end"] = useAllDay
                ? ["date": dateOnly.string(from: end)]
                : ["dateTime": isoFormatter.string(from: end)]
        }

        if generateMeet {
            body["conferenceData"] = [
                "createRequest": [
                    "requestId": UUID().uuidString,
                    "conferenceSolutionKey": ["type": "hangoutsMeet"]
                ]
            ]
        }
        if let attendees {
            body["attendees"] = attendees.map { ["email": $0] }
        }
        if let attachments {
            body["attachments"] = attachments.map { att -> [String: Any] in
                var dict: [String: Any] = [
                    "fileUrl": att.fileURL.absoluteString,
                    "title": att.title,
                ]
                if let m = att.mimeType { dict["mimeType"] = m }
                return dict
            }
        }
        if let remindersMinutes {
            body["reminders"] = [
                "useDefault": remindersMinutes.isEmpty,
                "overrides": remindersMinutes.map {
                    ["method": "popup", "minutes": $0]
                }
            ]
        }

        let url = Self.eventResourceURL(
            calendarId: calendarId,
            eventId: eventId,
            conferenceDataVersion: generateMeet ? 1 : nil,
            supportsAttachments: attachments?.isEmpty == false,
            sendUpdates: attendees == nil ? nil : "all"
        )
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.assertOK(resp, data: data)
        // Try to extract a Meet URL from the response (only present when
        // generateMeet was true and Google already minted the room).
        let patched = try? JSONDecoder().decode(EventDTO.self, from: data)
        return EventMutationResult(
            eventId: eventId,
            calendarId: calendarId,
            accountEmail: accountEmail,
            meetingURL: patched.flatMap { Self.resolveMeetingURL(from: $0) }
        )
    }

    /// RSVP response values the Google Calendar API understands.
    enum RSVPStatus: String {
        case accepted   // Yes
        case tentative  // Maybe
        case declined   // No
        case needsAction
    }

    /// Update the authenticated user's RSVP for an event. Internally fetches
    /// the current attendees, patches the matching attendee's
    /// `responseStatus`, and PATCHes back. Other attendees and their
    /// responses are preserved. Result reflects back to Google Calendar
    /// (and ultimately to the organizer's view).
    func setRSVP(accountEmail: String,
                 calendarId: String,
                 eventId: String,
                 status: RSVPStatus) async throws {
        let token = try await validAccessToken(for: accountEmail)

        // 1) Fetch the full event so we have the existing attendees array.
        let getURL = Self.eventResourceURL(calendarId: calendarId, eventId: eventId)
        var getReq = URLRequest(url: getURL)
        getReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (getData, getResp) = try await URLSession.shared.data(for: getReq)
        try Self.assertOK(getResp, data: getData)
        guard
            let raw = try JSONSerialization.jsonObject(with: getData) as? [String: Any],
            var attendeesRaw = raw["attendees"] as? [[String: Any]]
        else {
            // No attendees on this event — the user isn't actually invited,
            // so there's nothing to RSVP to. Bail.
            throw GoogleAuthError.network("No attendees list on event \(eventId)")
        }

        // 2) Mutate the matching attendee. PATCH on `attendees` replaces
        //    the whole array, so we have to send the others back unchanged.
        var matched = false
        for i in 0..<attendeesRaw.count {
            if let email = attendeesRaw[i]["email"] as? String, email == accountEmail {
                attendeesRaw[i]["responseStatus"] = status.rawValue
                matched = true
                break
            }
        }
        guard matched else {
            throw GoogleAuthError.network("\(accountEmail) is not on this event's invite list")
        }

        // 3) PATCH the attendees array back. We add `sendUpdates=externalOnly`
        //    so Google notifies attendees outside the same Workspace
        //    domain (the organizer always gets the update via internal
        //    sync regardless).
        var patchURL = getURL.absoluteString
        patchURL += "?sendUpdates=externalOnly"
        var patchReq = URLRequest(url: URL(string: patchURL)!)
        patchReq.httpMethod = "PATCH"
        patchReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        patchReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        patchReq.httpBody = try JSONSerialization.data(
            withJSONObject: ["attendees": attendeesRaw]
        )

        let (patchData, patchResp) = try await URLSession.shared.data(for: patchReq)
        try Self.assertOK(patchResp, data: patchData)
    }

    /// Delete an event. After this returns, the next `fetchAllEvents` call
    /// will no longer return it.
    func deleteEvent(accountEmail: String,
                     calendarId: String,
                     eventId: String) async throws {
        let token = try await validAccessToken(for: accountEmail)
        let url = Self.eventResourceURL(calendarId: calendarId, eventId: eventId)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        // DELETE returns 204 No Content on success — assertOK accepts the
        // full 2xx range.
        try Self.assertOK(resp, data: data)
    }

    // MARK: URL + body helpers

    /// Build query-string suffix from optional params. Returns "" or
    /// "?a=1&b=2".
    private static func queryString(_ items: [(String, String?)]) -> String {
        let pairs = items.compactMap { (k, v) -> String? in
            guard let v else { return nil }
            return "\(k)=\(v)"
        }
        return pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")
    }

    private static func eventsCollectionURL(
        calendarId: String,
        conferenceDataVersion: Int? = nil,
        supportsAttachments: Bool = false,
        sendUpdates: String? = nil
    ) -> URL {
        let encoded = calendarId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? calendarId
        var s = "https://www.googleapis.com/calendar/v3/calendars/\(encoded)/events"
        s += queryString([
            ("conferenceDataVersion", conferenceDataVersion.map { "\($0)" }),
            ("supportsAttachments", supportsAttachments ? "true" : nil),
            ("sendUpdates", sendUpdates),
        ])
        return URL(string: s)!
    }

    private static func eventResourceURL(
        calendarId: String,
        eventId: String,
        conferenceDataVersion: Int? = nil,
        supportsAttachments: Bool = false,
        sendUpdates: String? = nil
    ) -> URL {
        let encCal = calendarId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? calendarId
        let encId = eventId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? eventId
        var s = "https://www.googleapis.com/calendar/v3/calendars/\(encCal)/events/\(encId)"
        s += queryString([
            ("conferenceDataVersion", conferenceDataVersion.map { "\($0)" }),
            ("supportsAttachments", supportsAttachments ? "true" : nil),
            ("sendUpdates", sendUpdates),
        ])
        return URL(string: s)!
    }

    private static func eventBody(title: String,
                                  start: Date,
                                  end: Date,
                                  isAllDay: Bool,
                                  location: String?,
                                  notes: String?,
                                  meetingURL: String?,
                                  attendees: [String],
                                  attachments: [EventAttachment],
                                  remindersMinutes: [Int]) -> [String: Any] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = TimeZone(identifier: "UTC")

        var body: [String: Any] = ["summary": title]
        if isAllDay {
            body["start"] = ["date": dateOnly.string(from: start)]
            body["end"]   = ["date": dateOnly.string(from: end)]
        } else {
            body["start"] = ["dateTime": isoFormatter.string(from: start)]
            body["end"]   = ["dateTime": isoFormatter.string(from: end)]
        }

        if let loc = location, !loc.isEmpty { body["location"] = loc }

        // Compose description from notes + meeting URL
        var desc = notes ?? ""
        if let url = meetingURL, !url.isEmpty {
            if !desc.isEmpty { desc += "\n" }
            desc += url
        }
        if !desc.isEmpty { body["description"] = desc }

        // Attendees — Google emails them automatically when
        // sendUpdates=all is set on the request URL.
        let trimmedAttendees = attendees
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trimmedAttendees.isEmpty {
            body["attendees"] = trimmedAttendees.map { ["email": $0] }
        }

        // Attachments — `supportsAttachments=true` MUST be in the query
        // string when this is non-empty (handled by the URL builder).
        if !attachments.isEmpty {
            body["attachments"] = attachments.map { att -> [String: Any] in
                var dict: [String: Any] = [
                    "fileUrl": att.fileURL.absoluteString,
                    "title": att.title,
                ]
                if let m = att.mimeType { dict["mimeType"] = m }
                return dict
            }
        }

        // Per-event popup reminders. Empty array ⇒ fall back to the
        // calendar's default reminders.
        if !remindersMinutes.isEmpty {
            body["reminders"] = [
                "useDefault": false,
                "overrides": remindersMinutes.map {
                    ["method": "popup", "minutes": $0]
                }
            ]
        }
        return body
    }

    private static func assertOK(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleAuthError.network("HTTP \(http.statusCode) — \(body.prefix(200))")
        }
    }

    /// Returns an access token, refreshing it if needed.
    /// Used by Phase 1B (Calendar API calls).
    func validAccessToken(for email: String) async throws -> String {
        if let cached = GoogleKeychain.accessToken(for: email),
           let exp = GoogleKeychain.expiresAt(for: email),
           exp > Date().addingTimeInterval(60) {
            return cached
        }
        guard let refresh = GoogleKeychain.refreshToken(for: email) else {
            throw GoogleAuthError.tokenExchange("missing refresh token")
        }
        let tokens = try await refreshTokens(refreshToken: refresh)
        GoogleKeychain.store(
            email: email,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken ?? refresh,
            expiresIn: tokens.expiresIn
        )
        return tokens.accessToken
    }

    // MARK: - Internals

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let id_token: String?
        let token_type: String?
        // friendlier names
        var accessToken: String  { access_token }
        var refreshToken: String? { refresh_token }
        var expiresIn: Int        { expires_in ?? 3600 }
    }

    private struct UserInfo: Decodable {
        let email: String
        let name: String?
    }

    private func exchange(code: String, codeVerifier: String) async {
        do {
            let tokens = try await postForm(url: tokenURL, params: [
                "code": code,
                "client_id": clientID,
                "client_secret": Self.defaultClientSecret,
                "code_verifier": codeVerifier,
                "redirect_uri": currentRedirectURI,
                "grant_type": "authorization_code",
            ])
            let user = try await fetchUserInfo(accessToken: tokens.accessToken)

            // Store tokens now so the API can use them; account row is added
            // only after the user picks a color in the sheet.
            GoogleKeychain.store(
                email: user.email,
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken ?? "",
                expiresIn: tokens.expiresIn
            )

            await MainActor.run {
                // Pick the color: keep existing if reconnecting, or
                // auto-assign the next unused preset for new accounts
                // (the user can change it later from the account row).
                let colorHex: String
                if let existing = accounts.first(where: { $0.email == user.email }) {
                    colorHex = existing.colorHex
                } else {
                    colorHex = CalendarColorPreset
                        .nextUnused(in: linkedCalendarColors())
                        .hex
                }
                finalizePendingAccount(email: user.email,
                                       name: user.name,
                                       colorHex: colorHex)
                lastError = nil

                // Bring Forge to the front so the user sees the
                // connected account in Settings, not the leftover
                // Chrome tab.
                NSApp.activate(ignoringOtherApps: true)
            }
        } catch let e as GoogleAuthError {
            await MainActor.run { lastError = e.localizedDescription }
        } catch {
            await MainActor.run { lastError = error.localizedDescription }
        }
    }

    /// Called by the UI when the user picks a color. Saves the account.
    @MainActor
    func confirmPendingAccount(color: String) {
        guard let pending = pendingAccount else { return }
        finalizePendingAccount(email: pending.email,
                               name: pending.name,
                               colorHex: color)
        pendingAccount = nil
    }

    /// User dismissed the color sheet without picking. Revoke tokens.
    @MainActor
    func cancelPendingAccount() {
        guard let pending = pendingAccount else { return }
        if let refresh = GoogleKeychain.refreshToken(for: pending.email) {
            Task { try? await revoke(token: refresh) }
        }
        GoogleKeychain.delete(for: pending.email)
        pendingAccount = nil
    }

    @MainActor
    private func finalizePendingAccount(email: String, name: String?, colorHex: String) {
        let account = GoogleAccount(
            email: email, name: name, connectedAt: Date(), colorHex: colorHex
        )
        if let idx = accounts.firstIndex(where: { $0.email == email }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
        saveAccounts()
    }

    /// Bridge so `CalendarColorPreset.nextUnused` can dedupe against accounts.
    private func linkedCalendarColors() -> [LinkedCalendar] {
        accounts.map {
            LinkedCalendar(calendarIdentifier: $0.email,
                           displayName: $0.email,
                           colorHex: $0.colorHex)
        }
    }

    /// Update color for an existing account.
    @MainActor
    func setColor(for email: String, colorHex: String) {
        guard let idx = accounts.firstIndex(where: { $0.email == email }) else { return }
        accounts[idx].colorHex = colorHex
        saveAccounts()
    }

    private func refreshTokens(refreshToken: String) async throws -> TokenResponse {
        try await postForm(url: tokenURL, params: [
            "client_id": clientID,
            "client_secret": Self.defaultClientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    private func fetchUserInfo(accessToken: String) async throws -> UserInfo {
        var req = URLRequest(url: URL(string: userinfoURL)!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleAuthError.userInfo("HTTP \( (resp as? HTTPURLResponse)?.statusCode ?? -1 )")
        }
        return try JSONDecoder().decode(UserInfo.self, from: data)
    }

    private func revoke(token: String) async throws {
        var comps = URLComponents(string: revokeURL)!
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: req)
    }

    private func postForm(url: String, params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = params
            .map { "\(Self.percent($0.key))=\(Self.percent($0.value))" }
            .joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleAuthError.tokenExchange("HTTP \(http.statusCode) — \(body)")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - PKCE helpers

    private static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func sha256URLSafe(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return Data(digest).base64URLEncoded()
    }

    private static func percent(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - Keychain (refresh + access tokens, scoped per email)

enum GoogleKeychain {
    /// Keychain "service" identifier. Bumped from the legacy
    /// `com.strativ.forge.google` when we renamed the bundle ID
    /// to `com.toolkit.forge`. Existing entries under the old
    /// service string remain on disk but inaccessible to the
    /// renamed app — by design, macOS Keychain scopes secrets by
    /// the code-signing identity + service string. Users will
    /// simply re-connect Google accounts once on first launch
    /// under the new bundle.
    private static let service = "com.toolkit.forge.google"

    static func store(email: String, accessToken: String, refreshToken: String, expiresIn: Int) {
        set(value: accessToken,  account: "\(email)|access")
        if !refreshToken.isEmpty { set(value: refreshToken, account: "\(email)|refresh") }
        let exp = Date().addingTimeInterval(TimeInterval(expiresIn))
        UserDefaults.standard.set(exp.timeIntervalSince1970, forKey: "google.exp.\(email)")
    }

    static func accessToken(for email: String) -> String? { get(account: "\(email)|access") }
    static func refreshToken(for email: String) -> String? { get(account: "\(email)|refresh") }
    static func expiresAt(for email: String) -> Date? {
        let t = UserDefaults.standard.double(forKey: "google.exp.\(email)")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func delete(for email: String) {
        deleteItem(account: "\(email)|access")
        deleteItem(account: "\(email)|refresh")
        UserDefaults.standard.removeObject(forKey: "google.exp.\(email)")
    }

    // MARK: low-level

    private static func set(value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    private static func deleteItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Data helpers

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback HTTP listener for OAuth callback

/// Tiny single-shot HTTP server that catches Google's OAuth redirect to
/// http://127.0.0.1:PORT and pulls out the query parameters.
final class LoopbackOAuthServer {
    private(set) var port: UInt16 = 0
    var onResult: ((Result<[String: String], Error>) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.toolkit.forge.oauth-loopback")
    private var fired = false

    enum LoopbackError: LocalizedError {
        case bind(String)
        case timeout
        var errorDescription: String? {
            switch self {
            case .bind(let s): return "Couldn't bind local OAuth port: \(s)"
            case .timeout:     return "Sign-in timed out."
            }
        }
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Restrict to loopback only — safer
        params.requiredInterfaceType = .loopback

        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }

        // Use a semaphore to wait briefly for the OS-assigned port.
        let portReady = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = l.port?.rawValue ?? 0
                portReady.signal()
            }
        }
        l.start(queue: queue)
        if portReady.wait(timeout: .now() + 2.0) == .timedOut {
            l.cancel()
            throw LoopbackError.bind("listener didn't reach .ready in 2s")
        }
        listener = l

        // Hard timeout: if nothing happens in 5 min, give up.
        queue.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self = self, !self.fired else { return }
            self.fired = true
            DispatchQueue.main.async { self.onResult?(.failure(LoopbackError.timeout)) }
            self.stop()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self else { connection.cancel(); return }

            let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = req.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")
            var params: [String: String] = [:]

            if parts.count >= 2 {
                let pathQuery = parts[1]
                let urlStr = "http://127.0.0.1\(pathQuery)"
                if let url = URL(string: urlStr),
                   let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                    for item in items { if let v = item.value { params[item.name] = v } }
                }
            }

            // Send a friendly response page
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>Forge connected</title></head>
            <body style="font-family:-apple-system,Inter,sans-serif;padding:60px;text-align:center;color:#1c1917;background:#FDFBF7">
            <div style="font-size:48px">✅</div>
            <h2 style="margin:8px 0">Forge is connected.</h2>
            <p style="color:#78716c">You can close this tab and return to Forge.</p>
            <script>setTimeout(()=>window.close(),300);</script>
            </body></html>
            """
            let body = Data(html.utf8)
            let header = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
            var response = Data(header.utf8)
            response.append(body)

            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })

            // Fire result once
            if !self.fired {
                self.fired = true
                DispatchQueue.main.async {
                    self.onResult?(.success(params))
                }
            }
        }
    }
}

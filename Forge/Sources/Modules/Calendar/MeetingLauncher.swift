import Foundation
import AppKit

extension Notification.Name {
    /// Fired whenever the user explicitly engages with an event by
    /// clicking a "Join" button (from any surface — full-screen
    /// reminder, floating banner, menu-bar list, detail card, full
    /// calendar). `userInfo["eventId"]` carries the event id so the
    /// reminder module can drop it from its watch list and the
    /// banner / full-screen alert won't re-fire for that instance.
    static let meetingJoined = Notification.Name("forge.meetingJoined")
}

/// Centralised "open a meeting URL" entry point. Prefers the native
/// desktop app (Zoom / Microsoft Teams / Webex Meetings) when it's
/// installed; falls back to the web URL otherwise.
///
/// Why this exists: clicking a `meet.google.com` URL is fine in any
/// browser, but `zoom.us/j/123` opened in a browser kicks the user
/// through a slow "Launching Zoom…" interstitial. The native scheme
/// (`zoommtg://`) skips that page and joins the meeting immediately
/// if Zoom is installed — same for Teams and Webex.
enum MeetingLauncher {

    /// Open `url` in the best available client. Tries the native deep
    /// link first; on failure (app not installed or unsupported
    /// scheme), opens the raw HTTPS URL.
    static func open(_ url: URL) {
        if let native = nativeURL(for: url),
           hasHandler(for: native),
           NSWorkspace.shared.open(native) {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Join a calendar event: opens the meeting URL via `open(_:)`
    /// AND posts `.meetingJoined` so any reminder surfaces still
    /// watching this event drop it from their list. Use this from
    /// every Join button — `open(_:)` directly is for cases where
    /// we don't have an event context (e.g. deep-link handlers).
    static func join(_ event: CalendarEvent) {
        guard let url = event.meetingURL else { return }
        // For Google Meet links, pin the Google account that owns the
        // event so the browser opens it under that account instead of
        // defaulting to whichever Google account is signed in first.
        open(accountScopedURL(url, accountEmail: event.googleRouting?.accountEmail))
        NotificationCenter.default.post(
            name: .meetingJoined,
            object: nil,
            userInfo: ["eventId": event.id]
        )
    }

    /// Appends `authuser=<email>` to a Google Meet URL so the browser
    /// opens the meeting under the account that owns the event.
    ///
    /// Without this, a `meet.google.com/...` link opened in a browser
    /// with multiple signed-in Google accounts defaults to `authuser=0`
    /// (the first account), which is often NOT the account invited to the
    /// meeting — leading to a "you need access" wall. Google honors an
    /// `authuser` value that's either an index or an email address; we
    /// use the email since it's stable regardless of sign-in order.
    ///
    /// No-op for non-Meet URLs, a missing/!email account, or when an
    /// `authuser` parameter is already present on the link.
    static func accountScopedURL(_ url: URL, accountEmail: String?) -> URL {
        guard let email = accountEmail, email.contains("@"),
              (url.host?.lowercased().contains("meet.google.com") ?? false),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }

        var items = comps.queryItems ?? []
        guard !items.contains(where: { $0.name.lowercased() == "authuser" }) else { return url }
        items.append(URLQueryItem(name: "authuser", value: email))
        comps.queryItems = items
        return comps.url ?? url
    }

    /// Returns a service tag suitable for showing next to the Join
    /// button ("Zoom" / "Teams" / "Webex" / "Meet" / nil).
    static func service(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host.contains("zoom.us")                 { return "Zoom" }
        if host.contains("teams.microsoft.com")
            || host.contains("teams.live.com")      { return "Teams" }
        if host.contains("webex.com")               { return "Webex" }
        if host.contains("meet.google.com")         { return "Meet" }
        if host.contains("whereby.com")             { return "Whereby" }
        if host.contains("around.co")               { return "Around" }
        return nil
    }

    // MARK: - Native scheme construction

    /// Best-effort native URL for the given web URL. Returns nil when
    /// the service has no native app (Google Meet) or the URL doesn't
    /// match a known pattern.
    static func nativeURL(for url: URL) -> URL? {
        let host = url.host?.lowercased() ?? ""

        // --- Zoom ---
        // Web:   https://*.zoom.us/j/<meetingId>?pwd=<pwd>
        //        https://*.zoom.us/my/<personalRoom>
        //        https://*.zoom.us/s/<meetingId>?pwd=<pwd>
        // Deep:  zoommtg://zoom.us/join?confno=<meetingId>&pwd=<pwd>
        //        zoommtg://zoom.us/start?pmi=<personalRoom>
        if host.hasSuffix("zoom.us") {
            return zoomNativeURL(from: url)
        }

        // --- Microsoft Teams ---
        // Both regular and personal Teams. The `msteams:` scheme is
        // the documented entry point and works for `meetup-join` URLs.
        // Just swap the scheme — Teams parses the rest.
        if host.contains("teams.microsoft.com") || host.contains("teams.live.com") {
            let abs = url.absoluteString
            if abs.lowercased().hasPrefix("https://") {
                return URL(string: "msteams:/" + abs.dropFirst("https:".count))
            }
            return nil
        }

        // --- Webex ---
        // Webex Meetings registers `webex://` for join links. The web
        // URL itself is the meeting; the desktop client handles it
        // when we hand it the same path under the webex scheme.
        if host.contains("webex.com") {
            let abs = url.absoluteString
            if abs.lowercased().hasPrefix("https://") {
                return URL(string: "webex://" + abs.dropFirst("https://".count))
            }
            return nil
        }

        // Google Meet → no native macOS desktop app for joining. Fall
        // through to the browser.
        return nil
    }

    /// Pull Zoom meeting ID / password out of common URL shapes and
    /// build the `zoommtg://` deep link.
    private static func zoomNativeURL(from url: URL) -> URL? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        let kind = parts[0]        // "j", "my", "s", "wc", "join"
        let id   = parts[1]

        let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "pwd" })?
            .value

        let base: String
        switch kind {
        case "my":
            base = "zoommtg://zoom.us/start?pmi=\(id)"
        default:
            // "j", "s", "wc", "join" — all use the standard join entry.
            base = "zoommtg://zoom.us/join?confno=\(id)"
        }
        let composed = (pwd?.isEmpty == false) ? "\(base)&pwd=\(pwd!)" : base
        return URL(string: composed)
    }

    /// True when macOS has an app registered to handle the URL's
    /// scheme. NSWorkspace queues this lookup against LaunchServices
    /// — no permission required.
    private static func hasHandler(for url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }
}

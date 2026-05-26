import SwiftUI

// MARK: - Attendee avatar strip

/// Horizontal strip of attendee avatars with overflow. Shows up to
/// `maxShown` initial-bubbles in a row, then a `+N` chip for the rest.
/// Each bubble carries a `.help(...)` tooltip with the attendee's
/// name + email so hovering reveals identity. Google Calendar's API
/// doesn't return photo URLs on attendees, so we hash the email to
/// pick a deterministic accent color and overlay 1–2 initials.
///
/// `darkMode` controls border + text contrast — pass `true` for the
/// full-screen reminder (dark background) and `false` for the
/// detail popover (light card).
struct AttendeeAvatarStrip: View {
    let attendees: [EventAttendee]
    var maxShown: Int = 8
    var avatarSize: CGFloat = 26
    var darkMode: Bool = false

    var body: some View {
        let shown = Array(attendees.prefix(maxShown))
        let overflow = max(0, attendees.count - maxShown)

        // Overlap each chip a bit so the row reads as "a group of
        // people" rather than "a sequence of separate icons".
        HStack(spacing: -avatarSize * 0.30) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { idx, a in
                avatar(for: a)
                    // Earlier chips paint over later chips, so the
                    // leftmost stays on top — the natural reading
                    // order in left-to-right scripts.
                    .zIndex(Double(maxShown - idx))
            }
            if overflow > 0 {
                overflowChip(overflow)
                    .zIndex(0)
            }
        }
    }

    // MARK: Chip builders

    private func avatar(for attendee: EventAttendee) -> some View {
        let initials = Self.initials(for: attendee)
        let bgColor  = Self.color(for: attendee.email)
        return Text(initials)
            .font(.system(size: avatarSize * 0.42, weight: .bold))
            .foregroundColor(.white)
            .frame(width: avatarSize, height: avatarSize)
            .background(Circle().fill(bgColor))
            .overlay(
                Circle().strokeBorder(
                    darkMode ? Color.white.opacity(0.30) : Color.white,
                    lineWidth: 1.5
                )
            )
            // Ring around the organizer so the user can tell at a
            // glance who set up the meeting.
            .overlay(
                Circle()
                    .strokeBorder(
                        attendee.isOrganizer ? Color.yellow.opacity(0.85) : Color.clear,
                        lineWidth: 1.5
                    )
                    .padding(-1)
            )
            // Status pip in the bottom-right corner.
            .overlay(alignment: .bottomTrailing) {
                statusPip(for: attendee.responseStatus)
                    .frame(width: avatarSize * 0.34, height: avatarSize * 0.34)
                    .offset(x: 1, y: 1)
            }
            .help(Self.tooltip(for: attendee))
    }

    private func overflowChip(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: avatarSize * 0.36, weight: .bold))
            .foregroundColor(darkMode ? .white : ForgeTheme.Colors.textPrimary)
            .frame(width: avatarSize, height: avatarSize)
            .background(
                Circle().fill(
                    darkMode ? Color.white.opacity(0.15) : ForgeTheme.Colors.surfaceHover
                )
            )
            .overlay(
                Circle().strokeBorder(
                    darkMode ? Color.white.opacity(0.30) : ForgeTheme.Colors.borderDefault,
                    lineWidth: 1.5
                )
            )
            .help(overflowTooltip)
    }

    /// Tiny colored dot that indicates a single attendee's RSVP
    /// status. Hidden for `needsAction` / nil so the strip stays
    /// uncluttered when responses haven't come in.
    @ViewBuilder
    private func statusPip(for status: String?) -> some View {
        switch status {
        case "accepted":
            Circle()
                .fill(Color(red: 0.20, green: 0.78, blue: 0.36))
                .overlay(Circle().strokeBorder(darkMode ? Color.black.opacity(0.6) : .white, lineWidth: 1))
        case "declined":
            Circle()
                .fill(Color(red: 0.92, green: 0.30, blue: 0.30))
                .overlay(Circle().strokeBorder(darkMode ? Color.black.opacity(0.6) : .white, lineWidth: 1))
        case "tentative":
            Circle()
                .fill(Color(red: 0.96, green: 0.70, blue: 0.20))
                .overlay(Circle().strokeBorder(darkMode ? Color.black.opacity(0.6) : .white, lineWidth: 1))
        default:
            EmptyView()
        }
    }

    // MARK: Helpers

    /// Best-effort initials extraction:
    ///   1. "First Last"  → "FL"
    ///   2. "Only"        → "ON"
    ///   3. fallback to first two chars of email local-part
    static func initials(for attendee: EventAttendee) -> String {
        if let name = attendee.displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let parts = name.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2 {
                let first = parts[0].prefix(1)
                let second = parts[1].prefix(1)
                return (first + second).uppercased()
            }
            return String(name.prefix(2)).uppercased()
        }
        let local = attendee.email.split(separator: "@").first.map(String.init) ?? attendee.email
        return String(local.prefix(2)).uppercased()
    }

    /// "Display Name · email@addr" if a name exists, else just email.
    /// Suffixed with " (organizer)" for the organizer so hovers tell
    /// the user who's running the show.
    static func tooltip(for attendee: EventAttendee) -> String {
        let name = attendee.displayName?.trimmingCharacters(in: .whitespaces) ?? ""
        var base = name.isEmpty ? attendee.email : "\(name) · \(attendee.email)"
        if attendee.isOrganizer { base += " (organizer)" }
        // Append RSVP status when known.
        switch attendee.responseStatus {
        case "accepted":  base += " · Yes"
        case "tentative": base += " · Maybe"
        case "declined":  base += " · Declined"
        default: break
        }
        return base
    }

    /// Tooltip for the "+N" chip — newline-separated list of every
    /// attendee that doesn't fit in the visible strip.
    private var overflowTooltip: String {
        let remaining = attendees.dropFirst(maxShown)
        return remaining.map { Self.shortName(for: $0) }.joined(separator: "\n")
    }

    static func shortName(for attendee: EventAttendee) -> String {
        let name = attendee.displayName?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? attendee.email : name
    }

    /// Deterministic accent color from the email — same person always
    /// gets the same chip color, different people get visually
    /// distinct ones. We bias saturation/brightness to keep contrast
    /// against both light and dark backgrounds reasonable.
    static func color(for email: String) -> Color {
        // Use unicode scalars so the hash is stable across runs (the
        // built-in `String.hash` is randomized per launch).
        var seed: UInt64 = 1469598103934665603
        for scalar in email.lowercased().unicodeScalars {
            seed ^= UInt64(scalar.value)
            seed &*= 1099511628211
        }
        let hue = Double(seed % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.68)
    }
}

// MARK: - RSVP button row

/// Three pill buttons — Yes / Maybe / Decline — that PATCH the user's
/// attendance status on a Google Calendar event. Tracks an optimistic
/// `selected` state so the UI reflects the new choice immediately,
/// before the API round-trip completes.
struct RSVPButtonRow: View {
    let event: CalendarEvent
    /// Optional callback fired right after a successful RSVP — the
    /// caller can refresh its event list or toast.
    var onResponse: ((GoogleCalendarService.RSVPStatus) -> Void)? = nil
    var darkMode: Bool = false

    @State private var selected: String

    init(event: CalendarEvent,
         onResponse: ((GoogleCalendarService.RSVPStatus) -> Void)? = nil,
         darkMode: Bool = false) {
        self.event = event
        self.onResponse = onResponse
        self.darkMode = darkMode
        // Initialize with whatever Google last told us.
        _selected = State(initialValue: event.myResponseStatus ?? "needsAction")
    }

    var body: some View {
        HStack(spacing: 6) {
            rsvpButton("Yes",     statusKey: "accepted",  api: .accepted)
            rsvpButton("Maybe",   statusKey: "tentative", api: .tentative)
            rsvpButton("Decline", statusKey: "declined",  api: .declined)
        }
    }

    @ViewBuilder
    private func rsvpButton(_ label: String, statusKey: String, api: GoogleCalendarService.RSVPStatus) -> some View {
        let isActive = selected == statusKey
        let accent = Self.color(for: statusKey)
        Button {
            // Optimistic flip — feels instant, then the PATCH catches up.
            selected = statusKey
            sendRSVP(api)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(
                    isActive ? .white : (darkMode ? Color.white.opacity(0.85) : ForgeTheme.Colors.textPrimary)
                )
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        isActive
                            ? accent
                            : (darkMode ? Color.white.opacity(0.08) : ForgeTheme.Colors.surfaceHover)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        isActive
                            ? Color.clear
                            : accent.opacity(0.45),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func sendRSVP(_ status: GoogleCalendarService.RSVPStatus) {
        guard let r = event.googleRouting else { return }
        Task {
            do {
                try await GoogleCalendarService.shared.setRSVP(
                    accountEmail: r.accountEmail,
                    calendarId: r.calendarId,
                    eventId: r.eventId,
                    status: status
                )
                await MainActor.run { onResponse?(status) }
            } catch {
                print("[Forge RSVP] failed: \(error.localizedDescription)")
            }
        }
    }

    /// Per-status accent — green for Yes, amber for Maybe, red for
    /// Decline. Matches the convention people expect from Google /
    /// Outlook.
    static func color(for statusKey: String) -> Color {
        switch statusKey {
        case "accepted":  return Color(red: 0.20, green: 0.72, blue: 0.34)
        case "tentative": return Color(red: 0.95, green: 0.65, blue: 0.20)
        case "declined":  return Color(red: 0.90, green: 0.25, blue: 0.25)
        default:          return ForgeTheme.Colors.accent
        }
    }
}

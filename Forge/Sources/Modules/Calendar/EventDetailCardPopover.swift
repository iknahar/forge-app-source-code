import SwiftUI
import AppKit

/// Floating detail card shown when the user clicks an event row in the
/// menu-bar popover. Mirrors `EventDetailSidePanel` (the right-rail
/// variant used by FullCalendarView) but sized for a popover, with the
/// `Edit` button routing back to the parent so it can present the full
/// editor sheet.
///
/// We deliberately don't reuse `EventDetailSidePanel` directly because
/// it's `private` to FullCalendarView and tightly coupled to its rail
/// layout (the close button collapses the rail, the rail width is
/// fixed). This card is a thinner port of the same visual contract.
struct EventDetailCardPopover: View {
    let event: CalendarEvent
    let onClose: () -> Void
    let onEdit: () -> Void

    @EnvironmentObject private var calendarModule: CalendarModule
    @Environment(\.colorScheme) private var colorScheme
    @State private var now: Date = Date()
    @State private var copyToast: String?
    @State private var confirmDelete = false
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header — title + close
            HStack(alignment: .top) {
                Text(event.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                    .lineLimit(3)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(ForgeTheme.Colors.surfaceHover))
                }
                .buttonStyle(.plain)
            }

            // Calendar pill
            HStack(spacing: 6) {
                Circle().fill(event.calendarColor).frame(width: 6, height: 6)
                Text(event.calendarTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(ForgeTheme.Colors.surfaceHover))
            .overlay(Capsule().strokeBorder(ForgeTheme.Colors.borderDefault, lineWidth: 0.5))

            // Date + time + countdown badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(longDateString)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                    HStack(spacing: 5) {
                        Text(timeRangeString)
                            .font(.system(size: 11))
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                        Text("·")
                            .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.4))
                        Text(durationString)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                    }
                }
                Spacer()
                countdownBadge
            }

            Divider().opacity(0.12)

            // Join row
            if event.hasMeetingLink, let url = event.meetingURL {
                Button { MeetingLauncher.join(event) } label: {
                    HStack(spacing: 10) {
                        meetingIcon(for: url)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Join")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(ForgeTheme.Colors.textPrimary)
                            Text(url.host ?? url.absoluteString)
                                .font(.system(size: 10))
                                .foregroundColor(ForgeTheme.Colors.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(ForgeTheme.Colors.surfaceHover)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(ForgeTheme.Colors.borderDefault, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }

            // Attachments — small horizontal icon row
            if !event.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(event.attachments.prefix(6)) { att in
                        attachmentChip(att)
                    }
                    if event.attachments.count > 6 {
                        Text("+\(event.attachments.count - 6)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                    }
                }
            }

            // Meeting URL plain row
            if let url = event.meetingURL?.absoluteString {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 10))
                        .foregroundColor(ForgeTheme.Colors.accent)
                        .frame(width: 14)
                    Text(url)
                        .font(.system(size: 10))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }

            // Location
            if let loc = event.location, !loc.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 10))
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                        .frame(width: 14)
                    Text(loc)
                        .font(.system(size: 10))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                        .lineLimit(2)
                }
            }

            // Notes
            if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
               !notes.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 10))
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                            .frame(width: 14)
                        Text("Notes")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                    }
                    Text(notes)
                        .font(.system(size: 11))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(4)
                }
            }

            // Attendees: count line + avatar strip showing up to 8
            // people. Hovering each chip surfaces name + email.
            if event.attendeeCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 9))
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                            .frame(width: 14)
                        Text("\(event.attendeeCount) invited · \(event.confirmedAttendeeCount) accepted")
                            .font(.system(size: 10))
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                    }
                    if !event.attendees.isEmpty {
                        AttendeeAvatarStrip(
                            attendees: event.attendees,
                            maxShown: 8,
                            avatarSize: 22,
                            darkMode: false
                        )
                        .padding(.leading, 20)
                    }
                }
            }

            // RSVP — only for Google events the user is actually
            // invited to (organizers and EventKit events don't get
            // these). Yes / Maybe / Decline; flips optimistically.
            if event.isGoogleEvent, event.isInvited {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your response")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                    RSVPButtonRow(event: event)
                }
            }

            Divider().opacity(0.12)

            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(ForgeTheme.Colors.surfaceCard)
        .overlay(alignment: .top) {
            if let toast = copyToast {
                Text(toast)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.top, -10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if event.isGoogleEvent {
                footerButton(icon: "pencil", label: "Edit", action: onEdit)
            }
            footerButton(
                icon: "bell",
                label: reminderLabel,
                action: { if event.isGoogleEvent { onEdit() } }
            )
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
                        .font(.system(size: 10))
                    Text("Copy")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(ForgeTheme.Colors.textPrimary)
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
                            .font(.system(size: 11))
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
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(ForgeTheme.Colors.textPrimary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived strings + helpers

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
            badgeView(text: "NOW", tint: .blue, fillStrong: true)
        } else if event.startDate > now {
            let secs = event.startDate.timeIntervalSince(now)
            badgeView(text: countdownLabel(seconds: secs),
                      tint: .blue.opacity(0.85),
                      fillStrong: false)
        } else {
            EmptyView()
        }
    }

    private func badgeView(text: String, tint: Color, fillStrong: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(fillStrong ? .white : .blue)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(fillStrong ? tint : tint.opacity(0.15)))
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
        withAnimation { copyToast = "Copied" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { copyToast = nil }
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

    // MARK: - Meeting icon + attachment chip

    private func meetingIcon(for url: URL) -> some View {
        let s = url.absoluteString.lowercased()
        let tint: Color = {
            if s.contains("zoom.us") { return Color(red: 0.91, green: 0.20, blue: 0.20) }
            if s.contains("meet.google") { return Color(red: 0.04, green: 0.61, blue: 0.36) }
            if s.contains("teams.microsoft") { return Color(red: 0.30, green: 0.34, blue: 0.78) }
            if s.contains("webex") { return Color(red: 0.0, green: 0.65, blue: 0.78) }
            return Color.gray
        }()
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint)
            Image(systemName: "video.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private func attachmentChip(_ att: EventAttachment) -> some View {
        Button {
            NSWorkspace.shared.open(att.fileURL)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ForgeTheme.Colors.surfaceHover)
                if let iconURL = att.iconURL {
                    AsyncImage(url: iconURL) { img in
                        img.resizable().aspectRatio(contentMode: .fit).padding(5)
                    } placeholder: {
                        Image(systemName: fallbackSymbol(for: att))
                            .font(.system(size: 11))
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                    }
                } else {
                    Image(systemName: fallbackSymbol(for: att))
                        .font(.system(size: 11))
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(att.title)
    }

    private func fallbackSymbol(for att: EventAttachment) -> String {
        let host = att.fileURL.host?.lowercased() ?? ""
        if host.contains("figma") { return "f.cursive" }
        if host.contains("notion") { return "n.square" }
        if host.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if host.contains("docs.google") || host.contains("drive.google") { return "doc.text" }
        return "link"
    }
}

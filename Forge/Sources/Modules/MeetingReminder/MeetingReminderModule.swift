import SwiftUI
import AppKit
import Combine

/// Meeting Reminder — Dot-style floating banner that appears before/during a
/// meeting with Join, Snooze, Dismiss actions.
///
/// Architecture:
/// - Polls the user's calendar every 15s for the next reminder-eligible event.
/// - When an event enters the "reminder window" (start − N min … end), shows
///   the floating banner via an NSPanel.
/// - Banner uses TimelineView to keep the "Starting in 2 min" / "Started 3 min ago"
///   text live without re-creating the panel.
/// - Snooze re-arms the reminder N minutes later; Dismiss suppresses it until
///   the next app launch; Join opens the meeting URL and dismisses.
final class MeetingReminderModule: ForgeModule, ObservableObject {

    // MARK: - ForgeModule

    let id = "meetingReminder"
    let name = "Meeting Reminder"
    let description = "Floating reminder before each meeting"
    let iconName = "bell.badge.fill"
    let category: ModuleCategory = .calendar
    var isEnabled: Bool = true

    // MARK: - Dependencies (wired by AppDelegate after registration)

    weak var calendarRef: CalendarModule?
    weak var settingsRef: SettingsManager?

    // MARK: - State

    @Published private(set) var activeEvent: CalendarEvent?
    private var pollTimer: Timer?
    private var window: NSPanel?
    private var dismissed: Set<String> = []
    private var snoozedUntil: [String: Date] = [:]

    // MARK: - Lifecycle

    func activate() {
        startPolling()
        print("[Forge MeetingReminder] Activated")
    }

    func deactivate() {
        stopPolling()
        hideBanner()
        print("[Forge MeetingReminder] Deactivated")
    }

    func commands() -> [ForgeCommand] { [] }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Immediate check on activation
        tick()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tick() {
        guard let cal = calendarRef, let settings = settingsRef else {
            print("[Forge MeetingReminder] tick: missing refs")
            return
        }

        let now = Date()
        let leadSeconds = TimeInterval(max(0, settings.meetingReminderMinutes) * 60)
        let maxStartedAgoSeconds: TimeInterval = 10 * 60

        let candidate = cal.events
            .filter { event in
                let toStart = event.startDate.timeIntervalSince(now)
                let upcoming = toStart > 0 && toStart <= leadSeconds
                let recentlyStarted = toStart <= 0
                    && abs(toStart) <= maxStartedAgoSeconds
                    && now < event.endDate
                return (upcoming || recentlyStarted) && now < event.endDate
            }
            .filter { !dismissed.contains($0.id) }
            .filter { (snoozedUntil[$0.id] ?? .distantPast) <= now }
            .sorted { $0.startDate < $1.startDate }
            .first

        print("[Forge MeetingReminder] tick events=\(cal.events.count) lead=\(Int(leadSeconds))s style=\(settings.meetingReminderStyle.rawValue) candidate=\(candidate?.title ?? "none")")

        if let event = candidate {
            showBanner(for: event)
        } else if activeEvent != nil {
            hideBanner()
        }
    }

    // MARK: - Banner window — branches on user's reminder style preference

    private func showBanner(for event: CalendarEvent) {
        if activeEvent?.id == event.id, window != nil { return }
        if activeEvent?.id != event.id { hideBanner() }

        activeEvent = event

        let style = settingsRef?.meetingReminderStyle ?? .floating
        print("[Forge MeetingReminder] showBanner style=\(style.rawValue) event=\(event.title)")
        switch style {
        case .floating:   showFloatingBanner(for: event)
        case .fullscreen: showFullScreenAlert(for: event)
        }

        // Notification chime — plays once per banner show (subsequent
        // ticks for the same event return early at the top guard, so
        // we never double-chime). "Glass" is the cleanest universal
        // macOS system sound for alerts — pleasant but unmistakable,
        // and respects the user's system alert volume.
        Self.playReminderSound()
    }

    /// Asks AppKit to play the system "Glass" chime. Falls back to the
    /// generic alert beep if for some reason the system sound is missing.
    private static func playReminderSound() {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    // Floating bottom-pill (compact, white/dark depending on theme)
    private func showFloatingBanner(for event: CalendarEvent) {
        let joinShortcut = settingsRef?.binding(for: "joinMeeting").displayString ?? ""
        // Honor the user's app theme — without this the floating NSPanel
        // doesn't share the SwiftUI environment of the main window, so
        // ForgeTheme.Colors.surfaceCard (dynamic provider) was sometimes
        // reading the wrong appearance and the title rendered black-on-
        // black in the dark variant.
        let theme = settingsRef?.theme ?? .system

        let banner = MeetingReminderBanner(
            event: event,
            joinShortcut: joinShortcut,
            forcedScheme: theme.colorScheme,
            onJoin:    { [weak self] in self?.handleJoin(event) },
            onSnooze:  { [weak self] mins in self?.handleSnooze(event, minutes: mins) },
            onDismiss: { [weak self] in self?.handleDismiss(event) },
            onCopyURL: { [weak self] in self?.handleCopyURL(event) },
            onRSVP:    { [weak self] status in self?.handleRSVP(event, status: status) }
        )

        let hosting = NSHostingController(rootView: banner)
        // Wider than before (was 520) so the title has clear room next
        // to the now-rich action cluster (snooze + copy + attachments +
        // Join + RSVP + ×). The previous 520pt was getting squeezed and
        // the title would shrink/clip.
        let bannerWidth: CGFloat = 620
        let panel = MeetingReminderPanel(
            contentRect: NSRect(x: 0, y: 0, width: bannerWidth, height: 70),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Pin the panel's NSAppearance to the chosen theme so the
        // NSColor dynamic providers inside the SwiftUI hierarchy see
        // the right appearance (otherwise they fall back to .aqua
        // and produce black-on-black text in dark mode).
        switch theme {
        case .dark:   panel.appearance = NSAppearance(named: .darkAqua)
        case .light:  panel.appearance = NSAppearance(named: .aqua)
        case .system: panel.appearance = nil   // follow system
        }

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let x = f.midX - bannerWidth / 2
            let y = f.minY + 28
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        window = panel
    }

    // Full-screen aesthetic dark alert
    private func showFullScreenAlert(for event: CalendarEvent) {
        guard let screen = NSScreen.main else {
            print("[Forge MeetingReminder] full-screen: no NSScreen.main")
            return
        }

        print("[Forge MeetingReminder] presenting full-screen alert frame=\(screen.frame)")

        let joinShortcut = settingsRef?.binding(for: "joinMeeting").displayString ?? ""
        let bgPath = settingsRef?.reminderBackgroundImagePath

        let alert = FullScreenMeetingAlert(
            event: event,
            joinShortcut: joinShortcut,
            backgroundImagePath: bgPath,
            onJoin:    { [weak self] in self?.handleJoin(event) },
            onSnooze:  { [weak self] mins in self?.handleSnooze(event, minutes: mins) },
            onDismiss: { [weak self] in self?.handleDismiss(event) }
        )

        let hosting = NSHostingController(rootView: alert)
        hosting.view.frame = screen.frame

        let panel = FullScreenMeetingPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.setFrame(screen.frame, display: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = panel
        print("[Forge MeetingReminder] panel ordered front, isVisible=\(panel.isVisible) frame=\(panel.frame)")
    }

    private func hideBanner() {
        window?.orderOut(nil)
        window = nil
        activeEvent = nil
    }

    // MARK: - Actions

    private func handleJoin(_ event: CalendarEvent) {
        if let url = event.meetingURL {
            NSWorkspace.shared.open(url)
        }
        dismissed.insert(event.id)
        hideBanner()
    }

    private func handleSnooze(_ event: CalendarEvent, minutes: Int) {
        snoozedUntil[event.id] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        hideBanner()
    }

    private func handleDismiss(_ event: CalendarEvent) {
        dismissed.insert(event.id)
        hideBanner()
    }

    /// Copy the meeting URL to the clipboard and keep the banner on
    /// screen — the user might still want to Join right after.
    private func handleCopyURL(_ event: CalendarEvent) {
        guard let url = event.meetingURL?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// PATCH the user's RSVP on the Google event. Banner stays on screen
    /// (closing it after RSVP felt jarring — leaving it open lets the
    /// user still Join or Snooze if they answered "Maybe").
    private func handleRSVP(_ event: CalendarEvent,
                            status: GoogleCalendarService.RSVPStatus) {
        guard let routing = event.googleRouting else { return }
        Task {
            do {
                try await GoogleCalendarService.shared.setRSVP(
                    accountEmail: routing.accountEmail,
                    calendarId: routing.calendarId,
                    eventId: routing.eventId,
                    status: status
                )
            } catch {
                print("[Forge MeetingReminder] RSVP failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - NSPanel (non-activating floating banner)

final class MeetingReminderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Full-screen alert panel — needs to become key so Esc dismisses it.
final class FullScreenMeetingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Banner View

struct MeetingReminderBanner: View {
    let event: CalendarEvent
    let joinShortcut: String
    /// Pinned color scheme — comes from the user's Forge theme setting.
    /// `nil` lets the banner follow the system. Needed because the
    /// detached NSPanel host doesn't inherit the main app's environment.
    let forcedScheme: ColorScheme?
    let onJoin: () -> Void
    let onSnooze: (Int) -> Void
    let onDismiss: () -> Void
    let onCopyURL: () -> Void
    let onRSVP: (GoogleCalendarService.RSVPStatus) -> Void

    /// Tracks the optimistic RSVP — updated immediately on click so the
    /// dropdown reflects the new state without waiting for a calendar
    /// re-fetch.
    @State private var localRSVP: String? = nil
    /// Brief "Copied!" affordance after the copy button is clicked.
    @State private var justCopied = false
    /// Toggles the attachment popover. It's a `.popover` rendered above
    /// the banner so opening it doesn't expand the banner itself.
    @State private var showAttachments = false

    var body: some View {
        // Re-renders every 5 seconds so "in N min" stays fresh
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            content(now: ctx.date)
        }
        // Pin the color scheme to the user's chosen theme so dynamic
        // colors (surfaceCard, .primary text) read the right appearance
        // even when the SwiftUI tree lives inside a detached NSPanel.
        .preferredColorScheme(forcedScheme)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let isHappening = now >= event.startDate && now < event.endDate
        let subtitle = timeSubtitle(now: now, isHappening: isHappening)

        HStack(spacing: 10) {
            // 1. Calendar color dot (green-ish like the reference)
            Circle()
                .fill(event.calendarColor)
                .frame(width: 8, height: 8)

            // 2. Title + attendee badge + subtitle.
            //
            // `.layoutPriority(1)` ensures the title section wins width
            // negotiation against the action cluster — without it the
            // cluster (snooze + copy + attachments + Join + RSVP + ×)
            // was claiming most of the row and the title was being
            // truncated to nothing. We also use Forge's explicit
            // dynamic NSColor tokens (`textPrimary` / `textSecondary`)
            // because SwiftUI's `.primary` / `.secondary` semantic
            // colors sometimes resolve to the wrong variant inside an
            // NSPanel host.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if event.confirmedAttendeeCount > 0 {
                        attendeeBadge(count: event.confirmedAttendeeCount)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            .frame(minWidth: 140, alignment: .leading)

            Spacer(minLength: 8)

            // 3. Action cluster — snooze, copy, attachments, join, more, dismiss
            HStack(spacing: 6) {
                snoozeMenu
                copyButton
                if !event.attachments.isEmpty {
                    attachmentBadge
                }
                if event.hasMeetingLink {
                    joinButton(isHappening: isHappening)
                }
                if event.isInvited {
                    rsvpMenu
                }
                dismissButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            // Solid surface — pure white in light mode, near-black in
            // dark mode (matches the user's reference). Uses Forge's
            // adaptive card token so the popover-style frosted-glass
            // look is gone.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ForgeTheme.Colors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.20), radius: 16, y: 6)
    }

    // MARK: - Time subtitle

    private func timeSubtitle(now: Date, isHappening: Bool) -> String {
        if isHappening {
            let mins = Int(max(0, now.timeIntervalSince(event.startDate)) / 60)
            return mins == 0 ? "started just now" : "started \(mins) min ago"
        }
        let mins = max(0, Int(ceil(event.startDate.timeIntervalSince(now) / 60)))
        if mins == 0 { return "starting now" }
        if mins == 1 { return "in 1 min" }
        return "in \(mins) min"
    }

    // MARK: - Sub-views

    private func attendeeBadge(count: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(.secondary)
        .help("\(count) attending")
    }

    /// Compact rounded-square icon button (used by the snooze + copy
    /// affordances) — matches the reference visual.
    private func iconButton(systemName: String,
                            help: String,
                            accent: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(accent ? .white : .secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accent
                              ? ForgeTheme.Colors.accent
                              : Color.black.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var snoozeMenu: some View {
        Menu {
            Button("1 minute")   { onSnooze(1) }
            Button("2 minutes")  { onSnooze(2) }
            Button("5 minutes")  { onSnooze(5) }
            Button("10 minutes") { onSnooze(10) }
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.04))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Remind me again in…")
    }

    private var copyButton: some View {
        iconButton(
            systemName: justCopied ? "checkmark" : "doc.on.doc",
            help: "Copy meeting URL"
        ) {
            onCopyURL()
            // brief check-mark feedback
            withAnimation { justCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation { justCopied = false }
            }
        }
        .opacity(event.hasMeetingLink ? 1 : 0.35)
        .disabled(!event.hasMeetingLink)
    }

    private func joinButton(isHappening: Bool) -> some View {
        Button(action: onJoin) {
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Join")
                    .font(.system(size: 13, weight: .semibold))
                if !joinShortcut.isEmpty {
                    Text(joinShortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.18))
                        )
                        .padding(.leading, 2)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isHappening
                          ? ForgeTheme.Colors.accent
                          : Color(white: 0.15))
            )
        }
        .buttonStyle(.plain)
    }

    /// Dropdown that mutates RSVP on Google. Updates `localRSVP` for
    /// optimistic UI so the menu reflects the new choice immediately.
    private var rsvpMenu: some View {
        let current = localRSVP ?? event.myResponseStatus
        return Menu {
            rsvpItem("Going",         status: .accepted,  current: current)
            rsvpItem("Maybe",         status: .tentative, current: current)
            rsvpItem("Decline",       status: .declined,  current: current)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: rsvpIcon(for: current))
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundColor(rsvpTint(for: current))
            .frame(width: 36, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.04))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change RSVP")
    }

    @ViewBuilder
    private func rsvpItem(_ label: String,
                          status: GoogleCalendarService.RSVPStatus,
                          current: String?) -> some View {
        let isCurrent = current == status.rawValue
        Button {
            localRSVP = status.rawValue
            onRSVP(status)
        } label: {
            HStack {
                Text(label)
                if isCurrent {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func rsvpIcon(for status: String?) -> String {
        switch status {
        case "accepted":  return "checkmark.circle.fill"
        case "tentative": return "questionmark.circle.fill"
        case "declined":  return "xmark.circle.fill"
        default:          return "ellipsis.circle"
        }
    }

    private func rsvpTint(for status: String?) -> Color {
        switch status {
        case "accepted":  return Color(red: 0.16, green: 0.62, blue: 0.35)
        case "tentative": return Color.orange
        case "declined":  return Color.red.opacity(0.75)
        default:          return .secondary
        }
    }

    // MARK: - Attachments

    /// Compact button that shows the FIRST attachment's icon and a small
    /// numeric badge for the total. Tapping toggles a popover with the
    /// full list. The popover is anchored to this button and rendered
    /// ABOVE the banner so opening it has zero impact on the banner's
    /// layout (no width / height shift).
    private var attachmentBadge: some View {
        Button {
            showAttachments.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.04))
                    .frame(width: 30, height: 30)
                    .overlay(
                        AttachmentIconView(attachment: event.attachments[0],
                                           size: 16)
                    )
                // Count pill — only when there are more than 1
                if event.attachments.count > 1 {
                    Text("\(event.attachments.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.black)
                        )
                        .overlay(
                            Capsule().stroke(
                                ForgeTheme.Colors.surfaceCard,
                                lineWidth: 1.5
                            )
                        )
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.plain)
        .help("\(event.attachments.count) attached file\(event.attachments.count == 1 ? "" : "s")")
        .popover(isPresented: $showAttachments, arrowEdge: .bottom) {
            AttachmentList(attachments: event.attachments) {
                // Closing on item-click is intentional: the user has
                // picked something. Otherwise we keep it open until the
                // badge is clicked again (popover's default outside-tap
                // behaviour also closes it, which is the macOS standard).
                showAttachments = false
            }
        }
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 30)
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }
}

// MARK: - Attachment icon + list helpers (shared by floating + fullscreen)

/// Renders the attachment's `iconLink` if Google provided one (typical
/// for Drive / Notion / Figma etc.), otherwise an SF Symbol chosen from
/// the mime-type so we never have a "broken image" placeholder.
struct AttachmentIconView: View {
    let attachment: EventAttachment
    var size: CGFloat = 18

    var body: some View {
        if let url = attachment.iconURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: size, height: size)
                case .failure, .empty:
                    fallback
                @unknown default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(systemName: Self.symbol(for: attachment.mimeType))
            .font(.system(size: size * 0.8, weight: .medium))
            .foregroundColor(.secondary)
            .frame(width: size, height: size)
    }

    private static func symbol(for mime: String?) -> String {
        guard let mime = mime?.lowercased() else { return "doc" }
        if mime.contains("pdf")                     { return "doc.richtext" }
        if mime.contains("spreadsheet")             { return "tablecells" }
        if mime.contains("presentation")            { return "rectangle.on.rectangle" }
        if mime.contains("image")                   { return "photo" }
        if mime.contains("video")                   { return "play.rectangle" }
        if mime.contains("document") || mime.contains("text") { return "doc.text" }
        return "link"
    }
}

/// The expanded attachment list — used in the popover above the floating
/// banner AND inline in the full-screen alert. Each row is a button that
/// opens its `fileURL` in the user's default browser.
struct AttachmentList: View {
    let attachments: [EventAttachment]
    var onItemPicked: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(attachments) { att in
                Button {
                    NSWorkspace.shared.open(att.fileURL)
                    onItemPicked()
                } label: {
                    HStack(spacing: 10) {
                        AttachmentIconView(attachment: att, size: 20)
                        Text(att.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverHighlightButtonStyle())
            }
        }
        .padding(.vertical, 6)
        .frame(width: 280)
    }
}

/// Subtle row-hover background used by `AttachmentList`.
private struct HoverHighlightButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering
                          ? Color.primary.opacity(0.06)
                          : Color.clear)
                    .padding(.horizontal, 6)
            )
            .onHover { hovering = $0 }
    }
}

// MARK: - Full-screen aesthetic alert

struct FullScreenMeetingAlert: View {
    let event: CalendarEvent
    let joinShortcut: String
    let backgroundImagePath: String?
    let onJoin: () -> Void
    let onSnooze: (Int) -> Void
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var pulse = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            content(now: ctx.date)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let isHappening = now >= event.startDate && now < event.endDate
        let toStart = event.startDate.timeIntervalSince(now)
        let timeText = timeStatusText(isHappening: isHappening, toStart: toStart, now: now)

        ZStack {
            // 1. Solid black base (in case anything underneath shows through)
            Color.black

            // 2. Background: user-picked image if present, otherwise the
            // default diagonal cyan-stripe pattern.
            if let path = backgroundImagePath,
               let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .allowsHitTesting(false)
            } else {
                DiagonalStripesBackground()
            }

            // 3. Deep gradient veil — deepens the bottom, eases at top
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.03, blue: 0.04).opacity(0.55),
                    Color.black.opacity(0.70),
                ],
                startPoint: .top, endPoint: .bottom
            )

            // 4. Soft accent radial glow at the top — visual focal point
            RadialGradient(
                colors: [
                    event.calendarColor.opacity(0.28),
                    event.calendarColor.opacity(0.0),
                ],
                center: .top, startRadius: 60, endRadius: 720
            )
            .opacity(pulse ? 0.85 : 0.55)
            .allowsHitTesting(false)

            // 4. Centered content card
            VStack(spacing: 28) {
                Spacer()

                // Status pill
                HStack(spacing: 8) {
                    Circle()
                        .fill(event.calendarColor)
                        .frame(width: 9, height: 9)
                        .shadow(color: event.calendarColor.opacity(0.6), radius: 4)
                    Text(timeText.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

                // Event title — large, breathing room
                Text(event.title)
                    .font(.system(size: 56, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 80)

                // Meta row (calendar + time range)
                HStack(spacing: 18) {
                    metaItem(icon: "calendar", text: event.calendarTitle)
                    Divider().frame(height: 14).background(Color.white.opacity(0.15))
                    metaItem(icon: "clock", text: timeRangeText)
                    if event.attendeeCount > 0 {
                        Divider().frame(height: 14).background(Color.white.opacity(0.15))
                        metaItem(icon: "person.2.fill", text: "\(event.attendeeCount) invited")
                    }
                }
                .foregroundColor(.white.opacity(0.65))

                Spacer().frame(height: 24)

                // Attachments — always expanded in the full-screen alert
                // (the floating banner shows them collapsed behind a
                // badge; here we have room to surface them up-front).
                if !event.attachments.isEmpty {
                    fullScreenAttachmentCard
                }

                // Action cluster
                HStack(spacing: 14) {
                    if event.hasMeetingLink {
                        joinButton
                    }
                    snoozeMenu
                    dismissButton
                }

                Spacer()

                // Footer hint
                Text("Press Esc to dismiss")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.bottom, 28)
            }
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1.0 : 0.98)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the panel
        .ignoresSafeArea()
        .background(
            // Local key handler — ESC dismisses
            KeyEventCatcher(onEsc: onDismiss)
        )
    }

    // MARK: Components

    /// Glassy card listing the event's attachments, shown above the action
    /// cluster on the full-screen alert. Each row opens its link.
    private var fullScreenAttachmentCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Meeting prep", systemImage: "doc.text")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            ForEach(event.attachments) { att in
                Button {
                    NSWorkspace.shared.open(att.fileURL)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.10))
                                .frame(width: 30, height: 30)
                            AttachmentIconView(attachment: att, size: 18)
                        }
                        Text(att.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: 480)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var joinButton: some View {
        Button(action: onJoin) {
            HStack(spacing: 10) {
                Image(systemName: "video.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Join meeting")
                    .font(.system(size: 17, weight: .semibold))
                if !joinShortcut.isEmpty {
                    Text(joinShortcut)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .opacity(0.8)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.15)))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    Color(red: 0.906, green: 0.16, blue: 0.012)
                )
            )
            .shadow(color: Color(red: 0.906, green: 0.16, blue: 0.012).opacity(0.45),
                    radius: 22, y: 8)
        }
        .buttonStyle(.plain)
    }

    private var snoozeMenu: some View {
        Menu {
            Button("1 minute")   { onSnooze(1) }
            Button("2 minutes")  { onSnooze(2) }
            Button("5 minutes")  { onSnooze(5) }
            Button("10 minutes") { onSnooze(10) }
            Divider()
            Button("15 minutes") { onSnooze(15) }
            Button("30 minutes") { onSnooze(30) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Snooze")
                    .font(.system(size: 14, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                Text("Dismiss")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.55))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 13, weight: .medium))
        }
    }

    // MARK: Helpers

    private func timeStatusText(isHappening: Bool, toStart: TimeInterval, now: Date) -> String {
        if isHappening {
            let elapsed = max(0, now.timeIntervalSince(event.startDate))
            let mins = Int(elapsed / 60)
            return mins == 0 ? "Starting now" : "Started \(mins) min ago"
        }
        let mins = max(0, Int(ceil(toStart / 60)))
        if mins == 0 { return "Starting now" }
        if mins == 1 { return "Starting in 1 min" }
        return "Starting in \(mins) min"
    }

    private var timeRangeText: String {
        let f = DateFormatter()
        f.timeStyle = .short
        return "\(f.string(from: event.startDate)) – \(f.string(from: event.endDate))"
    }
}

// MARK: - ESC key catcher (NSView wrapper so the fullscreen alert can be closed)

private struct KeyEventCatcher: NSViewRepresentable {
    let onEsc: () -> Void

    func makeNSView(context: Context) -> _KeyView {
        let v = _KeyView()
        v.onEsc = onEsc
        return v
    }

    func updateNSView(_ nsView: _KeyView, context: Context) {
        nsView.onEsc = onEsc
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
    }
}

private final class _KeyView: NSView {
    var onEsc: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEsc?() } else { super.keyDown(with: event) }
    }
}

// MARK: - Default fullscreen reminder background
//
// Vector recreation of the user-supplied wallpaper — diagonal cyan-edged
// rectangles fanning out from the top-right corner on a black ground.
// Renders at any screen size without pixel artifacts.

struct DiagonalStripesBackground: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                // Stripe pattern: a stack of long, narrow rounded rects, rotated
                // -45° and offset diagonally so they march across the canvas.
                ForEach(0..<12, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.15, green: 0.70, blue: 0.85).opacity(0.55),
                                    Color(red: 0.07, green: 0.35, blue: 0.55).opacity(0.35),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                        // Long narrow stripe — wider than the screen so the
                        // rotated rects extend beyond all edges.
                        .frame(width: geo.size.width * 1.6, height: 56)
                        // Step each stripe diagonally toward the top-right
                        .offset(
                            x: geo.size.width * 0.55 - CGFloat(i) * 72,
                            y: -geo.size.height * 0.40 + CGFloat(i) * 80
                        )
                        .rotationEffect(.degrees(-32))
                        // Slight depth: stripes farther from corner fade
                        .opacity(0.85 - Double(i) * 0.05)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

// MARK: - SwiftUI bridge for NSVisualEffectView (frosted-glass background)

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

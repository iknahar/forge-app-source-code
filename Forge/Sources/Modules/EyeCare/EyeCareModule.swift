import SwiftUI
import AppKit
import Combine

// MARK: - Notifications

extension Notification.Name {
    /// Posted by EyeCareModule when a break starts / ends. Useful for
    /// other modules that want to pause their UI during the break (e.g.
    /// the mouse highlighter).
    static let forgeEyeBreakStarted = Notification.Name("forgeEyeBreakStarted")
    static let forgeEyeBreakEnded   = Notification.Name("forgeEyeBreakEnded")
}

// MARK: - Supporting Types

/// Whether the Short Break duration is expressed in seconds (the
/// classic 20-20-20 rule default) or minutes (Pomodoro style).
enum EyeBreakUnit: String, CaseIterable, Codable, Identifiable {
    case seconds = "Seconds"
    case minutes = "Minutes"
    var id: String { rawValue }
}

/// Sentinel string stored in `tintMonitorName` when the tint should
/// apply to every connected display. Anything else is interpreted as
/// `NSScreen.localizedName` and matched exactly.
let EyeCareTintAllMonitors = "__all__"

/// How long to delay the upcoming break when the user clicks one of
/// the "Trigger after Xm" buttons on the pre-break warning toast.
enum EyeBreakDelay: Int, CaseIterable {
    case fiveMinutes  = 5
    case tenMinutes   = 10
    /// Seconds-equivalent for the timer rewind.
    var seconds: Int { rawValue * 60 }
    var label: String { "Trigger after \(rawValue)m" }
}

/// Duration choices the user can pick from the break overlay's
/// "snooze" menu. `forever` is a soft state — the module's enabled
/// toggle still wins, but until the user re-enables the timer
/// nothing schedules a break.
enum EyeCareSnoozeChoice: String, CaseIterable, Codable, Identifiable {
    case oneHour    = "1 hour"
    case twoHours   = "2 hours"
    case eightHours = "8 hours"
    case oneDay     = "1 day"
    case forever    = "Until I re-enable"
    var id: String { rawValue }

    /// Returns the absolute date the snooze ends. `nil` means
    /// "forever" (or until user re-enables manually).
    func endDate(from now: Date) -> Date? {
        switch self {
        case .oneHour:    return now.addingTimeInterval(3600)
        case .twoHours:   return now.addingTimeInterval(7200)
        case .eightHours: return now.addingTimeInterval(28800)
        case .oneDay:     return now.addingTimeInterval(86400)
        case .forever:    return nil
        }
    }
}

// MARK: - Persisted Config

/// All user-tunable Eye Care state. Snapshot-able + Codable so we can
/// round-trip through JSON without touching live UI state. Lives at
/// `~/Library/Application Support/Forge/eye_care.json`.
private struct EyeCareConfig: Codable {
    var pomodoroMode: Bool = true
    var workMinutes: Int = 20            // Classic 20-20-20 rule default
    var shortBreakValue: Int = 20
    var shortBreakUnit: EyeBreakUnit = .seconds
    var longBreakMinutes: Int = 15
    var longBreakCycles: Int = 4

    var colorTemperatureK: Int = 6500    // Neutral white-point
    var brightnessPercent: Double = 100
    var autoDayNight: Bool = false
    var dayTemperatureK: Int = 6500
    var nightTemperatureK: Int = 4000
    var dayBrightnessPercent: Double = 100
    var nightBrightnessPercent: Double = 80

    /// Which display(s) the tint applies to. `EyeCareTintAllMonitors`
    /// (the default) tints every screen; otherwise this is an
    /// `NSScreen.localizedName` and only that screen gets the
    /// overlay.
    var tintMonitorName: String = EyeCareTintAllMonitors

    /// How many seconds before the break is due the warning toast
    /// appears. Configurable per-user; default 10s gives just
    /// enough runway to discard / postpone without leaving the
    /// banner on screen for ages.
    var prebreakWarningLeadSeconds: Int = 10

    /// Master switch for the pre-break warning toast. When false,
    /// the break overlay fires without any heads-up and the user
    /// can't push it back from a toast button. They can still snooze
    /// from the break overlay itself.
    var prebreakWarningEnabled: Bool = true

    var snoozeUntilEpoch: TimeInterval? = nil
    var snoozeForever: Bool = false
}

// MARK: - Module

/// Eye Care — scheduled micro-breaks (20-20-20 rule by default, or
/// classic Pomodoro) and a screen-tint engine for color temperature
/// + brightness. Modeled after the CareUEyes desktop app.
///
/// Why this is one module instead of two:
///   The user explicitly asked for both surfaces on the same Settings
///   page. The state, persistence, and "is the user actually
///   focusing right now?" logic are also shared (meeting detection,
///   snooze) — splitting would duplicate the bookkeeping.
final class EyeCareModule: ForgeModule, ObservableObject {

    let id          = "eyeCare"
    let name        = "Eye Care"
    let description = "Timed breaks plus warm-tint screen filter to ease eye strain"
    let iconName    = "eye.fill"
    let category: ModuleCategory = .calendar
    // Off by default — break overlays and screen tinting are
    // intrusive enough that users should opt in rather than
    // discover them mid-task. The Settings → Eye Care toggle
    // is the on-ramp; everything else (durations, snooze choices,
    // tint temperature) stays disabled until the master is on.
    var isEnabled: Bool = false

    // MARK: - Persisted (mirrored from EyeCareConfig)

    @Published var pomodoroMode: Bool { didSet { persist() } }
    @Published var workMinutes: Int { didSet { persist() } }
    @Published var shortBreakValue: Int { didSet { persist() } }
    @Published var shortBreakUnit: EyeBreakUnit { didSet { persist() } }
    @Published var longBreakMinutes: Int { didSet { persist() } }
    @Published var longBreakCycles: Int { didSet { persist() } }

    @Published var colorTemperatureK: Int { didSet { persist(); applyTintOverlay() } }
    @Published var brightnessPercent: Double { didSet { persist(); applyTintOverlay() } }
    @Published var autoDayNight: Bool { didSet { persist(); maybeAutoApplyDayNight() } }
    @Published var dayTemperatureK: Int { didSet { persist() } }
    @Published var nightTemperatureK: Int { didSet { persist() } }
    @Published var dayBrightnessPercent: Double { didSet { persist() } }
    @Published var nightBrightnessPercent: Double { didSet { persist() } }
    @Published var tintMonitorName: String { didSet { persist(); applyTintOverlay() } }

    /// User-configurable lead time on the pre-break warning toast.
    /// Lower-bounded by 3s in the UI so the toast actually has a
    /// chance to be read, upper-bounded at 60s so it doesn't sit
    /// on screen forever.
    @Published var prebreakWarningLeadSeconds: Int { didSet { persist() } }

    /// Master toggle for the pre-break warning toast. When false,
    /// breaks fire silently from the work timer with no heads-up.
    @Published var prebreakWarningEnabled: Bool { didSet { persist() } }

    // MARK: - Runtime (not persisted)

    /// Seconds until the next break is due. Counts down from
    /// `workMinutes * 60` (or the active pomodoro chunk).
    @Published var nextBreakInSeconds: Int = 0
    /// Whether the user is currently inside a break window. True
    /// while the break overlay is on screen.
    @Published var isOnBreak: Bool = false
    /// Seconds left in the current break.
    @Published var breakRemainingSeconds: Int = 0
    /// How many short breaks have happened since the last long
    /// break — the Pomodoro cycle counter.
    @Published var completedShortBreaks: Int = 0
    /// Is the timer paused by the user (via the Pause button on the
    /// settings page)?
    @Published var isPaused: Bool = false
    /// Resolved snooze deadline, exposed for the Settings UI to show
    /// "snoozed until …" copy.
    @Published var snoozeUntil: Date? = nil
    @Published var snoozeForever: Bool = false

    /// When non-nil, the pre-break warning toast is on screen and
    /// this is the live countdown the toast paints. Goes nil the
    /// moment the break actually fires (or the user dismisses it).
    @Published var prebreakWarningSeconds: Int? = nil

    // MARK: - Dependencies

    /// Set by AppDelegate after registration so we can ask the
    /// calendar "is there a meeting happening right now?" before
    /// triggering a break.
    weak var calendarRef: CalendarModule?

    // MARK: - Internal

    private var tickTimer: Timer?
    private var tintWindows: [NSWindow] = []
    private var breakWindows: [NSWindow] = []
    private var breakEscapeMonitor: Any?
    private var prebreakToastWindow: NSWindow?
    private var screenChangeObserver: NSObjectProtocol?
    private var didEnterFullScreenObserver: NSObjectProtocol?
    /// `NSWorkspace` + distributed notifications fired when the user
    /// wakes the screen / unlocks. We restart the work timer in
    /// response so a break doesn't fire the instant they sit back
    /// down.
    private var wakeObservers: [NSObjectProtocol] = []

    private let configURL: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("eye_care.json")
    }()

    // MARK: - Init

    init() {
        let loaded = Self.loadConfig(from: Self.configURL)
        self.pomodoroMode          = loaded.pomodoroMode
        self.workMinutes           = loaded.workMinutes
        self.shortBreakValue       = loaded.shortBreakValue
        self.shortBreakUnit        = loaded.shortBreakUnit
        self.longBreakMinutes      = loaded.longBreakMinutes
        self.longBreakCycles       = loaded.longBreakCycles
        self.colorTemperatureK     = loaded.colorTemperatureK
        self.brightnessPercent     = loaded.brightnessPercent
        self.autoDayNight          = loaded.autoDayNight
        self.dayTemperatureK       = loaded.dayTemperatureK
        self.nightTemperatureK     = loaded.nightTemperatureK
        self.dayBrightnessPercent  = loaded.dayBrightnessPercent
        self.nightBrightnessPercent = loaded.nightBrightnessPercent
        self.tintMonitorName       = loaded.tintMonitorName
        self.prebreakWarningLeadSeconds = loaded.prebreakWarningLeadSeconds
        self.prebreakWarningEnabled = loaded.prebreakWarningEnabled
        self.snoozeForever         = loaded.snoozeForever
        if let t = loaded.snoozeUntilEpoch {
            self.snoozeUntil = Date(timeIntervalSince1970: t)
        }
        self.nextBreakInSeconds = workMinutes * 60
    }

    // Static so init can read it before `self` is available.
    private static let configURL: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("eye_care.json")
    }()

    // MARK: - ForgeModule

    func activate() {
        startTickTimer()
        applyTintOverlay()
        maybeAutoApplyDayNight()

        // Re-create overlay windows when the display configuration
        // changes (new monitor plugged in, resolution change, etc.).
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.applyTintOverlay() }

        subscribeToWakeAndUnlockEvents()
    }

    func deactivate() {
        tickTimer?.invalidate(); tickTimer = nil
        removeTintOverlay()
        dismissBreakOverlay(playEndedNotification: false)
        dismissPrebreakToast()
        if let obs = screenChangeObserver { NotificationCenter.default.removeObserver(obs) }
        screenChangeObserver = nil
        unsubscribeFromWakeAndUnlockEvents()
    }

    // MARK: - Wake / Unlock handling

    /// When the user wakes the Mac from sleep or unlocks the screen,
    /// we treat that as the start of a fresh focus session. Reasons:
    ///   • If the timer kept counting during the lock, a break would
    ///     pop the second they sit down — they were AFK, that's not
    ///     useful.
    ///   • Even a few minutes of away time effectively gave the eyes
    ///     a distance-focus rest already.
    /// So: reset the work countdown to a full work period and dump
    /// the Pomodoro short-break counter back to zero.
    private func subscribeToWakeAndUnlockEvents() {
        let ws = NSWorkspace.shared.notificationCenter
        // System / screen wake.
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            let obs = ws.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.restartSessionAfterAwakening() }
            wakeObservers.append(obs)
        }

        // Screen unlock — uses the (undocumented but stable) macOS
        // distributed notification `com.apple.screenIsUnlocked`,
        // which is the only public-ish hook for the lock-screen
        // moment specifically.
        let dnc = DistributedNotificationCenter.default()
        let unlockObs = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.restartSessionAfterAwakening() }
        wakeObservers.append(unlockObs)
    }

    private func unsubscribeFromWakeAndUnlockEvents() {
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        for obs in wakeObservers {
            ws.removeObserver(obs)
            dnc.removeObserver(obs)
        }
        wakeObservers.removeAll()
    }

    private func restartSessionAfterAwakening() {
        // If a break is on-screen when the Mac wakes (rare — the
        // overlay can survive sleep), kill it; the user just got
        // their rest by being away.
        if isOnBreak {
            dismissBreakOverlay(playEndedNotification: false)
            isOnBreak = false
            breakRemainingSeconds = 0
        }
        dismissPrebreakToast()
        completedShortBreaks = 0
        resetWorkTimer()
    }

    // MARK: - Timer / break cycle

    /// Restart the work timer from scratch — called when the user
    /// hits Stop or finishes a break, or when work duration settings
    /// change.
    func resetWorkTimer() {
        nextBreakInSeconds = workMinutes * 60
    }

    /// Jump straight to the break, bypassing the pre-break warning
    /// toast. Used by the cup-icon Skip control on the Settings
    /// page — the user explicitly clicked it, so the heads-up
    /// would be redundant. The warning flow still runs naturally
    /// when the work-period countdown reaches `leadSeconds`.
    func skipToBreak() {
        suppressPrebreakWarningOnce = true
        nextBreakInSeconds = 1
    }

    /// One-shot suppression flag — set by `skipToBreak()` (and by
    /// the "X close warning" button on the toast) so the tick loop
    /// won't re-present the warning toast during the current
    /// pending break. Cleared automatically when the break actually
    /// starts.
    private var suppressPrebreakWarningOnce: Bool = false

    /// Restore every timer-related setting to its factory default
    /// (matching the 20-20-20 baseline shipped in `EyeCareConfig`).
    /// Used by the "Reset to defaults" link beside the Pomodoro
    /// toggle on the Settings page. Doesn't touch the screen-filter
    /// settings — those have their own Reset on the filter card.
    func resetTimerDefaults() {
        let d = EyeCareConfig()
        pomodoroMode             = d.pomodoroMode
        workMinutes              = d.workMinutes
        shortBreakValue          = d.shortBreakValue
        shortBreakUnit           = d.shortBreakUnit
        longBreakMinutes         = d.longBreakMinutes
        longBreakCycles          = d.longBreakCycles
        prebreakWarningLeadSeconds = d.prebreakWarningLeadSeconds
        prebreakWarningEnabled     = d.prebreakWarningEnabled
        resetWorkTimer()
    }

    /// User pressed Pause on the timer card. Halts the countdown
    /// without resetting it.
    func pauseTimer() { isPaused = true }
    func resumeTimer() { isPaused = false }
    func togglePause() { isPaused.toggle() }

    private func startTickTimer() {
        tickTimer?.invalidate()
        // 1s tick drives the break countdown. A 0.2s tolerance still
        // reads as a smooth per-second countdown but lets macOS coalesce
        // the wake-up — worthwhile since this runs continuously while
        // Eye Care is enabled.
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.2
        tickTimer = timer
    }

    private func tick() {
        // If a snooze is active and still in the future, suppress
        // breaks entirely (but keep the tint overlay running — color
        // settings aren't part of the snooze).
        if snoozeForever { return }
        if let until = snoozeUntil, until > Date() { return }
        if snoozeUntil != nil && snoozeUntil! <= Date() {
            // Snooze just ended — clear it and resume.
            snoozeUntil = nil
            persist()
        }

        if isOnBreak {
            breakRemainingSeconds -= 1
            if breakRemainingSeconds <= 0 {
                endBreak()
            }
            return
        }

        if isPaused { return }

        // Skip the countdown entirely while the user is in a meeting.
        // This is permanent behaviour now (no user toggle) — Forge
        // should never push a break in front of a live calendar
        // event. Also hide the warning toast if the meeting started
        // while it was on screen.
        if isInMeeting() {
            if prebreakToastWindow != nil { dismissPrebreakToast() }
            return
        }

        nextBreakInSeconds -= 1

        // Pre-break warning toast — counts down from
        // `prebreakWarningLeadSeconds` to zero, giving the user a
        // chance to push the break out by 5 or 10 minutes, or skip
        // it entirely, before the full-screen overlay slams onto
        // the screen. Gated on:
        //   • The master `prebreakWarningEnabled` toggle.
        //   • The one-shot `suppressPrebreakWarningOnce` flag (set
        //     by Skip-to-Break or by the toast's X close button).
        if prebreakWarningEnabled
            && !suppressPrebreakWarningOnce
            && nextBreakInSeconds > 0
            && nextBreakInSeconds <= prebreakWarningLeadSeconds {
            prebreakWarningSeconds = nextBreakInSeconds
            if prebreakToastWindow == nil {
                presentPrebreakToast()
            }
        }

        if nextBreakInSeconds <= 0 {
            dismissPrebreakToast()
            startBreak()
        }
    }

    /// Is the user currently inside a calendar event? Checked at
    /// every tick so a break that's about to fire gets postponed
    /// rather than crashing into the user's Zoom call.
    private func isInMeeting() -> Bool {
        calendarRef?.ongoingEvent != nil
    }

    // MARK: - Pre-break toast actions
    //
    // Wired to the three buttons on `EyeBreakWarningToastView`:
    //
    //   • Discard: kill the break, restart the work-period countdown
    //     from full so the user effectively gets a clean slate.
    //   • Trigger after Nm: push the break back by N minutes. The
    //     toast vanishes and will pop again at T-20 of the new
    //     deadline.

    /// User chose to skip this break entirely. Roll the timer back
    /// to a full work period.
    func discardUpcomingBreak() {
        dismissPrebreakToast()
        resetWorkTimer()
    }

    /// User asked to push the break out by `delay` minutes.
    func delayUpcomingBreak(_ delay: EyeBreakDelay) {
        dismissPrebreakToast()
        nextBreakInSeconds = delay.seconds
    }

    /// User clicked the X close button on the warning toast: hide
    /// the toast but DON'T touch the timer — the break still fires
    /// at the originally scheduled moment. Sets the one-shot
    /// suppression flag so the tick loop doesn't re-create the
    /// toast on the very next tick.
    func dismissPrebreakWarningOnly() {
        suppressPrebreakWarningOnce = true
        dismissPrebreakToast()
    }

    // MARK: - Break lifecycle

    private func startBreak() {
        let isLong = pomodoroMode
            && completedShortBreaks + 1 >= longBreakCycles
        let durationSeconds: Int = isLong
            ? longBreakMinutes * 60
            : (shortBreakUnit == .minutes ? shortBreakValue * 60 : shortBreakValue)
        breakRemainingSeconds = durationSeconds
        isOnBreak = true
        // The suppression flag was a one-shot — clear it so future
        // breaks get their warning back.
        suppressPrebreakWarningOnce = false
        if !isLong { completedShortBreaks += 1 } else { completedShortBreaks = 0 }
        presentBreakOverlay(totalSeconds: durationSeconds, isLong: isLong)
        NotificationCenter.default.post(name: .forgeEyeBreakStarted, object: self)
    }

    /// Called by the break overlay's Dismiss CTA, or automatically
    /// when the break timer hits zero.
    func endBreak() {
        isOnBreak = false
        breakRemainingSeconds = 0
        dismissBreakOverlay(playEndedNotification: true)
        resetWorkTimer()
    }

    // MARK: - Snooze

    /// Apply a snooze choice picked from the break overlay. Closes
    /// the break and sets a deadline (or marks forever).
    func applySnooze(_ choice: EyeCareSnoozeChoice) {
        if choice == .forever {
            snoozeForever = true
            snoozeUntil = nil
        } else {
            snoozeForever = false
            snoozeUntil = choice.endDate(from: Date())
        }
        persist()
        endBreak()
    }

    /// Manual "I'm back" — clear any snooze and resume counting.
    func clearSnooze() {
        snoozeForever = false
        snoozeUntil = nil
        persist()
    }

    // MARK: - Tint / Brightness Overlay
    //
    // We *simulate* color temperature and brightness with semi-
    // transparent, click-through fullscreen windows rather than
    // touching the actual display gamma table. Two reasons:
    //   1. Gamma-table writes (CGSetDisplayTransferByFormula) require
    //      careful cleanup on quit, can leave the user's screen in a
    //      broken state if the app crashes, and don't compose with
    //      Night Shift cleanly.
    //   2. f.lux / CareUEyes both use the overlay approach, so users
    //      already understand the model.

    private func applyTintOverlay() {
        guard isEnabled else { removeTintOverlay(); return }

        // Anything off neutral (6500K) gets an overlay: warm tint
        // below, cool tint above. Neutral = no overlay windows at
        // all so the user's screen renders untouched.
        let needsTint = colorTemperatureK != 6500
        guard needsTint else { removeTintOverlay(); return }

        // Re-create per-screen overlays from scratch — cheap (a few
        // empty windows) and avoids stale frames after monitor
        // changes.
        removeTintOverlay()

        // Filter the screen list by the user's monitor pick. "All"
        // means every screen; otherwise we apply only to the screen
        // whose `localizedName` matches the persisted value. If the
        // saved name no longer matches any connected screen (cable
        // unplugged, swapped dock, etc.) we silently fall back to
        // "all" so the feature keeps working.
        let screens: [NSScreen]
        if tintMonitorName == EyeCareTintAllMonitors {
            screens = NSScreen.screens
        } else if let match = NSScreen.screens.first(where: { $0.localizedName == tintMonitorName }) {
            screens = [match]
        } else {
            screens = NSScreen.screens
        }

        for screen in screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.hasShadow = false
            window.contentView = NSHostingView(
                rootView: EyeCareTintView(
                    temperatureK: colorTemperatureK,
                    brightnessPercent: brightnessPercent
                )
            )
            window.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
            window.orderFrontRegardless()
            tintWindows.append(window)
        }
    }

    // MARK: - Pre-break Warning Toast (window management)

    private func presentPrebreakToast() {
        guard prebreakToastWindow == nil else { return }
        guard let screen = NSScreen.main else { return }

        // Window dimensions include enough padding around the
        // visible card for the SwiftUI shadow to spill outside the
        // card without getting clipped — without that headroom the
        // shadow looks abruptly cut off. Sized for the compact
        // illustration-on-top layout.
        let toastWidth: CGFloat = 360
        let toastHeight: CGFloat = 240
        let inset: CGFloat = 18
        let origin = NSPoint(
            x: screen.frame.maxX - toastWidth - inset,
            y: screen.frame.maxY - toastHeight - inset
        )
        let rect = NSRect(origin: origin, size: NSSize(width: toastWidth, height: toastHeight))

        let window = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        // `hasShadow = false` — AppKit's window shadow is a hard
        // rectangle that doesn't follow rounded SwiftUI corners,
        // which is what was making the toast look squarish in the
        // screenshot. SwiftUI paints its own shadow inside the
        // hosted view instead.
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: EyeBreakWarningToastView(module: self))
        window.contentView?.frame = NSRect(origin: .zero, size: rect.size)
        window.orderFrontRegardless()
        prebreakToastWindow = window
    }

    private func dismissPrebreakToast() {
        prebreakToastWindow?.orderOut(nil)
        prebreakToastWindow = nil
        prebreakWarningSeconds = nil
    }

    private func removeTintOverlay() {
        for w in tintWindows { w.orderOut(nil) }
        tintWindows.removeAll()
    }

    // MARK: - Break Overlay

    private func presentBreakOverlay(totalSeconds: Int, isLong: Bool) {
        dismissBreakOverlay(playEndedNotification: false)
        for (index, screen) in NSScreen.screens.enumerated() {
            // `OverlayWindow` (vs. bare `NSWindow`) overrides
            // `canBecomeKey` — without that, our SwiftUI buttons on
            // a borderless `.screenSaver`-level window don't reliably
            // receive clicks. The earlier prototype skipped this
            // and that's why the Dismiss CTA looked dead.
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = true
            window.backgroundColor = .black
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.hasShadow = false
            let host = NSHostingView(
                rootView: EyeBreakOverlayView(
                    module: self,
                    isLong: isLong,
                    totalSeconds: totalSeconds
                )
            )
            host.frame = NSRect(origin: .zero, size: screen.frame.size)
            // Resize with the window so the SwiftUI content stays
            // fullscreen if AppKit ever re-lays out the host.
            host.autoresizingMask = [.width, .height]
            window.contentView = host
            // Promote the FIRST screen's window to key so the user
            // can interact with the buttons. Other-screen windows
            // are just visual blackouts; clicks on the active one
            // dismiss across all.
            if index == 0 {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
            breakWindows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)

        // ESC dismisses the break. We use a *local* NSEvent monitor
        // rather than SwiftUI's `.onExitCommand` because the latter
        // has been silently dropping ESC inside this overlay on
        // this macOS version. A local monitor consumes the key
        // event before it reaches any view, so this is bulletproof.
        breakEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 is the virtual key code for the Escape key.
            if event.keyCode == 53 {
                self?.endBreak()
                return nil   // consume
            }
            return event
        }
    }

    private func dismissBreakOverlay(playEndedNotification: Bool) {
        for w in breakWindows { w.orderOut(nil) }
        breakWindows.removeAll()
        if let mon = breakEscapeMonitor {
            NSEvent.removeMonitor(mon)
            breakEscapeMonitor = nil
        }
        if playEndedNotification {
            NotificationCenter.default.post(name: .forgeEyeBreakEnded, object: self)
        }
    }

    // MARK: - Auto Day-Night

    /// Switch between day and night settings if the auto toggle is
    /// on. Day is loosely defined as 07:00–19:00 local time.
    private func maybeAutoApplyDayNight() {
        guard autoDayNight else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 7 && hour < 19 {
            colorTemperatureK = dayTemperatureK
            brightnessPercent = dayBrightnessPercent
        } else {
            colorTemperatureK = nightTemperatureK
            brightnessPercent = nightBrightnessPercent
        }
    }

    // MARK: - Persistence

    private static func loadConfig(from url: URL) -> EyeCareConfig {
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(EyeCareConfig.self, from: data)
        else {
            return EyeCareConfig()
        }
        return decoded
    }

    private func persist() {
        let config = EyeCareConfig(
            pomodoroMode: pomodoroMode,
            workMinutes: workMinutes,
            shortBreakValue: shortBreakValue,
            shortBreakUnit: shortBreakUnit,
            longBreakMinutes: longBreakMinutes,
            longBreakCycles: longBreakCycles,
            colorTemperatureK: colorTemperatureK,
            brightnessPercent: brightnessPercent,
            autoDayNight: autoDayNight,
            dayTemperatureK: dayTemperatureK,
            nightTemperatureK: nightTemperatureK,
            dayBrightnessPercent: dayBrightnessPercent,
            nightBrightnessPercent: nightBrightnessPercent,
            tintMonitorName: tintMonitorName,
            prebreakWarningLeadSeconds: prebreakWarningLeadSeconds,
            prebreakWarningEnabled: prebreakWarningEnabled,
            snoozeUntilEpoch: snoozeUntil?.timeIntervalSince1970,
            snoozeForever: snoozeForever
        )
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configURL)
        }
    }
}

// MARK: - Tint overlay paint

/// The view painted into each per-screen tint window. One of two
/// chromatic overlays paints depending on which side of neutral
/// the user picked:
///   • Below 6500K → warm amber overlay (counteracts blue light).
///   • Above 6500K → cool blue overlay (extra contrast / chillier
///     feel during midday work).
///   • 6500K itself → no overlay (fully transparent).
///
/// Layers are non-interactive (`ignoresMouseEvents` is set on the
/// host NSWindow by `EyeCareModule`). The brightness control was
/// dropped at the user's request; `brightnessPercent` is still
/// accepted by this view for source compatibility but pinned at
/// 100 % everywhere so no dim layer ever paints.
private struct EyeCareTintView: View {
    let temperatureK: Int
    let brightnessPercent: Double

    /// Map kelvin → warm-tint opacity. 6500K is neutral (no
    /// overlay), 2000K is heavy warm. Tuned to feel similar to the
    /// lower settings on f.lux / Night Shift.
    private var warmAlpha: Double {
        let neutral = 6500.0
        let coldest = 2000.0
        let t = max(0, min(1, (neutral - Double(temperatureK)) / (neutral - coldest)))
        return t * 0.42
    }

    /// Map kelvin → cool-tint opacity. 6500K is neutral, 10000K is
    /// heavy cool. The peak alpha is lower than the warm side
    /// because a strong blue overlay tires the eyes faster — the
    /// cool slider is for "I want crisper" rather than a heavy
    /// daylight emulation.
    private var coolAlpha: Double {
        let neutral = 6500.0
        let coolest = 10000.0
        let t = max(0, min(1, (Double(temperatureK) - neutral) / (coolest - neutral)))
        return t * 0.26
    }

    var body: some View {
        ZStack {
            // Warm amber tint — active only when temperatureK <
            // 6500. Opacity 0 above neutral so it costs nothing.
            Color(red: 255/255, green: 170/255, blue: 80/255)
                .opacity(warmAlpha)
            // Cool blue tint — active only when temperatureK >
            // 6500.
            Color(red: 130/255, green: 175/255, blue: 255/255)
                .opacity(coolAlpha)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

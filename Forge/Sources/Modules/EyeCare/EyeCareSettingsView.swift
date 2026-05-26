import SwiftUI
import AppKit

/// The Settings → Eye Care page. Two stacked cards on a single page:
///
///   1. Eye-break timer — slim countdown strip with Pomodoro /
///      20-20-20 configuration directly below.
///   2. Screen filter — color temperature + brightness side by side,
///      monitor selector, and the auto day/night automation block.
///
/// Medical-fact callouts are interleaved with the controls so the
/// page reads as "informed defaults" rather than a list of knobs.
/// Source notes (kept inline as comments only — not surfaced):
///   • 20-20-20 rule: every 20 min, look at something 20 ft away for
///     20 seconds. Originally proposed by Dr. Jeffrey Anshel, widely
///     cited by the American Academy of Ophthalmology.
///   • Blink rate drops from ~15/min to ~5/min while staring at
///     screens (Argilés et al., 2015, IOVS).
///   • Blue-light wavelengths suppress melatonin most strongly in
///     the 460–480nm range (Brainard et al., 2001).
struct EyeCareSettingsView: View {
    @ObservedObject var module: EyeCareModule
    /// Provided by the parent Settings view via `.environmentObject`.
    /// We read + write enable state through the registry rather than
    /// touching `module.isEnabled` directly so the same `activate /
    /// deactivate` plumbing that the Tools-list toggle uses fires
    /// here too — flipping this switch tears down the tint and
    /// break overlays the same way the Tools toggle does.
    @EnvironmentObject var moduleRegistry: ModuleRegistry

    /// Live list of connected screens. We re-fetch each render so
    /// freshly-plugged monitors show up immediately in the dropdown.
    private var availableMonitors: [NSScreen] { NSScreen.screens }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            masterToggleCard
            timerCard
                .disabled(!isEyeCareEnabled)
                .opacity(isEyeCareEnabled ? 1 : 0.45)
            screenFilterCard
                .disabled(!isEyeCareEnabled)
                .opacity(isEyeCareEnabled ? 1 : 0.45)
            medicalFooter
        }
    }

    // MARK: - Card 0 — Master toggle

    /// Sits at the top of the page. The page header above already
    /// reads "Eye Care", so the card itself drops its own title —
    /// only the live status copy + toggle remain, alongside the
    /// icon chip. When off, the timer + screen-filter cards below
    /// fade so users know nothing's running.
    private var masterToggleCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "eye.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ForgeTheme.Colors.accent.opacity(0.12))
                )
            Text(isEyeCareEnabled
                 ? "Breaks scheduled, screen filter armed."
                 : "Everything paused. No breaks, no tint.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(ForgeTheme.Colors.textPrimary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { moduleRegistry.isEnabled(module.id) },
                set: { _ in moduleRegistry.toggleModule(module.id) }
            ))
            .toggleStyle(.forge)
            .labelsHidden()
            .tint(ForgeTheme.Colors.accent)
        }
        .padding(16)
        .background(ForgeTheme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }

    /// Live enable state read from the registry. Keeps the body's
    /// disabled / opacity branches in sync with whatever the master
    /// toggle (or the Tools-list toggle) most recently set.
    private var isEyeCareEnabled: Bool {
        moduleRegistry.isEnabled(module.id)
    }

    // MARK: - Card 1 — Eye-break Timer

    private var timerCard: some View {
        VStack(spacing: 0) {
            // Slim header strip — just the countdown + controls.
            // No big chip, no "Eye #N" — the spec calls for a calm
            // strip rather than a sticker.
            timerHeader

            VStack(alignment: .leading, spacing: 14) {
                medicalCallout(
                    icon: "eye",
                    title: "Why these defaults",
                    body: "The 20-20-20 rule: every 20 minutes of screen work, look at something 20 feet (≈6m) away for 20 seconds. It gives your ciliary muscles a chance to relax from sustained near-focus, which is the dominant cause of Computer Vision Syndrome."
                )

                Divider().opacity(0.3)

                pomodoroToggleRow

                numberRow(
                    label: "Pomodoro",
                    binding: $module.workMinutes,
                    range: 5...90,
                    unit: "Minutes"
                )

                shortBreakRow

                numberRow(
                    label: "Long Break",
                    binding: $module.longBreakMinutes,
                    range: 2...60,
                    unit: "Minutes"
                )

                numberRow(
                    label: "Long Break Cycles",
                    binding: $module.longBreakCycles,
                    range: 2...10,
                    unit: "Pomodoros"
                )

                Divider().opacity(0.3)

                // Pre-break warning master toggle — when off, breaks
                // fire silently with no heads-up toast. When on, the
                // lead-time row below is interactive; when off, it
                // dims so it's obvious the value isn't doing
                // anything.
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pre-break warning")
                            .font(.system(size: 13, weight: .medium))
                        Text("Show a top-right toast before the break so you can postpone or skip it.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $module.prebreakWarningEnabled)
                        .toggleStyle(.forge)
                        .labelsHidden()
                        .tint(ForgeTheme.Colors.accent)
                }

                // Lead-time stepper — disabled + faded when the
                // warning is off, so the row reads as "no effect"
                // rather than a knob you forgot to turn.
                numberRow(
                    label: "Warning lead time",
                    binding: $module.prebreakWarningLeadSeconds,
                    range: 3...60,
                    unit: "Seconds before break"
                )
                .disabled(!module.prebreakWarningEnabled)
                .opacity(module.prebreakWarningEnabled ? 1 : 0.4)
            }
            .padding(20)
        }
        .background(ForgeTheme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }

    private var timerHeader: some View {
        ZStack {
            LinearGradient(
                colors: [
                    ForgeTheme.Colors.accent.opacity(0.95),
                    ForgeTheme.Colors.accent.opacity(0.78),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.isOnBreak ? "ON BREAK" : "NEXT BREAK IN")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.6)
                        .foregroundColor(.white.opacity(0.78))
                    Text(countdownString)
                        .font(.system(size: 30, weight: .light, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                }

                Spacer()

                HStack(spacing: 10) {
                    timerActionButton(
                        systemImage: "cup.and.saucer.fill",
                        label: module.prebreakWarningEnabled
                            ? "Skip to warning (then break)"
                            : "Skip directly to break"
                    ) {
                        // Routes through the module so the cup
                        // icon shows the full warning → countdown
                        // → break sequence when the user has the
                        // pre-break warning enabled (otherwise the
                        // toast briefly flashes and gets eaten by
                        // the break starting at next tick).
                        module.skipToBreak()
                    }

                    Button(action: { module.resetWorkTimer() }) {
                        Text("RESET")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color.white.opacity(0.22))
                            )
                            .overlay(
                                Capsule().stroke(Color.white.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    timerActionButton(
                        systemImage: module.isPaused ? "play.fill" : "pause.fill",
                        label: module.isPaused ? "Resume" : "Pause"
                    ) {
                        module.togglePause()
                    }
                }
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 76)
    }

    private var pomodoroToggleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Pomodoro Technique Mode")
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .help("Classic Pomodoro alternates short breaks with one long break every few cycles. Off = simple 20-20-20 rhythm.")
                }
                Text("Off = pure 20-20-20 (short breaks only).")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            // Small inline "Reset to defaults" link. Resets the
            // mode toggle + every Pomodoro / break duration row
            // below — but leaves the screen filter alone (that
            // card has its own Reset).
            Button(action: { module.resetTimerDefaults() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Reset to defaults")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(ForgeTheme.Colors.accent)
            }
            .buttonStyle(.plain)
            .help("Restore the 20-minute work / 20-second break baseline and four-cycle long-break rhythm.")

            Toggle("", isOn: $module.pomodoroMode)
                .toggleStyle(.forge)
                .labelsHidden()
                .tint(ForgeTheme.Colors.accent)
                .padding(.leading, 8)
        }
    }

    private var shortBreakRow: some View {
        HStack {
            Text("Short Break")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            numberStepper(value: $module.shortBreakValue, range: 5...60)
            // Frame width matches the unit-text column in
            // `numberRow` (170pt). With leading alignment, the
            // picker sits flush left in its column, which means
            // the stepper's right edge — and therefore the `-`
            // button's x position — lines up with every other
            // row above and below this one.
            Picker("", selection: $module.shortBreakUnit) {
                ForEach(EyeBreakUnit.allCases) { unit in
                    Text(unit.rawValue).tag(unit)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 170, alignment: .leading)
        }
    }

    // MARK: - Card 2 — Screen filter

    private var screenFilterCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Filter")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Warm overlay + dimming. Click-through, so it doesn't fight any window.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: resetToNeutral) {
                    HStack(spacing: 4) {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 11))
                        Text("Reset")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(ForgeTheme.Colors.accent)
                }
                .buttonStyle(.plain)
            }

            monitorPicker

            // Single full-width color-temperature slider — warm
            // through neutral through cool. The brightness slider
            // was removed at the user's request; brightness stays
            // pinned at 100 % internally so no dim overlay paints.
            colorTempSlider

            Divider().opacity(0.3)

            // Explicit HStack so the toggle sits flush against the
            // card's right padding, matching the master toggle
            // card above. `Toggle(isOn:) { label }` auto-aligns
            // but the label closure ends up indented; this
            // structure gives us proper flex-space-between.
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto day & night")
                        .font(.system(size: 13, weight: .medium))
                    Text("Switch the temperature automatically — warmer at night to limit blue light (460–480 nm wavelengths suppress melatonin most).")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $module.autoDayNight)
                    .toggleStyle(.forge)
                    .labelsHidden()
                    .tint(ForgeTheme.Colors.accent)
            }

            if module.autoDayNight {
                dayNightSubControls
            }
        }
        .padding(20)
        .background(ForgeTheme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }

    /// Monitor selector. Always shows "All monitors" plus one entry
    /// per connected `NSScreen`. With a single display the user just
    /// sees "All monitors" + that one screen — same UI no matter how
    /// many displays are attached.
    private var monitorPicker: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Apply to")
                    .font(.system(size: 12, weight: .medium))
            }
            Spacer()
            Picker("", selection: $module.tintMonitorName) {
                Text("All monitors").tag(EyeCareTintAllMonitors)
                ForEach(Array(availableMonitors.enumerated()), id: \.element.localizedName) {
                    (index, screen) in
                    Text("Monitor \(index + 1) — \(screen.localizedName)")
                        .tag(screen.localizedName)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 260)
        }
    }

    private var colorTempSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Color temperature")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(module.colorTemperatureK) K")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(ForgeTheme.Colors.accent)
            }
            // Range now spans both ends. Below 6500K paints a warm
            // amber overlay; above 6500K paints a cool blue
            // overlay; 6500K itself is neutral (no overlay).
            Slider(
                value: Binding(
                    get: { Double(module.colorTemperatureK) },
                    set: { module.colorTemperatureK = Int($0) }
                ),
                in: 2500...10000,
                step: 100
            )
            .tint(ForgeTheme.Colors.accent)
            HStack {
                Text("Warm")
                Spacer()
                Text("Neutral")
                Spacer()
                Text("Cool")
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }
    }

    /// Day-then-Night blocks for the auto-toggle automation. The
    /// two blocks each sit in their own card with a real vertical
    /// gap between them, so a quick scan separates "what happens
    /// during the day" from "what happens at night" without the
    /// user having to read the headings.
    private var dayNightSubControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            dayNightBlock(
                title: "Day",
                window: "07:00 – 19:00",
                kelvinBinding: Binding(
                    get: { Double(module.dayTemperatureK) },
                    set: { module.dayTemperatureK = Int($0) }
                )
            )
            dayNightBlock(
                title: "Night",
                window: "19:00 – 07:00",
                kelvinBinding: Binding(
                    get: { Double(module.nightTemperatureK) },
                    set: { module.nightTemperatureK = Int($0) }
                )
            )
        }
    }

    private func dayNightBlock(
        title: String,
        window: String,
        kelvinBinding: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(window)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            // Warmth-only slider — brightness was dropped. Range
            // spans the full warm→cool spectrum like the main
            // color-temperature slider above.
            miniSlider(
                label: "Temperature",
                value: kelvinBinding,
                range: 2500...10000,
                unit: " K"
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(ForgeTheme.Colors.surfaceHover.opacity(0.55))
        )
    }

    // MARK: - Footer with medical facts

    private var medicalFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHY EYE CARE")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.2)
                .foregroundColor(.secondary)
            Text("Your blink rate drops from ~15 per minute to ~5 per minute while staring at a screen. Reduced blinks → less tear-film coverage → dry-eye symptoms by hour two. Micro-breaks reset both the blink reflex and the ciliary muscles that bend your lens for near focus. Breaks are automatically suppressed while a calendar event is active, so Forge never pushes a full-screen break in front of a Zoom call.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - Building blocks

    private func medicalCallout(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.accent)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(body)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ForgeTheme.Colors.accent.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ForgeTheme.Colors.accent.opacity(0.18), lineWidth: 1)
        )
    }

    private func numberRow(
        label: String,
        binding: Binding<Int>,
        range: ClosedRange<Int>,
        unit: String
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            numberStepper(value: binding, range: range)
            // 170pt is enough to fit "Seconds before break" without
            // ellipsis at the medium 12pt size. Wider than the
            // initial 110pt that was cutting it off.
            Text(unit)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 170, alignment: .leading)
        }
    }

    /// Number entry with both keyboard typing and click-stepper
    /// affordances. The center is a real `TextField` bound through a
    /// clamping projection (out-of-range entries are clamped on
    /// commit so you can't, say, type 500 into the long-break-cycles
    /// field). The +/- buttons remain for mouse-only adjustment.
    private func numberStepper(value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        // Out-of-range typed values are clamped on commit. Setting a
        // bridge `String` binding instead of binding directly to the
        // formatter lets us swallow garbage characters and avoid the
        // formatter eating the field's focus when you delete the
        // last digit.
        let clamped = Binding<Int>(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
        return HStack(spacing: 6) {
            Button(action: { clamped.wrappedValue = clamped.wrappedValue - 1 }) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(ForgeTheme.Colors.surfaceHover))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            TextField("", value: clamped, formatter: Self.integerFormatter)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(ForgeTheme.Colors.accent)
                .frame(width: 40, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(ForgeTheme.Colors.surfaceHover.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
                )

            Button(action: { clamped.wrappedValue = clamped.wrappedValue + 1 }) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(ForgeTheme.Colors.surfaceHover))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// Static integer-only formatter — created once and reused for
    /// every number field so each row doesn't have to spin up its
    /// own NumberFormatter instance.
    private static let integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.allowsFloats = false
        f.minimum = 0
        return f
    }()

    private func miniSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(ForgeTheme.Colors.accent)
            }
            Slider(value: value, in: range, step: 1)
                .tint(ForgeTheme.Colors.accent)
        }
    }

    private func timerActionButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func resetToNeutral() {
        // Neutral = no overlay, no tint, no dim. Brightness was
        // dropped from the UI but we keep it pinned at 100 % under
        // the hood to make sure no dim layer paints.
        module.colorTemperatureK = 6500
        module.brightnessPercent = 100
    }

    // MARK: - Formatting

    private var countdownString: String {
        let total = module.isOnBreak
            ? module.breakRemainingSeconds
            : module.nextBreakInSeconds
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

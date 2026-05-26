import SwiftUI

/// Full-screen overlay shown during an eye-break. Recreates the
/// "concentric rounded-rect ring field" wallpaper from the design
/// reference: a dense set of stadium shapes nested around a hot
/// point on the right edge, stroked in a violet → vermilion
/// gradient against pure black.
///
/// Above the wallpaper sits the actual UX:
///   • A reminder of why we're here (a single medical fact, rotated
///     each break so the user actually reads them over time).
///   • The countdown to "Break ends".
///   • The 20-20-20 reminder ("look 20 feet away") + don't-touch-
///     your-phone nudge.
///   • A Dismiss CTA + a Snooze popup (1h / 2h / 8h / 1d / Forever).
struct EyeBreakOverlayView: View {
    @ObservedObject var module: EyeCareModule
    let isLong: Bool
    let totalSeconds: Int

    @State private var snoozeMenuOpen = false

    var body: some View {
        // Same shape as the debug body that DID render: a ZStack
        // with `Color.black` + the rings + a centered content
        // group. Rebuilt to be as flat as possible — no Spacers,
        // no computed view properties returning `some View`, no
        // nested VStacks calling private helpers — because every
        // previous attempt added another layer that SwiftUI was
        // silently choking on. All the content lives inline below.
        ZStack {
            Color.black.ignoresSafeArea()

            // Decorative ring wallpaper back behind the content.
            // Now that the content is flat-inlined and known to
            // render, the rings can sit alongside it as a sibling
            // ZStack layer without the previous "invisible
            // content" symptom.
            BreakRingField().ignoresSafeArea()

            // Content stack. Kept deliberately flat — each row is
            // inline (no computed-property helpers, no nested
            // VStacks, no Spacers). Type sizes bumped up overall,
            // `.serif` design + `.italic()` on the editorial-style
            // pieces to match the landing page's Instrument-Serif
            // headline treatment.
            VStack(spacing: 28) {
                Text(isLong ? "LONG BREAK" : "EYE BREAK")
                    .font(.system(size: 14, weight: .heavy))
                    .tracking(4)
                    .foregroundColor(.white.opacity(0.75))

                Text(countdownString)
                    .font(.system(size: 124, weight: .light, design: .serif))
                    .italic()
                    .foregroundColor(.white)
                    .monospacedDigit()

                Text("Look at something at least 20 feet (≈6 m) away for the full break. Don't reach for your phone — that's the same near distance your eyes were just on.")
                    .font(.system(size: 20, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 620)

                Text("Blink rate drops from ~15/min to ~5/min while staring at a screen. Distance focus relaxes the ciliary muscle and resets the tear film.")
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .italic()
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 540)

                // Brand-red CTA. Accent background, white text —
                // matches the Download button on the landing page.
                Button(action: { module.endBreak() }) {
                    Text("I'm back — dismiss")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 30)
                        .padding(.vertical, 13)
                        .background(
                            Capsule().fill(ForgeTheme.Colors.accent)
                        )
                        .foregroundColor(.white)
                        .shadow(
                            color: ForgeTheme.Colors.accent.opacity(0.45),
                            radius: 18,
                            x: 0, y: 6
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .padding(.top, 8)

                Text("Or disable eye-care breaks for…")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.top, 2)

                HStack(spacing: 8) {
                    ForEach(EyeCareSnoozeChoice.allCases) { choice in
                        SnoozePill(label: shortSnoozeLabel(for: choice)) {
                            module.applySnooze(choice)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Sub-views

    private var medicalFactCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
            Text(rotatingFact)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .leading)
        }
    }

    private var actionRow: some View {
        VStack(spacing: 18) {
            // Primary CTA. White-on-dark so it pops against the
            // black overlay. Return key dismisses for keyboard
            // users.
            Button(action: { module.endBreak() }) {
                Text("I'm back — dismiss")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 30)
                    .padding(.vertical, 14)
                    .background(
                        Capsule().fill(Color.white)
                    )
                    .foregroundColor(.black)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])

            // Snooze row. Five inline pills instead of a hidden Menu
            // — on a `.screenSaver`-level fullscreen window the
            // SwiftUI Menu sometimes refuses to anchor / open, and
            // anyway the spec calls for the options to be visible
            // and pickable in one click.
            VStack(spacing: 8) {
                Text("Or disable eye-care breaks for…")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(.white.opacity(0.55))

                HStack(spacing: 8) {
                    ForEach(EyeCareSnoozeChoice.allCases) { choice in
                        SnoozePill(label: shortSnoozeLabel(for: choice)) {
                            module.applySnooze(choice)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Copy

    /// Big italic tip line. Rotated by the current second-of-day so a
    /// long stretch of breaks doesn't show the same string back-to-back.
    private var rotatingTip: String {
        let tips = [
            "Look at something at least 20 feet (≈6 m) away. Hold your gaze there for the full break.",
            "Stand up. Walk to the window. Let your eyes scan the horizon — far focus is the rest.",
            "Put your phone down. It's the same depth your eyes were just on. The break only works on distant focus.",
            "Roll your shoulders, tilt your head side to side. Eye strain rides on neck tension.",
            "Blink slowly, 10 times. Conscious blinks spread the tear film and reset dry-eye.",
            "Look up, then down, then far left, then far right. Slow circles. The extraocular muscles need range.",
            "Pour a glass of water. Hydration affects tear production more than people expect.",
            "Palming: rub your palms warm, cup them lightly over your closed eyes. Total darkness for 20 seconds.",
        ]
        let idx = Int(Date().timeIntervalSince1970) / max(totalSeconds, 1) % tips.count
        return tips[idx]
    }

    /// Small medical citation under the tip — varies less often so a
    /// short break shows a coherent thought rather than blinking
    /// through three different studies.
    private var rotatingFact: String {
        let facts = [
            "Sustained near-focus over hours fatigues the ciliary muscle of the eye. Distance focus during breaks lets it relax.",
            "Children and adults who spend more time on near work (screens, reading) show higher rates of progressive myopia — outdoor time is protective.",
            "Blue light around 460–480 nm is the most potent suppressor of melatonin. Warmer screens after sunset help your sleep.",
            "Digital Eye Strain (a.k.a. Computer Vision Syndrome) affects an estimated 50–90% of computer workers. Most of it is mechanical, not optical — it responds to micro-breaks.",
            "Your tear film evaporates roughly 4× faster when blink rate drops. The 20-20-20 rule was designed against exactly this.",
        ]
        let idx = Int(Date().timeIntervalSince1970 / 60) % facts.count
        return facts[idx]
    }

    /// Short labels that fit on the inline snooze pills. The full
    /// "until I re-enable Eye Care" copy lives in the help tooltip.
    private func shortSnoozeLabel(for choice: EyeCareSnoozeChoice) -> String {
        switch choice {
        case .oneHour:    return "1 hour"
        case .twoHours:   return "2 hours"
        case .eightHours: return "8 hours"
        case .oneDay:     return "1 day"
        case .forever:    return "Forever"
        }
    }

    private var countdownString: String {
        let remaining = max(0, module.breakRemainingSeconds)
        let m = remaining / 60
        let s = remaining % 60
        if remaining >= 60 {
            return String(format: "%02d:%02d", m, s)
        }
        return String(format: "0:%02d", s)
    }
}

// MARK: - Decorative ring field

/// A series of concentric rounded-rectangle (stadium) strokes,
/// shrinking as they spiral toward an off-center "hot point" near the
/// right edge of the screen — the same geometric vibe as the user's
/// reference wallpaper. Stroke color interpolates along a cool-violet
/// (outer rings) to warm-vermilion (inner rings) gradient, applied
/// top-leading → bottom-trailing on each ring so the bottom half of
/// each ring reads warmer than the top half.
struct BreakRingField: View {
    /// Number of nested rings. Tuned to look dense but not noisy at
    /// typical retina sizes.
    private let ringCount = 24

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<ringCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 500, style: .continuous)
                        .stroke(ringGradient(for: i), lineWidth: 0.7)
                        .opacity(0.85)
                        .frame(
                            width: ringWidth(for: i, in: geo.size),
                            height: ringHeight(for: i, in: geo.size)
                        )
                        .position(
                            x: ringCenterX(for: i, in: geo.size),
                            y: geo.size.height * 0.5
                        )
                }
            }
        }
        // No `.drawingGroup()` here — combining Metal compositing
        // with a sibling content layer occasionally inverts the
        // expected paint order on macOS Sonoma+. 24 static strokes
        // render fine without it.
        .allowsHitTesting(false)
    }

    // Linear interpolation from outer (i=0) to inner (i=last). Each
    // ring is sized + positioned to converge toward a hot point at
    // ~95% of the screen width.

    private func t(for i: Int) -> CGFloat {
        CGFloat(i) / CGFloat(max(1, ringCount - 1))
    }

    private func ringWidth(for i: Int, in size: CGSize) -> CGFloat {
        let outer = size.width * 1.30
        let inner = size.width * 0.04
        return outer + (inner - outer) * t(for: i)
    }

    private func ringHeight(for i: Int, in size: CGSize) -> CGFloat {
        let outer = size.height * 1.95
        let inner = size.height * 0.06
        return outer + (inner - outer) * t(for: i)
    }

    private func ringCenterX(for i: Int, in size: CGSize) -> CGFloat {
        // Outer rings centered on screen; inner rings creep right
        // toward the hot point at ~95% of the width.
        let outer = size.width * 0.50
        let inner = size.width * 0.95
        return outer + (inner - outer) * t(for: i)
    }

    private func ringGradient(for i: Int) -> LinearGradient {
        let f = Double(t(for: i))   // 0..1 outer→inner
        // Outer rings are violet/blue, inner rings warm vermilion.
        let topColor = Color(
            red:   0.34 + 0.50 * f,
            green: 0.18 + 0.05 * f,
            blue:  0.62 - 0.50 * f
        )
        let bottomColor = Color(
            red:   0.92,
            green: 0.20 + 0.02 * (1 - f),
            blue:  0.12 + 0.08 * (1 - f)
        )
        return LinearGradient(
            colors: [topColor, bottomColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Snooze pill

/// Inline pill used for the five snooze choices on the break
/// overlay. Lives in its own struct so each pill keeps its own
/// hover state. Uses tap + hover gestures rather than a SwiftUI
/// `Button`, matching the scroll-safe pattern used in the menu-bar
/// popover Tools list.
private struct SnoozePill: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(hovering ? .white : .white.opacity(0.8))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Color.white.opacity(hovering ? 0.18 : 0.08))
            )
            .overlay(
                Capsule().stroke(
                    Color.white.opacity(hovering ? 0.55 : 0.25),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

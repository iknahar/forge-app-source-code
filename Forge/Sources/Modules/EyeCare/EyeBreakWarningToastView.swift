import SwiftUI

/// Floating banner shown `prebreakWarningLeadSeconds` before an eye
/// break (default 10s). Compact, illustration-led layout:
///
///   ┌────────────────────────────────┐
///   │                            ×  │
///   │       [ illustration ]         │
///   │     Eye rest is due in 10s    │
///   │ ┌────────────────────────────┐ │
///   │ │  Dismiss the break  (RED) │ │
///   │ └────────────────────────────┘ │
///   │ ─────────────────────────────  │
///   │           Snooze for           │
///   │  ┌─────────┐  ┌─────────┐      │
///   │  │ +5 min  │  │ +10 min │      │
///   │  └─────────┘  └─────────┘      │
///   └────────────────────────────────┘
///
/// • The × close hides the toast but lets the break fire on
///   schedule.
/// • "Dismiss the break" cancels this break, resetting the work
///   timer.
/// • Snooze +5 / +10 push the break back by that many minutes.
struct EyeBreakWarningToastView: View {
    @ObservedObject var module: EyeCareModule
    @State private var closeHovering = false

    var body: some View {
        VStack(spacing: 0) {
            card
        }
        .padding(10)
    }

    private var card: some View {
        VStack(spacing: 10) {
            illustration

            // Countdown headline — now lives BELOW the illustration
            // with no preceding eye glyph (the illustration already
            // carries that semantic).
            Text(headlineText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.textPrimary)
                .lineLimit(1)

            ToastButtonPrimary(label: "Dismiss the break") {
                module.discardUpcomingBreak()
            }

            Divider()
                .padding(.vertical, 2)
                .opacity(0.45)

            Text("Snooze for")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                ToastButtonSecondary(label: "+5 min") {
                    module.delayUpcomingBreak(.fiveMinutes)
                }
                ToastButtonSecondary(label: "+10 min") {
                    module.delayUpcomingBreak(.tenMinutes)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ForgeTheme.Colors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ForgeTheme.Colors.borderDefault.opacity(0.6), lineWidth: 1)
        )
        // × close button overlay — top-right corner. Using an
        // overlay rather than a sibling row lets the rest of the
        // content stay vertically centered in the card without a
        // header taking up its own row.
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
        // Two-layer shadow that follows the rounded corners.
        .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    }

    // MARK: - Sub-views

    private var closeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(
                closeHovering
                    ? ForgeTheme.Colors.textPrimary
                    : ForgeTheme.Colors.textTertiary
            )
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(
                    closeHovering ? ForgeTheme.Colors.surfaceHover : Color.clear
                )
            )
            .contentShape(Circle())
            .onHover { closeHovering = $0 }
            .onTapGesture { module.dismissPrebreakWarningOnly() }
            .help("Hide this warning. The break will still happen.")
    }

    /// Compact illustration disc — 44pt, tuned to feel like a
    /// supporting glyph rather than the dominant element on the
    /// card.
    private var illustration: some View {
        ZStack {
            Circle()
                .fill(ForgeTheme.Colors.accent.opacity(0.14))
                .blur(radius: 10)
                .frame(width: 60, height: 60)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            ForgeTheme.Colors.accent.opacity(0.22),
                            ForgeTheme.Colors.accent.opacity(0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .overlay(
                    Circle().stroke(
                        ForgeTheme.Colors.accent.opacity(0.18),
                        lineWidth: 1
                    )
                )

            Image(systemName: "eye.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(ForgeTheme.Colors.accent)

            // Tiny rest motif offset to upper-right of the disc.
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.accent.opacity(0.85))
                .offset(x: 18, y: -14)
        }
        .frame(height: 60)
    }

    private var headlineText: String {
        let remaining = module.prebreakWarningSeconds ?? 0
        return "Eye rest is due in \(remaining)s"
    }
}

// MARK: - Button styles

/// Primary toast button — brand red, full-width, white text. Used
/// for the destructive "Dismiss the break" action.
private struct ToastButtonPrimary: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            Capsule().fill(ForgeTheme.Colors.accent)
        )
        .overlay(
            Capsule().fill(Color.black.opacity(hovering ? 0.12 : 0))
        )
        .shadow(
            color: ForgeTheme.Colors.accent.opacity(0.4),
            radius: 10, x: 0, y: 4
        )
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Secondary toast button — neutral pill for the postpone actions.
private struct ToastButtonSecondary: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(
            Capsule().fill(
                hovering
                    ? ForgeTheme.Colors.accent.opacity(0.12)
                    : ForgeTheme.Colors.surfaceHover
            )
        )
        .overlay(
            Capsule().stroke(
                hovering
                    ? ForgeTheme.Colors.accent.opacity(0.55)
                    : ForgeTheme.Colors.borderDefault,
                lineWidth: 1
            )
        )
        .foregroundColor(
            hovering ? ForgeTheme.Colors.accent : ForgeTheme.Colors.textPrimary
        )
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

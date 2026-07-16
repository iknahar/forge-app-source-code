import SwiftUI
import AppKit

/// Full-screen PIN prompt shown either over a locked app's windows
/// (per-app overlay) or standalone when the user triggers the
/// unlock shortcut without a specific app in focus. Both cases
/// share the same view — only the `title` and `onSuccess` differ.
///
/// The overlay sits at `.screenSaver` window level, so it stays on
/// top of the target app's windows and blocks clicks + keystrokes
/// from reaching them. The app process itself is never suspended
/// — notifications, syncing, badge counts keep flowing.
struct AppLockOverlayView: View {
    @ObservedObject var module: AppLockModule
    /// App display name for per-app overlays, or "Locked" for the
    /// floating unlock window.
    let title: String
    /// Called after `module.verify` returns true. Per-app overlays
    /// use this to tear down their specific window; the floating
    /// unlock window ignores it (verify itself handles teardown).
    let onSuccess: () -> Void
    /// Non-nil on per-app overlays: hides the locked app (its
    /// windows disappear, process keeps running so notifications
    /// still arrive) and dismisses this overlay. Nil on the
    /// floating unlock window — there's no specific app to hide.
    let onMinimize: (() -> Void)?

    @State private var pin: String = ""
    @State private var shake: Bool = false
    @State private var errorMessage: String? = nil
    @FocusState private var pinFocused: Bool

    /// Four-digit PIN — mainstream expectation (iOS lock, ATM, door
    /// keypads). Auto-submits on the fourth digit; no Enter button
    /// by design.
    private let pinLength = 4

    var body: some View {
        ZStack {
            // Lighter backdrop than before (0.55 → 0.35) so the
            // locked app's own window frame + traffic lights show
            // through — the user can still see *what* is behind
            // the lock, and orient themselves in Mission Control
            // / Cmd+Tab.
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                heroImage

                VStack(spacing: 8) {
                    Text("I know what you are trying to do")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    Text("\(title) is locked.")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                }

                pinDots
                    .modifier(ShakeModifier(shake: shake))

                if let msg = errorMessage {
                    Text(msg)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "#FCA5A5"))
                        .transition(.opacity)
                }

                // Minimize CTA — hides the locked app (windows off
                // screen, process still running so DMs / badges
                // keep flowing) and drops this overlay. User can
                // bring the app back later via Dock click, at
                // which point the lock re-engages.
                if let onMinimize = onMinimize {
                    Button(action: onMinimize) {
                        Label("Minimize \(title)", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color.white.opacity(0.1))
                            )
                            .overlay(
                                Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                hiddenPINField
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 34)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(hex: "#1C1917"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 12)
            )
            .frame(width: 440)
        }
        .onAppear { pinFocused = true }
        .onChange(of: pin) { newValue in
            let digits = newValue.filter { $0.isNumber }
            if digits != newValue {
                pin = String(digits.prefix(pinLength))
                return
            }
            if newValue.count > pinLength {
                pin = String(newValue.prefix(pinLength))
                return
            }
            errorMessage = nil
            if newValue.count == pinLength { submit() }
        }
    }

    /// User-supplied hero image (red hoodie + neon mask). Bundled at
    /// `Assets.xcassets/AppLockHero.imageset/AppLockHero.png`. Falls
    /// back to the system lock glyph if the asset isn't present yet.
    private var heroImage: some View {
        Group {
            if let nsImage = NSImage(named: "AppLockHero") {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 320, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 320, height: 200)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
        }
    }

    private var pinDots: some View {
        HStack(spacing: 18) {
            ForEach(0..<pinLength, id: \.self) { idx in
                let filled = idx < pin.count
                Circle()
                    .stroke(Color.white.opacity(filled ? 0 : 0.35), lineWidth: 1.5)
                    .background(Circle().fill(filled ? Color.white : Color.clear))
                    .frame(width: 18, height: 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: filled)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { pinFocused = true }
    }

    /// Offscreen editable SecureField that drives the model — the
    /// dot row above is purely display.
    private var hiddenPINField: some View {
        SecureField("", text: $pin)
            .textFieldStyle(.plain)
            .focused($pinFocused)
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityLabel("PIN")
            .onSubmit { submit() }
    }

    private func submit() {
        let ok = module.verify(pin: pin)
        if ok {
            onSuccess()
        } else {
            withAnimation(.default) { shake.toggle() }
            errorMessage = "Wrong PIN."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pin = ""
                pinFocused = true
            }
        }
    }
}

// MARK: - Shake

private struct ShakeModifier: GeometryEffect {
    var amount: CGFloat = 8
    var shakesPerUnit = CGFloat(3)
    var animatableData: CGFloat

    init(shake: Bool) {
        self.animatableData = shake ? 1 : 0
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amount * sin(animatableData * .pi * shakesPerUnit * 2)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

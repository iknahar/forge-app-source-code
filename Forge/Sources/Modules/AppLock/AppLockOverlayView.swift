import SwiftUI
import AppKit

/// Full-screen biometric lock overlay. Sits at `.modalPanel` level
/// so system UI (menu bar, dock) stays reachable while the locked
/// app is covered. The lock process itself is never suspended —
/// notifications, badge counts, syncing all keep flowing.
///
/// UI is deliberately spartan: hero image, subtitle, tappable
/// fingerprint glyph. No PIN dots, no keyboard input — everything
/// funnels through `LAContext` and the injected `authenticate`
/// closure.
struct AppLockOverlayView: View {
    @ObservedObject var module: AppLockModule
    /// App display name for per-app overlays, or "Locked" for the
    /// floating unlock window.
    let title: String
    /// Kicks off the system biometric prompt. Callback fires with
    /// the outcome; caller (module) handles disarm + teardown on
    /// success.
    let authenticate: (@escaping (Bool) -> Void) -> Void
    /// Non-nil on per-app overlays: hides the locked app (windows
    /// off screen, process keeps running so notifications still
    /// arrive) and dismisses this overlay. Nil on the floating
    /// unlock window.
    let onMinimize: (() -> Void)?

    @State private var shake: Bool = false
    /// Set on cancel/fail so we know to prompt with a mildly
    /// louder retry cue.
    @State private var lastAttemptFailed: Bool = false

    var body: some View {
        ZStack {
            // Lighter dim so the locked app's window frame + traffic
            // lights show through. User can still orient themselves
            // via Cmd+Tab / Mission Control.
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                heroImage

                Text("\(title) is locked.")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.75))

                fingerprintGlyph
                    .modifier(ShakeModifier(shake: shake))

                if lastAttemptFailed {
                    Text("Tap to try again")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                        .transition(.opacity)
                }

                if let onMinimize = onMinimize {
                    Button(action: onMinimize) {
                        Label("Minimize \(title)", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
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
        .onAppear { runAuth() }
    }

    /// User-supplied hero image (masked figure). Bundled at
    /// `Assets.xcassets/AppLockHero.imageset/AppLockHero.png`.
    /// Falls back to a system lock glyph if the asset is missing.
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

    private var fingerprintGlyph: some View {
        Button(action: runAuth) {
            Image(systemName: "touchid")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Tap for Touch ID")
    }

    private func runAuth() {
        authenticate { ok in
            if !ok {
                withAnimation(.default) { shake.toggle() }
                lastAttemptFailed = true
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

import SwiftUI

// MARK: - Confetti Celebration
//
// A lightweight particle system that bursts colourful confetti shapes
// from a central point. Used to celebrate small wins throughout the
// day — last meeting ending, focus-time goals, clipboard clear, etc.
//
// Usage:
//   .overlay(ConfettiOverlay(trigger: $showConfetti))
//
// Trigger it by toggling the binding to `true`; the view auto-resets
// it after the animation completes so it can fire again later.

/// Overlay modifier — attach to any view and toggle `trigger` to fire.
struct ConfettiOverlay: View {
    @Binding var trigger: Bool

    var body: some View {
        ZStack {
            if trigger {
                ConfettiBurst()
                    .onAppear {
                        // Auto-reset after the animation so repeat
                        // triggers work without manual clean-up.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            trigger = false
                        }
                    }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The actual particle burst. Spawns ~40 confetti pieces that fly
/// outward with gravity, rotation, and fade.
struct ConfettiBurst: View {
    @State private var particles: [ConfettiParticle] = []
    @State private var animating = false

    private static let colors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .pink,
        Color(red: 0.0, green: 0.8, blue: 0.6),   // teal
        Color(red: 1.0, green: 0.6, blue: 0.0),    // amber
        Color(red: 0.4, green: 0.2, blue: 0.9),    // violet
    ]

    private static let shapes: [ConfettiShape] = [
        .circle, .square, .strip, .triangle
    ]

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                ForEach(particles) { p in
                    confettiPiece(p)
                        .position(
                            x: animating ? center.x + p.endX : center.x,
                            y: animating ? center.y + p.endY : center.y
                        )
                        .rotationEffect(.degrees(animating ? p.endRotation : 0))
                        .scaleEffect(animating ? p.endScale : 0.3)
                        .opacity(animating ? 0 : 1)
                }
            }
            .onAppear {
                particles = Self.spawn(count: 40)
                withAnimation(.easeOut(duration: 2.0)) {
                    animating = true
                }
            }
        }
    }

    @ViewBuilder
    private func confettiPiece(_ p: ConfettiParticle) -> some View {
        switch p.shape {
        case .circle:
            Circle()
                .fill(p.color)
                .frame(width: p.size, height: p.size)
        case .square:
            RoundedRectangle(cornerRadius: 1)
                .fill(p.color)
                .frame(width: p.size, height: p.size)
        case .strip:
            RoundedRectangle(cornerRadius: 1)
                .fill(p.color)
                .frame(width: p.size * 0.4, height: p.size * 1.6)
        case .triangle:
            Triangle()
                .fill(p.color)
                .frame(width: p.size, height: p.size)
        }
    }

    private static func spawn(count: Int) -> [ConfettiParticle] {
        (0..<count).map { _ in
            let angle = Double.random(in: 0..<360) * .pi / 180
            let distance = CGFloat.random(in: 80...220)
            let gravity = CGFloat.random(in: 30...120)
            return ConfettiParticle(
                color: colors.randomElement() ?? .white,
                shape: shapes.randomElement() ?? .circle,
                size: CGFloat.random(in: 5...10),
                endX: cos(angle) * distance,
                endY: sin(angle) * distance + gravity,
                endRotation: Double.random(in: -540...540),
                endScale: CGFloat.random(in: 0.2...0.8)
            )
        }
    }
}

// MARK: - Particle Model

private enum ConfettiShape {
    case circle, square, strip, triangle
}

private struct ConfettiParticle: Identifiable {
    let id = UUID()
    let color: Color
    let shape: ConfettiShape
    let size: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    let endRotation: Double
    let endScale: CGFloat
}

// MARK: - Triangle Shape

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Notification for Confetti Triggers

extension Notification.Name {
    /// Post this from anywhere in the app to trigger a confetti burst
    /// in the menu bar popover. Attach `userInfo["message"]` with a
    /// short celebration string (e.g. "Last meeting done! 🎉").
    static let forgeConfetti = Notification.Name("forgeConfetti")
}

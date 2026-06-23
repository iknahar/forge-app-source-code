import SwiftUI
import AppKit

// MARK: - Teleprompter

/// A floating, auto-scrolling, read-only script panel shown WHILE recording.
/// It's a Forge-owned borderless panel, so the capture filter (which excludes
/// Forge's own windows) keeps it out of the recording — it's purely an on-screen
/// aid and is never exported. Drag the body to reposition.
final class TeleprompterPanel: NSPanel {
    init(script: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 540, height: 240),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar + 1
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: TeleprompterView(script: script))
    }
    override var canBecomeKey: Bool { false }
}

private struct TeleprompterView: View {
    let script: String

    @State private var offsetY: CGFloat = 0
    @State private var contentHeight: CGFloat = 1
    @State private var speed: Double = 35          // points / second
    @State private var paused = false
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                Text(script.isEmpty ? "—" : script)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: geo.size.width, alignment: .top)
                    .background(GeometryReader { g in
                        Color.clear.onAppear { contentHeight = max(1, g.size.height) }
                    })
                    .offset(y: geo.size.height * 0.5 - offsetY)
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 14) {
                Button { paused.toggle() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help(paused ? "Resume scroll" : "Pause scroll")

                Image(systemName: "tortoise.fill").foregroundStyle(.white.opacity(0.6)).font(.system(size: 11))
                Slider(value: $speed, in: 8...120).frame(width: 150)
                Image(systemName: "hare.fill").foregroundStyle(.white.opacity(0.6)).font(.system(size: 11))

                Button { offsetY = 0 } label: {
                    Image(systemName: "arrow.counterclockwise").foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Restart from top")
            }
            .tint(.forgeAccent)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .padding(6)
        .onReceive(tick) { _ in
            guard !paused else { return }
            offsetY += CGFloat(speed) / 30.0
            if offsetY > contentHeight + 80 { offsetY = 0 }   // loop with a small gap
        }
    }
}

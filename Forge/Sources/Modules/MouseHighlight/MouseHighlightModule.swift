import SwiftUI
import AppKit
import QuartzCore

/// Mouse Highlight — visual enhancements for the mouse cursor.
/// Features: Find My Mouse (double-tap RIGHT Command for spotlight),
/// Click Highlighter (small yellow ring on every click — toggled via
/// global hotkey), and Crosshairs.
final class MouseHighlightModule: ForgeModule, ObservableObject {
    let id = "mouseHighlight"
    let name = "Mouse Highlight"
    let description = "Highlight clicks and find your cursor"
    let iconName = "cursorarrow.click.2"
    let category: ModuleCategory = .input
    var isEnabled: Bool = true

    // MARK: - State

    @Published var findMyMouseEnabled: Bool = true
    /// Bridges the per-action enable toggle from SettingsManager into
    /// the module so the gesture handler can be silenced without
    /// removing the monitor. Set by AppDelegate on init + on every
    /// Settings change.
    var isFindMyMouseGestureEnabled: () -> Bool = { true }
    var isClickHighlighterShortcutEnabled: () -> Bool = { true }
    /// Click Highlighter is OFF by default — the user toggles it on
    /// via the global ⌘⌥H shortcut (or the Modules tab). It's a
    /// "presentation mode" feature, not something you want firing
    /// during normal use.
    @Published var clickHighlightEnabled: Bool = false
    @Published var crosshairsEnabled: Bool = false
    /// Find-My-Mouse spotlight halo radius. Tuned tighter (was 120pt)
    /// so the ring reads as a friendly "here's your cursor" pulse
    /// rather than a heavy dim across half the screen.
    @Published var spotlightRadius: CGFloat = 88
    @Published var clickRingColor: NSColor = .systemYellow
    /// Radius of the click-highlight disc. Bumped from 22pt → 28pt
    /// (44pt → 56pt diameter) so the ring is clearly visible on
    /// large external displays during presentations / screen
    /// recordings without obscuring the click target.
    @Published var clickRingSize: CGFloat = 28
    @Published var isFindMyMouseActive: Bool = false

    // Event monitors
    private var rightCmdMonitor: Any?
    private var clickMonitor: Any?
    private var moveMonitor: Any?
    /// Local-app counterpart of `moveMonitor`. Global event monitors only
    /// fire while the event is being delivered to another application, so
    /// when the cursor is over a Forge window the spotlight wouldn't follow
    /// it. The local monitor catches those.
    private var moveLocalMonitor: Any?
    private var lastRightCmdPressTime: TimeInterval = 0
    private let doublePressTreshold: TimeInterval = 0.4
    /// Previous flagsChanged state so we can detect a true RIGHT Command
    /// press transition (key going from up to down) rather than reacting
    /// to every flag-change that happens to include .command in its
    /// modifier mask.
    private var wasRightCmdDown: Bool = false
    /// kVK_RightCommand — the right ⌘ key on full-size + most laptop
    /// keyboards. Distinct from kVK_Command (54 → 55? See note). On macOS
    /// keyCode 54 is right ⌘, 55 is left ⌘. We trigger on right-only
    /// so the user can still use left-⌘ for other shortcuts without
    /// any double-tap interference.
    private let rightCommandKeyCode: UInt16 = 54

    // Windows
    private var spotlightWindow: NSWindow?
    private var crosshairWindow: NSWindow?
    /// Drives the spotlight ripple. A CADisplayLink (not a Timer) so the
    /// ripple advances exactly once per display refresh — vsync-locked,
    /// judder-free, and automatically correct on 60Hz, 120Hz ProMotion,
    /// and external displays alike.
    private var spotlightDisplayLink: CADisplayLink?
    private var spotlightEscMonitorGlobal: Any?
    private var spotlightEscMonitorLocal: Any?
    private var spotlightAutoDismiss: DispatchWorkItem?
    private var screenshotDismissObserver: NSObjectProtocol?
    private var screenshotResumeObserver: NSObjectProtocol?
    /// True while a Forge screenshot session is on screen. While set, the
    /// double-Ctrl detector ignores presses and `showSpotlight()` refuses
    /// to bring the ring back — otherwise the spotlight z-orders above the
    /// screenshot overlay and the user sees a giant dark circle on top of
    /// the capture UI.
    private var screenshotInProgress: Bool = false

    /// Public entrypoint so a global hotkey can toggle / show the spotlight.
    func toggleFindMyMouse() {
        if isFindMyMouseActive { hideSpotlight() } else { showSpotlight() }
    }

    /// Public entrypoint for the ⌘⌥H "Turn on click highlighter"
    /// shortcut. Flips `clickHighlightEnabled` so every subsequent
    /// mouse click paints the small yellow ring at the click point.
    /// Pressing the shortcut again turns it back off.
    func toggleClickHighlighter() {
        clickHighlightEnabled.toggle()
        // Brief tactile feedback so the user knows which state they're in.
        NSSound(named: NSSound.Name(clickHighlightEnabled ? "Pop" : "Tink"))?.play()
        // Clear any in-flight rings on disable so we don't leave a
        // stray fade-out on screen.
        if !clickHighlightEnabled { clearClickRings() }
    }
    private var clickWindows: [NSWindow] = []

    // MARK: - Lifecycle

    func activate() {
        setupRightCommandMonitor()
        setupClickMonitor()
        if crosshairsEnabled { showCrosshairs() }

        // Listen for screenshot-session bookends. Between Before and After:
        //  - the spotlight is force-dismissed
        //  - `screenshotInProgress` is true so the double-Ctrl detector and
        //    `showSpotlight()` both refuse to bring it back
        // This guarantees the giant dark spotlight ring never appears on
        // top of the screenshot overlay regardless of what the user types.
        screenshotDismissObserver = NotificationCenter.default.addObserver(
            forName: .forgeBeforeScreenshotCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenshotInProgress = true
            self?.hideSpotlight()
        }
        screenshotResumeObserver = NotificationCenter.default.addObserver(
            forName: .forgeAfterScreenshotDismiss,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenshotInProgress = false
            // Clear any stale press timestamp so the very next press
            // after the screenshot doesn't immediately count as a double.
            self?.lastRightCmdPressTime = 0
            self?.wasRightCmdDown = false
        }
    }

    func deactivate() {
        removeAllMonitors()
        hideSpotlight()
        hideCrosshairs()
        clearClickRings()
        if let obs = screenshotDismissObserver {
            NotificationCenter.default.removeObserver(obs)
            screenshotDismissObserver = nil
        }
        if let obs = screenshotResumeObserver {
            NotificationCenter.default.removeObserver(obs)
            screenshotResumeObserver = nil
        }
    }

    // MARK: - Find My Mouse (Double-tap RIGHT Command)

    private func setupRightCommandMonitor() {
        rightCmdMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self,
                  self.findMyMouseEnabled,
                  self.isFindMyMouseGestureEnabled(),
                  !self.screenshotInProgress
            else { return }

            // Only care about the right-Command physical key. flagsChanged
            // fires once per modifier-key state change; keyCode identifies
            // which physical key caused it.
            guard event.keyCode == self.rightCommandKeyCode else { return }

            let flags = event.modifierFlags
            // Any other modifier on the line ⇒ this isn't a clean "tap
            // right-⌘ by itself" — could be part of a combo. Ignore.
            let otherMods: NSEvent.ModifierFlags = [.control, .option, .shift, .function]
            let hasOtherMods = !flags.intersection(otherMods).isEmpty

            let cmdNow = flags.contains(.command)
            let wasDown = self.wasRightCmdDown
            self.wasRightCmdDown = cmdNow

            // Only react on the press transition (up → down) of a bare
            // right-⌘.
            guard cmdNow, !wasDown, !hasOtherMods else { return }

            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastRightCmdPressTime < self.doublePressTreshold {
                DispatchQueue.main.async {
                    if self.isFindMyMouseActive {
                        self.hideSpotlight()
                    } else {
                        self.showSpotlight()
                    }
                }
                self.lastRightCmdPressTime = 0 // prevent triple-trigger
            } else {
                self.lastRightCmdPressTime = now
            }
        }
    }

    private func showSpotlight() {
        // Belt-and-suspenders: if a screenshot session is on screen, refuse
        // to bring the ring back. The setupCtrlMonitor guard already blocks
        // the most common trigger but other code paths (e.g. the public
        // `toggleFindMyMouse()` hotkey) flow through here too.
        guard !screenshotInProgress else { return }
        guard let screen = NSScreen.main else { return }
        isFindMyMouseActive = true

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
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let spotlightView = SpotlightView(frame: screen.frame)
        spotlightView.spotlightRadius = spotlightRadius
        spotlightView.mouseLocation = NSEvent.mouseLocation

        window.contentView = spotlightView
        window.orderFrontRegardless()

        spotlightWindow = window

        // Follow the cursor — fire on every mouse move (any modifier state).
        // We register BOTH global and local monitors:
        //   - global: events sent to OTHER apps (cursor over desktop, Finder…)
        //   - local: events sent to OUR app (cursor over a Forge window)
        // Without the local monitor, the spotlight froze whenever the cursor
        // entered any Forge window.
        let updatePosition: () -> Void = { [weak self] in
            guard let self = self else { return }
            (self.spotlightWindow?.contentView as? SpotlightView)?.mouseLocation = NSEvent.mouseLocation
            self.spotlightWindow?.contentView?.needsDisplay = true
            // Reset the 3-second auto-dismiss timer on every move so the
            // spotlight stays alive while the user is actively moving the
            // cursor — otherwise it disappears mid-search.
            self.spotlightAutoDismiss?.cancel()
            let dismiss = DispatchWorkItem { self.hideSpotlight() }
            self.spotlightAutoDismiss = dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: dismiss)
        }
        let moveTypes: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: moveTypes) { _ in
            DispatchQueue.main.async { updatePosition() }
        }
        moveLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: moveTypes) { event in
            DispatchQueue.main.async { updatePosition() }
            return event   // pass the event along so other handlers still fire
        }

        // Drive the animated red ripple with a display-synced CADisplayLink.
        // The previous 1/30s Timer free-ran on the run loop, unaligned with
        // the compositor — producing visible judder and rendering frames
        // that were sometimes never shown. CADisplayLink fires in lockstep
        // with the screen the spotlight window lives on.
        spotlightDisplayLink?.invalidate()
        let link = spotlightView.displayLink(target: self, selector: #selector(stepSpotlightRipple(_:)))
        link.add(to: .main, forMode: .common)
        spotlightDisplayLink = link

        // ESC dismisses — both global (outside Forge) and local (inside Forge)
        // are needed because each only covers one focus state.
        spotlightEscMonitorGlobal = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            if event.keyCode == 53 { self?.hideSpotlight() }
        }
        spotlightEscMonitorLocal = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            if event.keyCode == 53 {
                self?.hideSpotlight()
                return nil
            }
            return event
        }

        // Auto-dismiss after 3 seconds (cancelled if user hits Esc earlier).
        let dismiss = DispatchWorkItem { [weak self] in self?.hideSpotlight() }
        spotlightAutoDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: dismiss)
    }

    /// CADisplayLink callback — advances the ripple phase once per screen
    /// refresh. The phase delta is derived from the real frame duration
    /// (`targetTimestamp − timestamp`) so the ripple travels at the same
    /// visual speed (~0.75 cycles/sec, matching the old 0.025-per-1/30s
    /// Timer) regardless of whether the display runs at 60Hz or 120Hz.
    @objc private func stepSpotlightRipple(_ link: CADisplayLink) {
        guard let view = spotlightWindow?.contentView as? SpotlightView else {
            link.invalidate()
            spotlightDisplayLink = nil
            return
        }
        let frameDuration = max(0, link.targetTimestamp - link.timestamp)
        view.phase = (view.phase + CGFloat(frameDuration) * 0.75)
            .truncatingRemainder(dividingBy: 1)
        view.needsDisplay = true
    }

    /// Public entry point for other modules (e.g. Screenshot) that need to
    /// guarantee no spotlight ring is visible before they do their own thing.
    func dismissSpotlightImmediately() {
        hideSpotlight()
    }

    private func hideSpotlight() {
        isFindMyMouseActive = false
        spotlightWindow?.orderOut(nil)
        spotlightWindow = nil

        spotlightDisplayLink?.invalidate()
        spotlightDisplayLink = nil

        // Cancel pending auto-dismiss if we're hiding early (e.g. from Esc).
        spotlightAutoDismiss?.cancel()
        spotlightAutoDismiss = nil

        if let m = moveMonitor                  { NSEvent.removeMonitor(m); moveMonitor = nil }
        if let m = moveLocalMonitor             { NSEvent.removeMonitor(m); moveLocalMonitor = nil }
        if let m = spotlightEscMonitorGlobal    { NSEvent.removeMonitor(m); spotlightEscMonitorGlobal = nil }
        if let m = spotlightEscMonitorLocal     { NSEvent.removeMonitor(m); spotlightEscMonitorLocal = nil }
    }

    // MARK: - Click Highlighter

    private func setupClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.clickHighlightEnabled else { return }
            DispatchQueue.main.async {
                self.showClickRing(at: NSEvent.mouseLocation, isRightClick: event.type == .rightMouseDown)
            }
        }
    }

    private func showClickRing(at screenPoint: NSPoint, isRightClick: Bool) {
        // Window is sized slightly larger than the disc so the soft
        // fill's edge doesn't get clipped against the window bounds.
        let pad: CGFloat = 4
        let windowSize = clickRingSize * 2 + pad * 2
        let ringFrame = NSRect(
            x: screenPoint.x - windowSize / 2,
            y: screenPoint.y - windowSize / 2,
            width: windowSize,
            height: windowSize
        )

        let window = OverlayWindow(
            contentRect: ringFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let ringView = ClickRingView(frame: NSRect(origin: .zero, size: ringFrame.size))
        ringView.ringColor = isRightClick ? .systemBlue : clickRingColor
        ringView.maxRadius = clickRingSize

        window.contentView = ringView
        window.orderFrontRegardless()

        clickWindows.append(window)

        animateClickRing(view: ringView, window: window)
    }

    private func animateClickRing(view: ClickRingView, window: NSWindow) {
        // The ring drives its own CADisplayLink (vsync-locked, like the
        // spotlight). When the 1s animation completes it calls back here
        // so we can tear down the overlay window. Each ring animates
        // independently, so rapid clicks each get a clean ripple.
        view.onComplete = { [weak self, weak window] in
            guard let window = window else { return }
            window.orderOut(nil)
            self?.clickWindows.removeAll { $0 === window }
        }
        view.startAnimating()
    }

    private func clearClickRings() {
        for window in clickWindows {
            window.orderOut(nil)
        }
        clickWindows.removeAll()
    }

    // MARK: - Crosshairs

    func showCrosshairs() {
        guard crosshairWindow == nil, let screen = NSScreen.main else { return }
        crosshairsEnabled = true

        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = CrosshairView(frame: screen.frame)
        view.mouseLocation = NSEvent.mouseLocation

        window.contentView = view
        window.orderFrontRegardless()

        crosshairWindow = window

        // Track mouse for crosshairs
        if moveMonitor == nil {
            moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if let crosshairView = self.crosshairWindow?.contentView as? CrosshairView {
                        crosshairView.mouseLocation = NSEvent.mouseLocation
                        crosshairView.needsDisplay = true
                    }
                    if let spotlightView = self.spotlightWindow?.contentView as? SpotlightView {
                        spotlightView.mouseLocation = NSEvent.mouseLocation
                        spotlightView.needsDisplay = true
                    }
                }
            }
        }
    }

    func hideCrosshairs() {
        crosshairsEnabled = false
        crosshairWindow?.orderOut(nil)
        crosshairWindow = nil
    }

    // MARK: - Cleanup

    private func removeAllMonitors() {
        if let monitor = rightCmdMonitor {
            NSEvent.removeMonitor(monitor)
            rightCmdMonitor = nil
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let monitor = moveMonitor {
            NSEvent.removeMonitor(monitor)
            moveMonitor = nil
        }
    }

    // MARK: - Commands

}

// MARK: - Spotlight View (Find My Mouse)

final class SpotlightView: NSView {
    /// Compact spotlight — small enough not to block content, easy to spot.
    var spotlightRadius: CGFloat = 7
    var mouseLocation: NSPoint = .zero
    /// 0…1 cycle driven by a Timer in the module. Drives all animation.
    var phase: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        guard let window = self.window else { return }
        let p = NSPoint(
            x: mouseLocation.x - window.frame.origin.x,
            y: mouseLocation.y - window.frame.origin.y
        )

        // Animated color: cycles between deep accent red and a warmer orange-red.
        let t = (sin(phase * .pi * 2) + 1) / 2   // 0…1 smooth pulse
        let accent = NSColor(
            srgbRed: lerp(0.906, 1.000, t),
            green:   lerp(0.160, 0.380, t),
            blue:    lerp(0.012, 0.080, t),
            alpha: 1
        )

        // 1. Soft outer halo with pulsing opacity
        let haloOpacity = 0.22 + 0.22 * t
        let haloRadius  = spotlightRadius + 50
        let cs = CGColorSpaceCreateDeviceRGB()
        let haloColors = [
            accent.withAlphaComponent(haloOpacity).cgColor,
            accent.withAlphaComponent(haloOpacity * 0.45).cgColor,
            accent.withAlphaComponent(0).cgColor,
        ] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: haloColors, locations: [0, 0.5, 1]) {
            ctx.drawRadialGradient(
                g,
                startCenter: p, startRadius: spotlightRadius * 0.5,
                endCenter: p, endRadius: haloRadius,
                options: []
            )
        }

        // 2. Two ripple rings — phase-offset for a continuous radar-ping effect
        drawRipple(p: p, phase: phase,                color: accent)
        drawRipple(p: p, phase: phase + 0.5,          color: accent)

        // 3. Crisp core ring
        accent.withAlphaComponent(0.95).setStroke()
        let core = NSBezierPath(ovalIn: NSRect(
            x: p.x - spotlightRadius, y: p.y - spotlightRadius,
            width: spotlightRadius * 2, height: spotlightRadius * 2
        ))
        core.lineWidth = 2.5
        core.stroke()

        // 4. Subtle inner white highlight (helps cursor pop)
        NSColor.white.withAlphaComponent(0.55 + 0.20 * t).setStroke()
        let inner = NSBezierPath(ovalIn: NSRect(
            x: p.x - spotlightRadius + 3, y: p.y - spotlightRadius + 3,
            width: (spotlightRadius - 3) * 2, height: (spotlightRadius - 3) * 2
        ))
        inner.lineWidth = 1
        inner.stroke()
    }

    private func drawRipple(p: NSPoint, phase: CGFloat, color: NSColor) {
        let local = phase.truncatingRemainder(dividingBy: 1)
        let expand: CGFloat = 36
        let r = spotlightRadius + expand * local
        let alpha = (1 - local) * 0.75
        color.withAlphaComponent(alpha).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(
            x: p.x - r, y: p.y - r,
            width: r * 2, height: r * 2
        ))
        ring.lineWidth = 1.6 + 1.4 * (1 - local)   // thicker when fresh
        ring.stroke()
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}

// MARK: - Click Ring View

/// Small, soft yellow click highlight. Renders a constant-size disc
/// (no expansion) with a fade-in / hold / fade-out alpha curve. Matches
/// the user-requested "very small yellow shade only when clicking".
final class ClickRingView: NSView {
    var ringColor: NSColor = .systemYellow
    var maxRadius: CGFloat = 10
    var progress: CGFloat = 0 // 0 to 1 across the full animation

    /// Called once when the 1s ripple finishes, so the owner can tear
    /// down the overlay window.
    var onComplete: (() -> Void)?

    private var rippleLink: CADisplayLink?
    private var animationStart: CFTimeInterval = 0
    private let animationDuration: CFTimeInterval = 1.0

    /// Begin the ripple, driven by a display-synced CADisplayLink rather
    /// than a free-running Timer. Progress is computed from wall-clock
    /// elapsed time, so the animation lasts exactly 1s no matter the
    /// refresh rate; the link just decides when to repaint.
    func startAnimating() {
        animationStart = CACurrentMediaTime()
        let link = self.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        rippleLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - animationStart
        if elapsed >= animationDuration {
            progress = 1
            link.invalidate()
            rippleLink = nil
            onComplete?()
            return
        }
        progress = CGFloat(elapsed / animationDuration)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        let center = NSPoint(x: bounds.midX, y: bounds.midY)

        // Alpha curve, expressed as percentages of the total
        // animation duration (1s). Tuned so the disc reads as
        // genuinely visible for the bulk of that second:
        //   0.00 .. 0.05  → fade in   (≈ 50 ms)
        //   0.05 .. 0.85  → hold at full (≈ 800 ms)
        //   0.85 .. 1.00  → fade out  (≈ 150 ms)
        let alpha: CGFloat
        if progress < 0.05 {
            alpha = progress / 0.05
        } else if progress < 0.85 {
            alpha = 1.0
        } else {
            alpha = max(0, 1.0 - (progress - 0.85) / 0.15)
        }

        // Soft yellow disc (filled, ~50% alpha at peak so it reads as
        // a "shade", not a solid blob).
        context.setFillColor(ringColor.withAlphaComponent(alpha * 0.55).cgColor)
        context.fillEllipse(in: NSRect(
            x: center.x - maxRadius,
            y: center.y - maxRadius,
            width: maxRadius * 2,
            height: maxRadius * 2
        ))

        // Crisp outline so the disc reads against any background
        // (white desktops, photos, etc.).
        context.setStrokeColor(ringColor.withAlphaComponent(alpha * 0.95).cgColor)
        context.setLineWidth(1.25)
        context.strokeEllipse(in: NSRect(
            x: center.x - maxRadius + 0.625,
            y: center.y - maxRadius + 0.625,
            width: maxRadius * 2 - 1.25,
            height: maxRadius * 2 - 1.25
        ))
    }
}

// MARK: - Crosshair View

final class CrosshairView: NSView {
    var mouseLocation: NSPoint = .zero

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        guard let window = self.window else { return }
        let localPoint = NSPoint(
            x: mouseLocation.x - window.frame.origin.x,
            y: mouseLocation.y - window.frame.origin.y
        )

        // Draw fullscreen crosshair lines
        context.saveGState()

        // Main lines (with gap around cursor)
        let gap: CGFloat = 20
        let lineColor = NSColor.systemRed.withAlphaComponent(0.6)

        context.setStrokeColor(lineColor.cgColor)
        context.setLineWidth(1)

        // Horizontal left
        context.move(to: CGPoint(x: 0, y: localPoint.y))
        context.addLine(to: CGPoint(x: localPoint.x - gap, y: localPoint.y))
        // Horizontal right
        context.move(to: CGPoint(x: localPoint.x + gap, y: localPoint.y))
        context.addLine(to: CGPoint(x: bounds.width, y: localPoint.y))
        // Vertical bottom
        context.move(to: CGPoint(x: localPoint.x, y: 0))
        context.addLine(to: CGPoint(x: localPoint.x, y: localPoint.y - gap))
        // Vertical top
        context.move(to: CGPoint(x: localPoint.x, y: localPoint.y + gap))
        context.addLine(to: CGPoint(x: localPoint.x, y: bounds.height))
        context.strokePath()

        // Coordinate label
        let text = "\(Int(mouseLocation.x)), \(Int(mouseLocation.y))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()

        let labelPoint = NSPoint(x: localPoint.x + 12, y: localPoint.y + 8)
        let bgRect = NSRect(x: labelPoint.x - 4, y: labelPoint.y - 2, width: size.width + 8, height: size.height + 4)
        let bg = NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3)
        NSColor(calibratedWhite: 0.1, alpha: 0.85).setFill()
        bg.fill()

        str.draw(at: labelPoint)

        context.restoreGState()
    }
}

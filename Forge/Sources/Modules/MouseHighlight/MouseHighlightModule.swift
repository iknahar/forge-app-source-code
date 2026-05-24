import SwiftUI
import AppKit

/// Mouse Highlight — visual enhancements for the mouse cursor.
/// Features: Find My Mouse (double-press Ctrl for spotlight),
/// Click Highlighter (colored circles on clicks), and Crosshairs.
final class MouseHighlightModule: ForgeModule, ObservableObject {
    let id = "mouseHighlight"
    let name = "Mouse Highlight"
    let description = "Highlight clicks and find your cursor"
    let iconName = "cursorarrow.click.2"
    let category: ModuleCategory = .input
    var isEnabled: Bool = true

    // MARK: - State

    @Published var findMyMouseEnabled: Bool = true
    @Published var clickHighlightEnabled: Bool = true
    @Published var crosshairsEnabled: Bool = false
    @Published var spotlightRadius: CGFloat = 120
    @Published var clickRingColor: NSColor = .systemYellow
    @Published var clickRingSize: CGFloat = 30
    @Published var isFindMyMouseActive: Bool = false

    // Event monitors
    private var ctrlPressMonitor: Any?
    private var clickMonitor: Any?
    private var moveMonitor: Any?
    /// Local-app counterpart of `moveMonitor`. Global event monitors only
    /// fire while the event is being delivered to another application, so
    /// when the cursor is over a Forge window the spotlight wouldn't follow
    /// it. The local monitor catches those.
    private var moveLocalMonitor: Any?
    private var lastCtrlPressTime: TimeInterval = 0
    private let doublePressTreshold: TimeInterval = 0.4
    /// Previous flagsChanged state so we can detect a true Ctrl press
    /// transition (key going from up to down) rather than reacting to any
    /// flag-change event that happens to have Ctrl set in its modifier
    /// mask (e.g. when ⌥ is added on top of ⌃ during the ⌃⌥S shortcut).
    private var wasCtrlDown: Bool = false

    // Windows
    private var spotlightWindow: NSWindow?
    private var crosshairWindow: NSWindow?
    private var spotlightAnimationTimer: Timer?
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
    private var clickWindows: [NSWindow] = []

    // MARK: - Lifecycle

    func activate() {
        setupCtrlMonitor()
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
            // Clear any stale Ctrl-press timestamp so the very next press
            // after the screenshot doesn't immediately count as a double.
            self?.lastCtrlPressTime = 0
            self?.wasCtrlDown = false
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

    // MARK: - Find My Mouse (Double-press Ctrl)

    private func setupCtrlMonitor() {
        ctrlPressMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self,
                  self.findMyMouseEnabled,
                  !self.screenshotInProgress
            else { return }

            let flags = event.modifierFlags
            let ctrlNow = flags.contains(.control)
            // Any other modifier on the line ⇒ this isn't a clean "tap Ctrl
            // by itself" — it's part of a combo like ⌃⌥S (the screenshot
            // shortcut). Don't count it as a Find My Mouse press.
            let otherMods: NSEvent.ModifierFlags = [.option, .command, .shift, .function]
            let hasOtherMods = !flags.intersection(otherMods).isEmpty

            // Remember the new Ctrl state for the next event before any
            // early return so the transition detection stays correct.
            let wasDown = self.wasCtrlDown
            self.wasCtrlDown = ctrlNow

            // Only react on the actual press transition (up → down) of a
            // bare Ctrl key — no other modifiers involved.
            guard ctrlNow, !wasDown, !hasOtherMods else { return }

            let now = ProcessInfo.processInfo.systemUptime

            if now - self.lastCtrlPressTime < self.doublePressTreshold {
                // Double-press detected
                DispatchQueue.main.async {
                    if self.isFindMyMouseActive {
                        self.hideSpotlight()
                    } else {
                        self.showSpotlight()
                    }
                }
                self.lastCtrlPressTime = 0 // Reset to prevent triple-trigger
            } else {
                self.lastCtrlPressTime = now
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

        // Drive the animated red ripple effect at ~30 fps
        spotlightAnimationTimer?.invalidate()
        spotlightAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard
                let view = self?.spotlightWindow?.contentView as? SpotlightView
            else { return }
            view.phase = (view.phase + 0.025).truncatingRemainder(dividingBy: 1)
            view.needsDisplay = true
        }

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

    /// Public entry point for other modules (e.g. Screenshot) that need to
    /// guarantee no spotlight ring is visible before they do their own thing.
    func dismissSpotlightImmediately() {
        hideSpotlight()
    }

    private func hideSpotlight() {
        isFindMyMouseActive = false
        spotlightWindow?.orderOut(nil)
        spotlightWindow = nil

        spotlightAnimationTimer?.invalidate()
        spotlightAnimationTimer = nil

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
        let ringSize = clickRingSize * 2
        let ringFrame = NSRect(
            x: screenPoint.x - ringSize / 2,
            y: screenPoint.y - ringSize / 2,
            width: ringSize,
            height: ringSize
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

        // Animate ring expanding and fading
        animateClickRing(view: ringView, window: window)
    }

    private func animateClickRing(view: ClickRingView, window: NSWindow) {
        var progress: CGFloat = 0
        let duration: TimeInterval = 0.4
        let startTime = CACurrentMediaTime()

        let displayLink = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak view, weak window] timer in
            guard let view = view, let window = window else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startTime
            progress = CGFloat(elapsed / duration)

            if progress >= 1.0 {
                timer.invalidate()
                window.orderOut(nil)
                self?.clickWindows.removeAll { $0 === window }
                return
            }

            view.progress = progress
            view.needsDisplay = true
        }
        RunLoop.current.add(displayLink, forMode: .common)
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
        if let monitor = ctrlPressMonitor {
            NSEvent.removeMonitor(monitor)
            ctrlPressMonitor = nil
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

    func commands() -> [ForgeCommand] {
        [
            ForgeCommand(
                id: "mouse.findmymouse", title: "Find My Mouse", subtitle: "Spotlight effect on cursor",
                iconName: "cursorarrow.rays", moduleId: id,
                action: { [weak self] in self?.showSpotlight() },
                keywords: ["find", "mouse", "cursor", "spotlight", "highlight", "locate"]
            ),
            ForgeCommand(
                id: "mouse.crosshairs", title: "Toggle Crosshairs", subtitle: "Show fullscreen crosshairs at cursor",
                iconName: "plus.circle", moduleId: id,
                action: { [weak self] in
                    guard let self = self else { return }
                    if self.crosshairsEnabled {
                        self.hideCrosshairs()
                    } else {
                        self.showCrosshairs()
                    }
                },
                keywords: ["crosshair", "cursor", "guide", "lines", "mouse"]
            ),
            ForgeCommand(
                id: "mouse.clickhighlight", title: "Toggle Click Highlight", subtitle: "Show colored rings on mouse clicks",
                iconName: "cursorarrow.click", moduleId: id,
                action: { [weak self] in
                    self?.clickHighlightEnabled.toggle()
                },
                keywords: ["click", "highlight", "ring", "mouse", "visual"]
            ),
        ]
    }
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

final class ClickRingView: NSView {
    var ringColor: NSColor = .systemYellow
    var maxRadius: CGFloat = 30
    var progress: CGFloat = 0 // 0 to 1

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let currentRadius = maxRadius * (0.3 + progress * 0.7) // Start at 30%, expand to 100%
        let alpha = 1.0 - progress // Fade out

        // Outer ring
        context.saveGState()
        context.setStrokeColor(ringColor.withAlphaComponent(alpha * 0.8).cgColor)
        context.setLineWidth(2.5)
        context.strokeEllipse(in: NSRect(
            x: center.x - currentRadius,
            y: center.y - currentRadius,
            width: currentRadius * 2,
            height: currentRadius * 2
        ))

        // Inner fill
        context.setFillColor(ringColor.withAlphaComponent(alpha * 0.15).cgColor)
        context.fillEllipse(in: NSRect(
            x: center.x - currentRadius,
            y: center.y - currentRadius,
            width: currentRadius * 2,
            height: currentRadius * 2
        ))

        // Center dot (visible at start, fades quickly)
        let dotAlpha = max(0, 1.0 - progress * 3)
        if dotAlpha > 0 {
            context.setFillColor(ringColor.withAlphaComponent(dotAlpha).cgColor)
            let dotSize: CGFloat = 4
            context.fillEllipse(in: NSRect(
                x: center.x - dotSize / 2,
                y: center.y - dotSize / 2,
                width: dotSize,
                height: dotSize
            ))
        }

        context.restoreGState()
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

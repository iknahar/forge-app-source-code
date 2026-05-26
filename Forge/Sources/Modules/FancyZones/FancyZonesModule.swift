import SwiftUI
import AppKit

// MARK: - File logger
//
// `print()` from a SwiftUI macOS app launched via `open .app` doesn't
// land in Console.app's `system.log`, so diagnostic messages were
// going nowhere visible. This helper appends every `fzLog(...)` line
// to `~/Library/Logs/Forge/fancyzones.log` — the user can just
// `tail -f` it in Terminal to see what's happening in real time.

private let fzLogURL: URL = {
    let dir = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Forge", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true
    )
    return dir.appendingPathComponent("fancyzones.log")
}()

private let fzLogFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

private let fzLogQueue = DispatchQueue(label: "forge.fz.log")

private func fzLog(_ message: String) {
    let stamp = fzLogFormatter.string(from: Date())
    let line = "[\(stamp)] [FZ] \(message)\n"
    // Mirror to stderr too — Console.app picks it up under the Mac
    // device stream if the user filters there.
    print(line, terminator: "")
    fzLogQueue.async {
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fzLogURL.path) {
                if let handle = try? FileHandle(forWritingTo: fzLogURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: fzLogURL)
            }
        }
    }
}

/// FancyZones — custom window snap zone layouts.
/// Activated with ⌃⌥F to open the zone editor. Hold Shift during
/// window drag to show zone overlay and snap windows into zones.
final class FancyZonesModule: ForgeModule, ObservableObject {
    let id = "fancyZones"
    let name = "FancyZones"
    let description = "Custom window snap zones"
    let iconName = "rectangle.split.3x3"
    let category: ModuleCategory = .windows
    var isEnabled: Bool = true

    // MARK: - State

    @Published var isEditorActive: Bool = false
    @Published var isOverlayShowing: Bool = false
    /// Bridges the per-action enable toggle from SettingsManager into
    /// the module's gesture handler. Set by AppDelegate. When false,
    /// Shift-drag does nothing (overlay won't show, snap won't fire).
    var isSnapGestureEnabled: () -> Bool = { true }
    /// What the user has chosen as their active layout — either one
    /// of the built-in templates, or a custom layout they drew with
    /// the splitter. The snap-on-drop + overlay both render from
    /// `activeConfig` which switches on this.
    @Published var activeLayoutRef: ActiveLayout = .template(.columns)
    /// One persisted config per template (zone count, padding,
    /// highlight distance, orientation defaults). Persists to disk.
    @Published var configs: [ZoneTemplate: ZoneLayoutConfig] = [:]
    /// User-drawn custom layouts. Each one has its own zones array
    /// produced by the splitter UI (no template generator involved).
    @Published var customLayouts: [CustomLayout] = []

    /// Backward-compatibility shim — many call sites still ask "is
    /// THIS template active?". Returns the template iff active, else
    /// nil (when a custom layout is currently chosen).
    var activeTemplate: ZoneTemplate {
        if case .template(let t) = activeLayoutRef { return t }
        return .none
    }

    /// Convenience: the config for the active layout — works for both
    /// templates and custom layouts. Custom layouts are wrapped in a
    /// transient `ZoneLayoutConfig` so the snap path stays generic.
    var activeConfig: ZoneLayoutConfig {
        switch activeLayoutRef {
        case .template(let t):
            return config(for: t)
        case .custom(let id):
            return customLayouts
                .first(where: { $0.id == id })
                .map { $0.asZoneLayoutConfig() }
                ?? config(for: .columns)
        }
    }

    /// Pick the template to use on a given screen. Honors the user's
    /// "Default for horizontal/vertical monitor" stars from the
    /// per-template edit sheet:
    ///   • Whichever template has its orientation-default flag set
    ///     wins for that orientation.
    ///   • If no template is starred for the orientation, fall back
    ///     to the user's `activeTemplate` (the one they tapped most
    ///     recently in the editor).
    /// A monitor is "vertical" when its visible-frame height is
    /// taller than its width.
    func configForScreen(_ screen: NSScreen) -> ZoneLayoutConfig {
        // The active layout is the user's most recent explicit pick
        // (tapped card in the editor, or just-saved custom layout).
        // That wins on every screen — anything more sophisticated
        // (per-monitor preferences) needs a real per-monitor data
        // model, which Forge doesn't have yet. Without this rule, a
        // template that the user once starred as "horizontal default"
        // would override a freshly-authored custom layout that's
        // already marked active, which is what was happening today.
        //
        // The orientation-default stars in the editor remain stored
        // for future multi-monitor work — we just don't consult them
        // at snap time.
        _ = screen
        return activeConfig
    }

    private var editorWindow: NSWindow?
    private var overlayWindow: NSWindow?
    private var dragMonitor: Any?
    private var mouseUpMonitor: Any?
    /// The window the user started dragging when Shift was first
    /// held — captured at the first qualifying drag event so the
    /// mouse-up snap doesn't have to re-resolve "frontmost focused
    /// window" later (focus can change mid-drag if the user crosses
    /// monitors / apps, and AX `focusedWindow` lookups occasionally
    /// race the OS's own drag-complete handler).
    private var dragTargetWindow: AXUIElement?
    private var dragTargetPID: pid_t?
    /// True between the first `.leftMouseDragged` event and the next
    /// `.leftMouseUp`. Gates whether Shift should expose the overlay
    /// (otherwise typing capital letters would also fire it).
    private var isDragging = false

    // MARK: - Lifecycle

    func activate() {
        loadLayouts()
        setupDragMonitor()
    }

    func deactivate() {
        closeEditor()
        hideOverlay()
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
    }

    // MARK: - Drag Monitor

    /// Two global event monitors gate the snap behavior:
    ///
    ///   1. `.leftMouseDragged` fires while the user is dragging with
    ///      the left mouse button down — that's our "drag in progress"
    ///      signal. We only consult the Shift modifier *during* a drag,
    ///      so plain Shift presses (typing capital letters) are ignored.
    ///
    ///   2. `.leftMouseUp` fires when the drag ends. If the zone overlay
    ///      was visible at that moment, we look up which zone the cursor
    ///      is over and resize the frontmost window into that zone via
    ///      the Accessibility API.
    private func setupDragMonitor() {
        dragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged]
        ) { [weak self] event in
            guard let self = self,
                  self.isEnabled,
                  self.isSnapGestureEnabled()
            else { return }
            let wasDragging = self.isDragging
            self.isDragging = true
            let shiftHeld = event.modifierFlags.contains(.shift)

            // First drag event of a new gesture — capture the window
            // that's being dragged so the mouse-up handler doesn't
            // have to re-resolve "frontmost focused window" later.
            // That re-resolution was the snap bug: by the time AX
            // looked again at mouse-up, focus had already drifted
            // (e.g. the OS hadn't finished its own drag commit) and
            // we'd silently fail or target the wrong window.
            if !wasDragging {
                self.captureDragTarget()
            }

            DispatchQueue.main.async {
                if shiftHeld && !self.isOverlayShowing {
                    self.showOverlay()
                } else if !shiftHeld && self.isOverlayShowing {
                    // Shift released mid-drag — hide overlay but keep
                    // `isDragging = true` so re-pressing Shift in the
                    // same gesture re-shows it.
                    self.hideOverlay()
                }
                // While Shift is held + the overlay is up, keep the
                // highlight glued to the cursor so the user can see
                // which zone they're about to drop into.
                if self.isOverlayShowing {
                    self.updateOverlayHighlight(at: NSEvent.mouseLocation)
                }
            }
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] _ in
            guard let self = self else { return }
            let snapNow = self.isDragging && self.isOverlayShowing
            let target = self.dragTargetWindow
            self.isDragging = false
            self.dragTargetWindow = nil
            self.dragTargetPID = nil
            let cursor = NSEvent.mouseLocation
            fzLog("mouseUp snapNow=\(snapNow) capturedTarget=\(target != nil)")

            // Tear down the overlay immediately so the user gets
            // visual closure, then snap on a tiny delay so the OS's
            // own drag-complete handler has time to commit the
            // window's final position before our AX setAttributes
            // race it.
            DispatchQueue.main.async { self.hideOverlay() }
            if snapNow {
                // Use the captured target if available; fall back to
                // a fresh frontmost lookup otherwise.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if let window = target {
                        self.snap(window: window, under: cursor)
                    } else {
                        self.snapFrontmostWindow(under: cursor)
                    }
                }
            }
        }
    }

    /// Resolve the AX window the user is dragging RIGHT NOW and stash
    /// it. Three-step fallback:
    ///   1. `kAXFocusedWindowAttribute`
    ///   2. `kAXMainWindowAttribute`
    ///   3. First entry of `kAXWindowsAttribute` (the app's window
    ///      list; first is conventionally the frontmost)
    /// If ALL three return errors AND `AXIsProcessTrusted()` is
    /// false, fire the system permission prompt — that's the only
    /// reason every app's AX would refuse us in lockstep.
    private func captureDragTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            fzLog("capture: no frontmost app")
            return
        }
        let trusted = AXIsProcessTrusted()
        let appRef = AXUIElementCreateApplication(app.processIdentifier)

        // Try the two scalar attributes first.
        for attr in [kAXFocusedWindowAttribute as CFString,
                     kAXMainWindowAttribute as CFString] {
            var anyRef: AnyObject?
            let err = AXUIElementCopyAttributeValue(appRef, attr, &anyRef)
            if err == .success, let value = anyRef {
                dragTargetWindow = (value as! AXUIElement)
                dragTargetPID = app.processIdentifier
                fzLog("capture OK: app=\(app.localizedName ?? "?") via=\(attr) trusted=\(trusted)")
                return
            }
            fzLog("capture: \(attr) failed err=\(err.rawValue) trusted=\(trusted) app=\(app.localizedName ?? "?")")
        }

        // Last resort — list all windows of the app and take the
        // first (frontmost by AX convention).
        var windowsRef: CFTypeRef?
        let listErr = AXUIElementCopyAttributeValue(
            appRef, kAXWindowsAttribute as CFString, &windowsRef
        )
        if listErr == .success,
           let windows = windowsRef as? [AXUIElement],
           let first = windows.first {
            dragTargetWindow = first
            dragTargetPID = app.processIdentifier
            fzLog("capture OK via windows list: app=\(app.localizedName ?? "?")")
            return
        }
        fzLog("capture: windows list failed err=\(listErr.rawValue) app=\(app.localizedName ?? "?")")

        // All three failed AND we're not trusted → trigger the
        // system Accessibility prompt. The user can grant once and
        // every future drag will work. We only do this on the FIRST
        // failed capture per session to avoid prompt spam.
        if !trusted && !hasPromptedForAX {
            hasPromptedForAX = true
            DispatchQueue.main.async { self.promptForAccessibility() }
        }
    }

    /// True after we've shown the system Accessibility prompt at
    /// least once this app session. Resets on next launch.
    private var hasPromptedForAX = false

    /// Triggers the macOS Accessibility consent dialog. Without
    /// AX trust, every `AXUIElementCopyAttributeValue` against
    /// another app's element returns `.apiDisabled (-25211)` — which
    /// is exactly the failure mode in the log dump.
    private func promptForAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [promptKey: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        // Also pop a Forge-side alert telling the user what's
        // happening + a one-click jump to the right Privacy pane.
        let alert = NSAlert()
        alert.messageText = "Forge needs Accessibility permission"
        alert.informativeText = """
        FancyZones can't snap windows without Accessibility access. \
        macOS may have just shown a system dialog; if so, click \
        "Open System Settings" there.

        Otherwise, open System Settings → Privacy & Security → \
        Accessibility, enable Forge, then try the shift-drag again.

        (If Forge is already in the list, toggle it off and on — \
        Debug builds get re-signed on every rebuild and the OS \
        sometimes invalidates the trust silently.)
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Snap logic

    /// Find which zone the mouse is over and resize the frontmost window
    /// to fill it. Uses the Accessibility API; requires the user to have
    /// granted Forge Accessibility access (System Settings → Privacy &
    /// Security → Accessibility).
    private func snapFrontmostWindow(under cursorPoint: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) })
                ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let layout = configForScreen(screen)
        guard !layout.zones.isEmpty else { return }

        // Pick the zone that contains the cursor; if none does (the
        // user dropped between zones, on the edge, etc.) fall back
        // to the closest zone by center-distance. The "release to
        // snap" gesture is intent-heavy — we shouldn't silently bail
        // just because the cursor was a few pixels off.
        let zone = zoneClosest(to: cursorPoint, in: layout.zones, visible: visible)

        // Inset by "space around zones" so the snapped window has
        // breathing room matching the visual overlay.
        let pad = CGFloat(layout.spaceAroundEnabled ? layout.spaceAroundPixels : 0)
        let target = absoluteRect(for: zone, in: visible).insetBy(dx: pad, dy: pad)
        resizeFrontmostWindow(to: target, screen: screen)
    }

    /// Closest zone to a cursor point: prefers containment, falls
    /// back to nearest center. Shared by snap + overlay highlight so
    /// both paths agree on what's "under the cursor".
    private func zoneClosest(
        to cursor: NSPoint,
        in zones: [ZoneDefinition],
        visible: NSRect
    ) -> ZoneDefinition {
        var best: ZoneDefinition = zones[0]
        var bestDist: CGFloat = .infinity
        for zone in zones {
            let zr = absoluteRect(for: zone, in: visible)
            if zr.contains(cursor) { return zone }
            let d = hypot(cursor.x - zr.midX, cursor.y - zr.midY)
            if d < bestDist {
                bestDist = d
                best = zone
            }
        }
        return best
    }

    /// While the overlay is up, keep its highlighted zone in sync
    /// with the cursor — this is the "you're about to drop here"
    /// feedback the user asked for. Called from the drag monitor on
    /// every `.leftMouseDragged` while Shift is held.
    private func updateOverlayHighlight(at cursor: NSPoint) {
        guard let view = overlayWindow?.contentView as? ZoneOverlayView,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
                          ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let target = zoneClosest(to: cursor, in: view.zones, visible: visible)
        let newIdx = view.zones.firstIndex { $0.id == target.id }
        if view.highlightedZone != newIdx {
            view.highlightedZone = newIdx
            view.needsDisplay = true
        }
    }

    /// Convert a normalized `ZoneDefinition.rect` into an absolute
    /// NSRect on the given screen.
    ///
    /// IMPORTANT: zones are stored with **top-left** origin (y=0 is
    /// the top of the screen, matching the splitter UI). NSScreen
    /// uses **bottom-left** origin. Flip Y here. The old code
    /// treated y=0 as bottom, which silently inverted every layout —
    /// the Grid template's "top-left" zone was actually landing in
    /// the bottom-left of the screen, and the user's freshly-drawn
    /// custom layouts looked like they were "splitting old templates"
    /// because the zone they thought was on top was being painted at
    /// the bottom.
    private func absoluteRect(for zone: ZoneDefinition, in visible: NSRect) -> NSRect {
        NSRect(
            x: visible.origin.x + zone.rect.x * visible.width,
            y: visible.origin.y + (1.0 - zone.rect.y - zone.rect.height) * visible.height,
            width: zone.rect.width * visible.width,
            height: zone.rect.height * visible.height
        )
    }

    /// Move + resize the frontmost window to fill `target` (NSScreen
    /// coordinates, bottom-left). Accessibility API uses top-left
    /// coordinates so we convert before issuing the set.
    /// Snap a specific (already-captured) AX window to the zone under
    /// the cursor. This is the path the mouse-up handler uses now —
    /// it doesn't go through `frontmostApplication` again because
    /// focus can drift between drag-start and mouse-up.
    private func snap(window: AXUIElement, under cursorPoint: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorPoint) })
                ?? NSScreen.main
        else { fzLog("snap: no screen contains cursor"); return }
        let visible = screen.visibleFrame
        let layout = configForScreen(screen)
        guard !layout.zones.isEmpty else {
            fzLog("snap: active layout has 0 zones — nothing to snap to")
            return
        }
        let zone = zoneClosest(to: cursorPoint, in: layout.zones, visible: visible)
        let pad = CGFloat(layout.spaceAroundEnabled ? layout.spaceAroundPixels : 0)
        let target = absoluteRect(for: zone, in: visible).insetBy(dx: pad, dy: pad)
        fzLog("snap: zone=\(zone.name) target=\(target) layoutZones=\(layout.zones.count)")
        resize(window: window, to: target, screen: screen)
    }

    private func resizeFrontmostWindow(to target: NSRect, screen: NSScreen) {
        guard AXIsProcessTrusted() else {
            print("[Forge FancyZones] Snap skipped — Accessibility permission required.")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedAny: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedAny
        )
        guard err == .success, let focused = focusedAny else { return }
        resize(window: focused as! AXUIElement, to: target, screen: screen)
    }

    /// Generic "move + resize this window" — the shared AX path used
    /// by both the captured-target and frontmost-window snap routes.
    /// Sets size FIRST, then position, then size again. Some apps
    /// reject a position that would overflow their current size
    /// (Finder, Mail, …) so we need to give them the new size up
    /// front; the second size set covers apps that snap their size
    /// to the position rect they just got.
    private func resize(window: AXUIElement, to target: NSRect, screen: NSScreen) {
        guard AXIsProcessTrusted() else {
            fzLog("resize SKIPPED: Accessibility permission missing")
            return
        }

        // AX uses TOP-LEFT origin anchored at the primary display.
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        var topLeftPosition = CGPoint(
            x: target.origin.x,
            y: primaryScreenTop - target.origin.y - target.height
        )
        var size = target.size

        // Diagnostic: read back the window's current frame so we can
        // tell whether AX is responding at all on this window.
        let beforeFrame = readWindowFrame(window)
        fzLog("resize: before=\(beforeFrame ?? .zero) targetPos=\(topLeftPosition) targetSize=\(size)")

        var sizeResult: AXError = .success
        var posResult: AXError = .success

        if let sizeValue = AXValueCreate(.cgSize, &size) {
            sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let posValue = AXValueCreate(.cgPoint, &topLeftPosition) {
            posResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }

        let afterFrame = readWindowFrame(window)
        fzLog("resize: sizeErr=\(sizeResult.rawValue) posErr=\(posResult.rawValue) after=\(afterFrame ?? .zero)")

        // If the AX writes had zero effect (e.g. the window is
        // fullscreen, or the app rejected our calls), retry once
        // after another ~150ms in case the OS was still completing
        // its own drag handler.
        if let before = beforeFrame, let after = afterFrame,
           NSEqualRects(before, after) {
            fzLog("resize: NO CHANGE detected, retrying in 0.15s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if let sizeValue = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
                }
                if let posValue = AXValueCreate(.cgPoint, &topLeftPosition) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
                }
                if let sizeValue = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
                }
                let retryFrame = self.readWindowFrame(window)
                fzLog("resize retry: after=\(retryFrame ?? .zero)")
            }
        }
    }

    /// Best-effort frame read so we can detect whether our writes
    /// actually changed anything. Returns nil if the window doesn't
    /// expose position+size (e.g. fullscreen apps).
    private func readWindowFrame(_ window: AXUIElement) -> NSRect? {
        var posAny: AnyObject?
        var sizeAny: AnyObject?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posAny) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeAny) == .success,
            let posVal = posAny, let sizeVal = sizeAny
        else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &s)
        return NSRect(origin: p, size: s)
    }

    // MARK: - Zone Overlay

    func showOverlay() {
        // Anchor the overlay to whichever screen the cursor is over —
        // multi-monitor users expect the zones to appear under their
        // hand, not on the primary display.
        let cursor = NSEvent.mouseLocation
        guard !isOverlayShowing,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
                ?? NSScreen.main
        else { return }
        // Pick the layout for THIS screen (honors per-orientation
        // default stars set in the editor).
        let layout = configForScreen(screen)
        // No zones (template == .none) — nothing to show.
        guard !layout.zones.isEmpty else { return }
        isOverlayShowing = true

        let window = NSWindow(
            contentRect: screen.visibleFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = ZoneOverlayView(frame: screen.visibleFrame)
        view.zones = layout.zones
        view.spaceAroundPixels = layout.spaceAroundEnabled ? CGFloat(layout.spaceAroundPixels) : 0
        view.screenFrame = screen.visibleFrame

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        overlayWindow = window
        // Seed the highlight so the first feedback frame already
        // points at the right zone — without this the user sees an
        // "all dim" overlay until they nudge the mouse.
        updateOverlayHighlight(at: NSEvent.mouseLocation)
    }

    func hideOverlay() {
        isOverlayShowing = false
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }

    // MARK: - Zone Editor

    /// Open the PowerToys-style template gallery. The gallery is a
    /// SwiftUI view hosted in a regular NSWindow so it picks up
    /// Forge's theme + animations.
    func openEditor() {
        guard !isEditorActive, let screen = NSScreen.main else { return }
        isEditorActive = true

        let editorSize = NSSize(width: 760, height: 580)
        let origin = NSPoint(
            x: screen.visibleFrame.midX - editorSize.width / 2,
            y: screen.visibleFrame.midY - editorSize.height / 2
        )

        let host = NSHostingController(rootView: FancyZonesEditorView(
            module: self,
            onClose: { [weak self] in self?.closeEditor() }
        ))

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: editorSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FancyZones"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.level = .floating
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        editorWindow = window
    }

    func closeEditor() {
        isEditorActive = false
        editorWindow?.orderOut(nil)
        editorWindow = nil
    }

    // MARK: - Public config API (used by the SwiftUI editor)

    /// Returns the persisted config for a template, or the default if
    /// the user has never customised it. Always returns a fresh value
    /// with zones regenerated from the current params.
    func config(for template: ZoneTemplate) -> ZoneLayoutConfig {
        var c = configs[template] ?? ZoneLayoutConfig.defaults(for: template)
        c.regenerateZones()
        return c
    }

    /// Persist a new config for a template. If the template is the
    /// active one, the next drag-snap immediately uses the new zones.
    ///
    /// Enforces mutual exclusivity per orientation default: if the
    /// user just starred this template as "default for horizontal"
    /// (or vertical), unstar every other template for the same
    /// orientation so the per-screen lookup has a unique winner.
    func updateConfig(for template: ZoneTemplate, _ config: ZoneLayoutConfig) {
        var c = config
        c.regenerateZones()
        configs[template] = c
        if c.defaultHorizontal {
            for (otherTemplate, otherCfg) in configs where otherTemplate != template && otherCfg.defaultHorizontal {
                var clone = otherCfg
                clone.defaultHorizontal = false
                configs[otherTemplate] = clone
            }
        }
        if c.defaultVertical {
            for (otherTemplate, otherCfg) in configs where otherTemplate != template && otherCfg.defaultVertical {
                var clone = otherCfg
                clone.defaultVertical = false
                configs[otherTemplate] = clone
            }
        }
        saveLayouts()
    }

    /// Activate a built-in template. Used by the editor's "tap card"
    /// gesture.
    func activateTemplate(_ template: ZoneTemplate) {
        activeLayoutRef = .template(template)
        if configs[template] == nil {
            configs[template] = ZoneLayoutConfig.defaults(for: template)
        }
        saveLayouts()
    }

    /// Activate a user-drawn custom layout by id.
    func activateCustomLayout(_ id: UUID) {
        guard customLayouts.contains(where: { $0.id == id }) else { return }
        activeLayoutRef = .custom(id)
        saveLayouts()
    }

    /// Add a freshly-built custom layout to the persisted list and
    /// make it active. Called by the splitter UI on Save.
    func addCustomLayout(_ layout: CustomLayout) {
        customLayouts.append(layout)
        activeLayoutRef = .custom(layout.id)
        saveLayouts()
    }

    /// Update an existing custom layout in place (e.g. user opened
    /// the splitter again on a saved layout and tweaked it).
    func updateCustomLayout(_ layout: CustomLayout) {
        guard let idx = customLayouts.firstIndex(where: { $0.id == layout.id }) else { return }
        customLayouts[idx] = layout
        saveLayouts()
    }

    /// Permanently delete a custom layout. If it was active, falls
    /// back to the Columns template so the snap path keeps working.
    func deleteCustomLayout(_ id: UUID) {
        customLayouts.removeAll { $0.id == id }
        if case .custom(let active) = activeLayoutRef, active == id {
            activeLayoutRef = .template(.columns)
        }
        saveLayouts()
    }

    // MARK: - Persistence

    private struct PersistedState: Codable {
        let activeLayoutRef: ActiveLayout?
        // Old field, kept Optional so legacy files still decode.
        let activeTemplate: String?
        let configs: [String: ZoneLayoutConfig]
        let customLayouts: [CustomLayout]?
    }

    private var layoutsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fancyzones_layouts.json")
    }

    private func loadLayouts() {
        guard
            let data = try? Data(contentsOf: layoutsURL),
            let saved = try? JSONDecoder().decode(PersistedState.self, from: data)
        else {
            activeLayoutRef = .template(.columns)
            configs = [:]
            customLayouts = []
            return
        }
        // Prefer the new field; fall back to the legacy `activeTemplate`
        // string for files written before custom layouts existed.
        if let ref = saved.activeLayoutRef {
            activeLayoutRef = ref
        } else if let legacy = saved.activeTemplate.flatMap(ZoneTemplate.init(rawValue:)) {
            activeLayoutRef = .template(legacy)
        } else {
            activeLayoutRef = .template(.columns)
        }
        var rebuilt: [ZoneTemplate: ZoneLayoutConfig] = [:]
        for (key, value) in saved.configs {
            guard let t = ZoneTemplate(rawValue: key) else { continue }
            var c = value
            c.regenerateZones()
            rebuilt[t] = c
        }
        configs = rebuilt
        customLayouts = saved.customLayouts ?? []
    }

    private func saveLayouts() {
        let state = PersistedState(
            activeLayoutRef: activeLayoutRef,
            activeTemplate: nil,
            configs: Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value) }),
            customLayouts: customLayouts
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: layoutsURL)
        }
    }

}

// MARK: - Active layout reference

/// Tagged union of "what is currently active" — either one of the
/// built-in templates, or a user-drawn custom layout (identified by
/// UUID). Stored on the module + persisted to disk.
enum ActiveLayout: Codable, Equatable {
    case template(ZoneTemplate)
    case custom(UUID)
}

// MARK: - Custom layout

/// User-authored layout drawn with the splitter UI. Holds the raw
/// `[ZoneDefinition]` directly because there's no template generator
/// to call — the zones come straight from the splitter clicks.
struct CustomLayout: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var zones: [ZoneDefinition]
    var spaceAroundEnabled: Bool
    var spaceAroundPixels: Int
    var highlightDistance: Int
    var defaultHorizontal: Bool
    var defaultVertical: Bool

    init(
        id: UUID = UUID(),
        name: String,
        zones: [ZoneDefinition],
        spaceAroundEnabled: Bool = true,
        spaceAroundPixels: Int = 16,
        highlightDistance: Int = 20,
        defaultHorizontal: Bool = false,
        defaultVertical: Bool = false
    ) {
        self.id = id
        self.name = name
        self.zones = zones
        self.spaceAroundEnabled = spaceAroundEnabled
        self.spaceAroundPixels = spaceAroundPixels
        self.highlightDistance = highlightDistance
        self.defaultHorizontal = defaultHorizontal
        self.defaultVertical = defaultVertical
    }

    /// Adapter — wraps the custom layout in the same shape templates
    /// produce so call sites that already consume `ZoneLayoutConfig`
    /// don't need to fork.
    func asZoneLayoutConfig() -> ZoneLayoutConfig {
        ZoneLayoutConfig(
            id: id.uuidString,
            template: .none,
            zoneCount: zones.count,
            spaceAroundEnabled: spaceAroundEnabled,
            spaceAroundPixels: spaceAroundPixels,
            highlightDistance: highlightDistance,
            zones: zones,
            defaultHorizontal: defaultHorizontal,
            defaultVertical: defaultVertical
        )
    }
}

// MARK: - Zone Data Models

struct ZoneRect: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var origin: CGPoint {
        CGPoint(x: x, y: y)
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

struct ZoneDefinition: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var rect: ZoneRect

    init(name: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.id = UUID().uuidString
        self.name = name
        self.rect = ZoneRect(x: x, y: y, width: width, height: height)
    }
}

/// FancyZones template — one of the six PowerToys-style options.
/// The actual zones for each template are generated from a (template,
/// zoneCount) pair via `generateZones(...)` so the user can tune the
/// count from the editor without us having to maintain a separate
/// hard-coded zone array per option.
enum ZoneTemplate: String, Codable, CaseIterable, Identifiable {
    case none, focus, columns, rows, grid, priorityGrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:         return "No layout"
        case .focus:        return "Focus"
        case .columns:      return "Columns"
        case .rows:         return "Rows"
        case .grid:         return "Grid"
        case .priorityGrid: return "Priority Grid"
        }
    }

    var defaultZoneCount: Int {
        switch self {
        case .none:         return 0
        case .focus:        return 1
        case .columns:      return 3
        case .rows:         return 3
        case .grid:         return 4
        case .priorityGrid: return 3
        }
    }

    /// True when the editor should allow tweaking the zone count.
    /// "None" and "Focus" don't — they have fixed semantics.
    var supportsZoneCount: Bool {
        switch self {
        case .none, .focus: return false
        default:            return true
        }
    }

    /// Produce the zones for a given count. All coordinates are
    /// normalised (0…1) over the working screen rect.
    static func generateZones(template: ZoneTemplate, count: Int) -> [ZoneDefinition] {
        let n = max(1, min(8, count))
        switch template {
        case .none:
            return []
        case .focus:
            // One large centred zone, 80% of the screen.
            return [ZoneDefinition(name: "Focus", x: 0.10, y: 0.10, width: 0.80, height: 0.80)]
        case .columns:
            let w = 1.0 / CGFloat(n)
            return (0..<n).map { i in
                ZoneDefinition(name: "Column \(i + 1)",
                               x: CGFloat(i) * w, y: 0, width: w, height: 1.0)
            }
        case .rows:
            let h = 1.0 / CGFloat(n)
            return (0..<n).map { i in
                ZoneDefinition(name: "Row \(i + 1)",
                               x: 0, y: CGFloat(i) * h, width: 1.0, height: h)
            }
        case .grid:
            let (rows, cols) = gridShape(for: n)
            let w = 1.0 / CGFloat(cols)
            let h = 1.0 / CGFloat(rows)
            return (0..<n).map { i in
                let r = i / cols
                let c = i % cols
                return ZoneDefinition(
                    name: "Zone \(i + 1)",
                    x: CGFloat(c) * w,
                    y: CGFloat(r) * h,
                    width: w,
                    height: h
                )
            }
        case .priorityGrid:
            // Wide middle, narrow sides — matches PowerToys' Priority
            // Grid for n=3 (≈22.5 / 55 / 22.5). For larger n we split
            // the side area into more strips of equal width.
            if n == 1 { return [ZoneDefinition(name: "Main", x: 0, y: 0, width: 1, height: 1)] }
            if n == 2 {
                return [
                    ZoneDefinition(name: "Side", x: 0,    y: 0, width: 0.30, height: 1),
                    ZoneDefinition(name: "Main", x: 0.30, y: 0, width: 0.70, height: 1),
                ]
            }
            let center: CGFloat = 0.55
            let sideTotal = (1.0 - center) / 2
            let leftCount = (n - 1) / 2
            let rightCount = (n - 1) - leftCount
            var zones: [ZoneDefinition] = []
            if leftCount > 0 {
                let stripW = sideTotal / CGFloat(leftCount)
                for i in 0..<leftCount {
                    zones.append(ZoneDefinition(
                        name: "Side",
                        x: CGFloat(i) * stripW,
                        y: 0,
                        width: stripW,
                        height: 1
                    ))
                }
            }
            zones.append(ZoneDefinition(name: "Main",
                                        x: sideTotal, y: 0,
                                        width: center, height: 1))
            if rightCount > 0 {
                let stripW = sideTotal / CGFloat(rightCount)
                for i in 0..<rightCount {
                    zones.append(ZoneDefinition(
                        name: "Side",
                        x: sideTotal + center + CGFloat(i) * stripW,
                        y: 0,
                        width: stripW,
                        height: 1
                    ))
                }
            }
            return zones
        }
    }

    /// Rough rows × cols pairing for the Grid template. Picked to
    /// match common workspace shapes (4 → 2×2, 6 → 2×3, etc.).
    private static func gridShape(for n: Int) -> (rows: Int, cols: Int) {
        switch n {
        case 1:     return (1, 1)
        case 2:     return (1, 2)
        case 3:     return (1, 3)
        case 4:     return (2, 2)
        case 5, 6:  return (2, 3)
        case 7, 8:  return (2, 4)
        default:    return (3, 3)
        }
    }
}

/// One persisted layout config — there's exactly one of these per
/// template. The zones array is regenerated from (template, zoneCount)
/// each time params change so the on-disk shape stays small and
/// self-consistent.
struct ZoneLayoutConfig: Codable, Identifiable, Equatable {
    let id: String              // = template.rawValue
    var template: ZoneTemplate
    var zoneCount: Int
    var spaceAroundEnabled: Bool
    var spaceAroundPixels: Int
    var highlightDistance: Int
    var zones: [ZoneDefinition]
    /// User-marked defaults (PowerToys-style star toggles). We
    /// persist them for future multi-monitor work even though the
    /// current snap path always uses `activeTemplate`.
    var defaultHorizontal: Bool
    var defaultVertical: Bool

    var name: String { template.displayName }

    static func defaults(for template: ZoneTemplate) -> ZoneLayoutConfig {
        var c = ZoneLayoutConfig(
            id: template.rawValue,
            template: template,
            zoneCount: template.defaultZoneCount,
            spaceAroundEnabled: true,
            spaceAroundPixels: 16,
            highlightDistance: 20,
            zones: [],
            defaultHorizontal: false,
            defaultVertical: false
        )
        c.regenerateZones()
        return c
    }

    mutating func regenerateZones() {
        zones = ZoneTemplate.generateZones(template: template, count: zoneCount)
    }
}

// MARK: - Zone Overlay View

final class ZoneOverlayView: NSView {
    var zones: [ZoneDefinition] = []
    /// Padding around each zone in screen points — matches the
    /// "Space around zones" slider in the editor. Snap calculations
    /// inset by the same amount so what you see is what you get.
    var spaceAroundPixels: CGFloat = 4
    var screenFrame: CGRect = .zero
    var highlightedZone: Int? = nil

    /// Zones are stored with TOP-LEFT origin (y=0 = top of screen) to
    /// match how the splitter UI authors them. Flipping the view lets
    /// us draw zone rects directly without inverting Y everywhere.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        let inset = max(2, spaceAroundPixels)
        for (index, zone) in zones.enumerated() {
            let rect = CGRect(
                x: zone.rect.origin.x * bounds.width,
                y: zone.rect.origin.y * bounds.height,
                width: zone.rect.width * bounds.width,
                height: zone.rect.height * bounds.height
            ).insetBy(dx: inset, dy: inset)

            let isHighlighted = highlightedZone == index

            // Non-highlighted: faint blue chrome — "here are the
            // available zones". Highlighted: Forge red "about to
            // drop here" so the user gets unambiguous feedback that
            // releasing now will snap the window to THIS rect.
            let fillColor = isHighlighted
                ? NSColor(red: 0.91, green: 0.16, blue: 0.012, alpha: 0.30)
                : NSColor.systemBlue.withAlphaComponent(0.10)
            let borderColor = isHighlighted
                ? NSColor(red: 0.91, green: 0.16, blue: 0.012, alpha: 0.95)
                : NSColor.systemBlue.withAlphaComponent(0.40)

            let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            // Glow on the highlighted zone — the user's eye locks on
            // it from anywhere on the screen.
            if isHighlighted {
                context.saveGState()
                context.setShadow(
                    offset: .zero,
                    blur: 14,
                    color: NSColor(red: 0.91, green: 0.16, blue: 0.012, alpha: 0.6).cgColor
                )
                context.setFillColor(fillColor.cgColor)
                context.addPath(path)
                context.fillPath()
                context.restoreGState()
            } else {
                context.setFillColor(fillColor.cgColor)
                context.addPath(path)
                context.fillPath()
            }

            context.setStrokeColor(borderColor.cgColor)
            context.setLineWidth(isHighlighted ? 3.5 : 2)
            context.addPath(path)
            context.strokePath()

            // Zone label
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(isHighlighted ? 0.9 : 0.5)
            ]
            let label = NSAttributedString(string: zone.name, attributes: attrs)
            let labelSize = label.size()
            label.draw(at: NSPoint(
                x: rect.midX - labelSize.width / 2,
                y: rect.midY - labelSize.height / 2
            ))

            // Zone number badge
            let numAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.6)
            ]
            let numLabel = NSAttributedString(string: "\(index + 1)", attributes: numAttrs)
            let numSize = numLabel.size()
            let badgeRect = NSRect(x: rect.minX + 10, y: rect.maxY - numSize.height - 14, width: numSize.width + 12, height: numSize.height + 6)
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
            NSColor(calibratedWhite: 0.2, alpha: 0.7).setFill()
            badgePath.fill()
            numLabel.draw(at: NSPoint(x: badgeRect.minX + 6, y: badgeRect.minY + 3))
        }
    }
}

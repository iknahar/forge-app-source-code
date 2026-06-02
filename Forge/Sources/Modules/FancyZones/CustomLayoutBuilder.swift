import AppKit
import SwiftUI

// MARK: - Public entry point

/// Full-screen splitter overlay used to author a `CustomLayout`. The
/// PowerToys analog: the user hovers, sees a tracking line in the
/// direction of the next split, clicks to commit, repeats. Once
/// committed, resizers between adjacent zones can be dragged or
/// moved with the keyboard.
///
/// Interaction contract (matches the user's spec):
///   • Hover           → red horizontal suggestion line at the cursor.
///   • Hold Shift      → suggestion flips to a vertical line.
///   • Click           → commits the current suggestion as a split.
///   • Drag a resizer  → move the shared edge between adjacent zones.
///   • Tab / ⇧Tab      → cycle focus through zones and resizers.
///   • Arrow keys      → nudge the focused resizer 1% at a time.
///   • Delete          → merge the two zones the focused resizer
///                       separates.
///   • Enter           → name + save the layout.
///   • Esc             → cancel without saving.
enum CustomLayoutBuilder {
    /// Open the splitter on the screen the cursor is currently on.
    /// `onSave` is called with the finished layout (after the user
    /// types a name); `onCancel` fires when they bail.
    static func open(
        editing existing: CustomLayout? = nil,
        onSave: @escaping (CustomLayout) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
                ?? NSScreen.main
        else { onCancel(); return }

        let panel = CustomLayoutBuilderWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.setFrame(screen.frame, display: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let view = CustomLayoutBuilderView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.initialZones = existing?.zones
        view.existingName = existing?.name
        view.editingId = existing?.id
        view.onSave = { layout in
            panel.orderOut(nil)
            onSave(layout)
        }
        view.onCancel = {
            panel.orderOut(nil)
            onCancel()
        }
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Panel

/// Borderless panel that's allowed to become key so the view can
/// receive keyboard events (Tab / arrow keys / Delete / Enter / Esc).
final class CustomLayoutBuilderWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - The actual splitter view

final class CustomLayoutBuilderView: NSView {

    // MARK: Configuration

    /// If set, pre-load the splitter with these zones (editing path).
    var initialZones: [ZoneDefinition]?
    /// Carried through to the saved CustomLayout when editing.
    var existingName: String?
    var editingId: UUID?

    var onSave: ((CustomLayout) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: State

    /// All zones, normalised 0…1 over the screen rect. Starts as one
    /// zone covering the whole screen; each split divides one zone
    /// into two.
    private var zones: [NormalisedZone] = [
        NormalisedZone(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    ]

    /// Tracking suggestion that follows the cursor. `nil` when the
    /// cursor isn't inside any zone.
    private var suggestion: SuggestionLine?

    /// True while Shift is held — flips suggestion orientation.
    private var shiftHeld: Bool = false

    /// Tab focus cycles through all zones then all resizers. nil =
    /// no focus.
    private var focus: Focus? = nil

    /// Resizer the cursor is currently hovering over — drawn brighter
    /// + thicker so the user discovers the drag handle even before
    /// they click.
    private var hoveredResizerId: String?

    /// Resizer currently being dragged with the mouse, plus the
    /// initial cursor position so we can keep it under the mouse.
    private var dragState: DragState?

    /// Reference to the floating help card — kept so the splitter
    /// can gate its own mouse handling whenever the cursor is over
    /// the card (no suggestion line, no resizer hover, no
    /// accidental split-on-click behind the card).
    private weak var helpCard: SplitterHelpCardView?

    /// Tracking area refreshed on `updateTrackingAreas()` so we get
    /// `mouseMoved` events without requiring a click first.
    private var trackingArea: NSTrackingArea?

    // MARK: Constants

    /// Minimum normalised zone dimension (≈ 2% of the screen) — keeps
    /// the user from creating sliver zones that snap to nothing.
    private let minZoneExtent: CGFloat = 0.02
    private let arrowNudge: CGFloat = 0.01
    private let resizerHotZone: CGFloat = 14   // pt; how close to an edge to "grab" it
    private let strokeWidth: CGFloat = 2

    // MARK: First-responder + tracking

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let z = initialZones, !z.isEmpty {
            zones = z.map { NormalisedZone(rect: $0.rect.cgRect) }
        }
        installHelpCard()
        window?.makeFirstResponder(self)
    }

    /// Install (or reposition) the floating help card. The card hosts
    /// the Save + Cancel buttons and can be dragged out of the way.
    private func installHelpCard() {
        // Centre horizontally, anchored ~60pt from the top so it's
        // visible without sitting on the most-likely first-split
        // target. The user can drag it anywhere from there.
        let cardSize = NSSize(width: 400, height: 320)
        let origin = NSPoint(
            x: bounds.midX - cardSize.width / 2,
            y: bounds.maxY - cardSize.height - 60
        )
        let card = SplitterHelpCardView(frame: NSRect(origin: origin, size: cardSize))
        card.onSave = { [weak self] in self?.promptSaveName() }
        card.onCancel = { [weak self] in self?.onCancel?() }
        addSubview(card)
        helpCard = card
    }

    /// True when `point` (splitter-local coords) lands inside the
    /// floating help card. Splitter mouse handlers consult this so
    /// clicks + hovers on the card don't bleed into split / hover
    /// behavior behind it.
    private func isOverHelpCard(_ point: NSPoint) -> Bool {
        guard let card = helpCard else { return false }
        return card.frame.contains(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // The floating help card is the PRIMARY interaction target
        // whenever the cursor is over it — no suggestion line, no
        // resizer hover, no cursor change from us. The card's own
        // tracking + cursor rects take over.
        if isOverHelpCard(p) {
            if suggestion != nil { suggestion = nil; needsDisplay = true }
            if hoveredResizerId != nil { hoveredResizerId = nil; needsDisplay = true }
            return
        }

        // Hover-test against resizers first — when the cursor is on
        // one, suppress the split suggestion (the user is heading
        // toward a drag, not a split) and swap the cursor to the
        // appropriate resize icon.
        if let resizer = resizerHit(at: p) {
            if hoveredResizerId != resizer.id {
                hoveredResizerId = resizer.id
            }
            suggestion = nil
            switch resizer.orientation {
            case .horizontal: NSCursor.resizeUpDown.set()
            case .vertical:   NSCursor.resizeLeftRight.set()
            }
        } else {
            if hoveredResizerId != nil { hoveredResizerId = nil }
            NSCursor.crosshair.set()
            updateSuggestion(at: p)
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredResizerId = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        let newShift = event.modifierFlags.contains(.shift)
        if newShift != shiftHeld {
            shiftHeld = newShift
            if let win = window {
                let p = convert(win.mouseLocationOutsideOfEventStream, from: nil)
                updateSuggestion(at: p)
            }
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // If the click is on the help card the card subview already
        // intercepted it via hitTest — but defend against missed
        // routing (e.g. user clicks the card's outer 1pt border).
        if isOverHelpCard(p) { return }

        // Did we click on an existing resizer? Then start a drag.
        if let resizer = resizerHit(at: p) {
            dragState = DragState(resizer: resizer, lastPoint: p)
            focus = .resizer(resizer.id)
            needsDisplay = true
            return
        }

        // Otherwise commit the current suggestion as a split.
        commitSuggestionSplit(at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var state = dragState else {
            // Without an active drag we still want to keep the
            // suggestion line moving so the user gets feedback when
            // sweeping with the button held.
            mouseMoved(with: event)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        moveResizer(state.resizer, to: p)
        state.lastPoint = p
        dragState = state
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragState = nil
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                                                       // Esc
            onCancel?()
        case 36, 76:                                                   // Return / Enter
            promptSaveName()
        case 48:                                                       // Tab
            advanceFocus(forward: !event.modifierFlags.contains(.shift))
            needsDisplay = true
        case 51, 117:                                                  // Delete / Forward Delete
            // Works on both kinds of focus: a focused resizer is
            // removed and its neighbours merged; a focused zone is
            // merged into the nearest neighbour. Both fall back to
            // a beep when geometry doesn't allow a clean merge.
            switch focus {
            case .resizer: deleteFocusedResizer()
            case .zone:    deleteFocusedZone()
            case .none:    NSSound.beep()
            }
        case 123, 124, 125, 126:                                       // ← → ↓ ↑
            nudgeFocusedResizer(keyCode: event.keyCode,
                                shifted: event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Suggestion

    private func updateSuggestion(at point: NSPoint) {
        guard bounds.contains(point), let zoneIndex = zoneIndex(at: point) else {
            suggestion = nil
            return
        }
        let zone = zones[zoneIndex]
        let zoneRect = zone.absoluteRect(in: bounds)
        if shiftHeld {
            suggestion = SuggestionLine(
                orientation: .vertical,
                position: point.x,
                bounds: zoneRect,
                zoneIndex: zoneIndex
            )
        } else {
            suggestion = SuggestionLine(
                orientation: .horizontal,
                position: point.y,
                bounds: zoneRect,
                zoneIndex: zoneIndex
            )
        }
    }

    /// Commit the current `suggestion` as an actual zone split.
    private func commitSuggestionSplit(at point: NSPoint) {
        guard let suggestion else { return }
        let zone = zones[suggestion.zoneIndex]
        let zr = zone.rect

        switch suggestion.orientation {
        case .horizontal:
            // Convert absolute y back to normalised; flip to top-down so
            // the user's "top is smaller y" mental model matches our
            // top-left rect coords.
            let yNorm = 1.0 - (point.y / bounds.height)
            let cutInZone = yNorm - zr.minY
            let topHeight = cutInZone
            let bottomHeight = zr.height - cutInZone
            guard topHeight >= minZoneExtent, bottomHeight >= minZoneExtent else { return }
            let top = NormalisedZone(rect: CGRect(x: zr.minX, y: zr.minY,
                                                  width: zr.width, height: topHeight))
            let bottom = NormalisedZone(rect: CGRect(x: zr.minX, y: zr.minY + topHeight,
                                                     width: zr.width, height: bottomHeight))
            zones[suggestion.zoneIndex] = top
            zones.append(bottom)

        case .vertical:
            let xNorm = point.x / bounds.width
            let cutInZone = xNorm - zr.minX
            let leftWidth = cutInZone
            let rightWidth = zr.width - cutInZone
            guard leftWidth >= minZoneExtent, rightWidth >= minZoneExtent else { return }
            let left = NormalisedZone(rect: CGRect(x: zr.minX, y: zr.minY,
                                                   width: leftWidth, height: zr.height))
            let right = NormalisedZone(rect: CGRect(x: zr.minX + leftWidth, y: zr.minY,
                                                    width: rightWidth, height: zr.height))
            zones[suggestion.zoneIndex] = left
            zones.append(right)
        }
        focus = .zone(zones.count - 1)
        needsDisplay = true
    }

    // MARK: Resizers

    /// Derive resizers from the current zone list. Two zones share a
    /// resizer when one's bottom edge equals another's top edge (or
    /// right equals left) AND their perpendicular ranges overlap.
    private var resizers: [Resizer] {
        var out: [Resizer] = []
        // Horizontal resizers (shared between top + bottom neighbours).
        for i in zones.indices {
            for j in zones.indices where j != i {
                let a = zones[i].rect
                let b = zones[j].rect
                if abs(a.maxY - b.minY) < 0.0005 {
                    let lo = max(a.minX, b.minX)
                    let hi = min(a.maxX, b.maxX)
                    if hi - lo > 0.0005 {
                        let id = "H\(round(a.maxY * 10000))-\(round(lo * 10000))-\(round(hi * 10000))"
                        if !out.contains(where: { $0.id == id }) {
                            out.append(Resizer(
                                id: id,
                                orientation: .horizontal,
                                position: a.maxY,
                                rangeMin: lo,
                                rangeMax: hi,
                                topOrLeftZones: zones.indices.filter { abs(zones[$0].rect.maxY - a.maxY) < 0.0005
                                                                       && rangesOverlap(zones[$0].rect.minX, zones[$0].rect.maxX, lo, hi) },
                                bottomOrRightZones: zones.indices.filter { abs(zones[$0].rect.minY - a.maxY) < 0.0005
                                                                            && rangesOverlap(zones[$0].rect.minX, zones[$0].rect.maxX, lo, hi) }
                            ))
                        }
                    }
                }
                if abs(a.maxX - b.minX) < 0.0005 {
                    let lo = max(a.minY, b.minY)
                    let hi = min(a.maxY, b.maxY)
                    if hi - lo > 0.0005 {
                        let id = "V\(round(a.maxX * 10000))-\(round(lo * 10000))-\(round(hi * 10000))"
                        if !out.contains(where: { $0.id == id }) {
                            out.append(Resizer(
                                id: id,
                                orientation: .vertical,
                                position: a.maxX,
                                rangeMin: lo,
                                rangeMax: hi,
                                topOrLeftZones: zones.indices.filter { abs(zones[$0].rect.maxX - a.maxX) < 0.0005
                                                                       && rangesOverlap(zones[$0].rect.minY, zones[$0].rect.maxY, lo, hi) },
                                bottomOrRightZones: zones.indices.filter { abs(zones[$0].rect.minX - a.maxX) < 0.0005
                                                                            && rangesOverlap(zones[$0].rect.minY, zones[$0].rect.maxY, lo, hi) }
                            ))
                        }
                    }
                }
            }
        }
        return out
    }

    private func rangesOverlap(_ aMin: CGFloat, _ aMax: CGFloat, _ bMin: CGFloat, _ bMax: CGFloat) -> Bool {
        max(aMin, bMin) < min(aMax, bMax)
    }

    private func resizerHit(at point: NSPoint) -> Resizer? {
        for resizer in resizers {
            let rect = resizer.absoluteRect(in: bounds)
            if rect.insetBy(dx: -resizerHotZone, dy: -resizerHotZone).contains(point) {
                return resizer
            }
        }
        return nil
    }

    private func moveResizer(_ resizer: Resizer, to point: NSPoint) {
        // Recompute target normalised position from the cursor.
        let newPos: CGFloat
        switch resizer.orientation {
        case .horizontal:
            newPos = 1.0 - (point.y / bounds.height)
        case .vertical:
            newPos = point.x / bounds.width
        }
        applyResizerPosition(resizer, to: newPos)
    }

    private func applyResizerPosition(_ resizer: Resizer, to newPos: CGFloat) {
        // Clamp so neither side of the resizer collapses below the
        // minimum extent.
        var maxTopOrLeft: CGFloat = 0
        var minBottomOrRight: CGFloat = 1
        switch resizer.orientation {
        case .horizontal:
            for i in resizer.topOrLeftZones {
                maxTopOrLeft = max(maxTopOrLeft, zones[i].rect.minY)
            }
            for i in resizer.bottomOrRightZones {
                minBottomOrRight = min(minBottomOrRight, zones[i].rect.maxY)
            }
        case .vertical:
            for i in resizer.topOrLeftZones {
                maxTopOrLeft = max(maxTopOrLeft, zones[i].rect.minX)
            }
            for i in resizer.bottomOrRightZones {
                minBottomOrRight = min(minBottomOrRight, zones[i].rect.maxX)
            }
        }
        let clamped = min(max(newPos, maxTopOrLeft + minZoneExtent),
                          minBottomOrRight - minZoneExtent)

        // Apply to all zones touching the resizer.
        switch resizer.orientation {
        case .horizontal:
            for i in resizer.topOrLeftZones {
                let r = zones[i].rect
                zones[i] = NormalisedZone(rect: CGRect(x: r.minX, y: r.minY,
                                                       width: r.width, height: clamped - r.minY))
            }
            for i in resizer.bottomOrRightZones {
                let r = zones[i].rect
                zones[i] = NormalisedZone(rect: CGRect(x: r.minX, y: clamped,
                                                       width: r.width, height: r.maxY - clamped))
            }
        case .vertical:
            for i in resizer.topOrLeftZones {
                let r = zones[i].rect
                zones[i] = NormalisedZone(rect: CGRect(x: r.minX, y: r.minY,
                                                       width: clamped - r.minX, height: r.height))
            }
            for i in resizer.bottomOrRightZones {
                let r = zones[i].rect
                zones[i] = NormalisedZone(rect: CGRect(x: clamped, y: r.minY,
                                                       width: r.maxX - clamped, height: r.height))
            }
        }
        needsDisplay = true
    }

    private func nudgeFocusedResizer(keyCode: UInt16, shifted: Bool) {
        guard case .resizer(let id) = focus,
              let resizer = resizers.first(where: { $0.id == id })
        else { return }

        let step = shifted ? arrowNudge * 5 : arrowNudge
        var newPos = resizer.position
        switch (keyCode, resizer.orientation) {
        case (123, .vertical):  newPos -= step           // ← left
        case (124, .vertical):  newPos += step           // → right
        case (125, .horizontal): newPos += step          // ↓ down
        case (126, .horizontal): newPos -= step          // ↑ up
        default: return
        }
        applyResizerPosition(resizer, to: newPos)
    }

    private func deleteFocusedResizer() {
        guard case .resizer(let id) = focus,
              let resizer = resizers.first(where: { $0.id == id })
        else { return }
        if mergeAcross(resizer: resizer) {
            focus = nil
            needsDisplay = true
        }
    }

    /// Delete a focused zone — there's no single resizer to remove,
    /// so we look for a neighbour the zone can be cleanly merged
    /// with. Tries every resizer that touches the focused zone and
    /// commits the first one that produces a valid rectangle.
    private func deleteFocusedZone() {
        guard case .zone(let idx) = focus else { return }
        // Find resizers that touch this zone (it's on either side).
        let touching = resizers.filter {
            $0.topOrLeftZones.contains(idx) || $0.bottomOrRightZones.contains(idx)
        }
        for resizer in touching {
            if mergeAcross(resizer: resizer) {
                focus = nil
                needsDisplay = true
                return
            }
        }
        // No clean merge possible — beep so the user knows the press
        // registered but couldn't act on it.
        NSSound.beep()
    }

    /// Shared merge primitive used by both the resizer-delete and
    /// zone-delete paths. Returns `true` when the merge succeeded.
    /// Skips silently when the union of the touching zones isn't
    /// itself a rectangle (e.g. three zones meeting at a T) so we
    /// don't silently drop content.
    @discardableResult
    private func mergeAcross(resizer: Resizer) -> Bool {
        let touching = Set(resizer.topOrLeftZones + resizer.bottomOrRightZones)
        guard let firstIndex = touching.first, zones.indices.contains(firstIndex) else { return false }

        var unionRect: CGRect = zones[firstIndex].rect
        for i in touching { unionRect = unionRect.union(zones[i].rect) }

        let totalArea = touching.reduce(CGFloat(0)) {
            $0 + zones[$1].rect.width * zones[$1].rect.height
        }
        let unionArea = unionRect.width * unionRect.height
        guard abs(totalArea - unionArea) < 0.0005 else { return false }

        for i in touching.sorted(by: >) {
            zones.remove(at: i)
        }
        zones.append(NormalisedZone(rect: unionRect))
        return true
    }

    // MARK: Focus cycling

    private func advanceFocus(forward: Bool) {
        // Order: zones first (by index), then resizers.
        let zoneIds: [Focus] = zones.indices.map { .zone($0) }
        let resizerIds: [Focus] = resizers.map { .resizer($0.id) }
        let ordered = zoneIds + resizerIds
        guard !ordered.isEmpty else { return }
        if let current = focus, let idx = ordered.firstIndex(where: { $0 == current }) {
            let next = (idx + (forward ? 1 : -1) + ordered.count) % ordered.count
            focus = ordered[next]
        } else {
            focus = ordered.first
        }
    }

    private func zoneIndex(at point: NSPoint) -> Int? {
        let normX = point.x / bounds.width
        let normY = 1.0 - (point.y / bounds.height)
        for (i, zone) in zones.enumerated() {
            if zone.rect.contains(CGPoint(x: normX, y: normY)) {
                return i
            }
        }
        return nil
    }

    // MARK: Save flow

    private func promptSaveName() {
        let alert = NSAlert()
        alert.messageText = "Name your layout"
        alert.informativeText = "Custom layouts appear in FancyZones alongside the built-in templates."
        let field = NSTextField(string: existingName ?? "My Layout")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        // The splitter panel sits at `.screenSaver` level (1000) so it
        // floats above almost everything. `NSAlert.runModal()` puts
        // its window at the default `.modalPanel` level (8), which
        // means the alert spawns BEHIND our overlay and the user
        // can't see or click it. Two-step fix:
        //   1. Lower our panel's level while the modal is up so the
        //      alert sits naturally above us.
        //   2. Also bump the alert window's own level above our
        //      restored screenSaver level — belt-and-braces for any
        //      cases where step 1's drop isn't honored before the
        //      modal opens.
        let savedLevel = window?.level
        window?.level = .normal
        alert.window.level = NSWindow.Level(
            rawValue: NSWindow.Level.screenSaver.rawValue + 1
        )
        let response = alert.runModal()
        window?.level = savedLevel ?? .screenSaver

        guard response == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let layoutName = name.isEmpty ? "Custom Layout" : name

        // Convert internal zones to CalendarModule-flavoured
        // ZoneDefinition (the model FancyZones already consumes).
        let definitions: [ZoneDefinition] = zones.enumerated().map { i, z in
            ZoneDefinition(
                name: "Zone \(i + 1)",
                x: z.rect.minX,
                y: z.rect.minY,
                width: z.rect.width,
                height: z.rect.height
            )
        }
        let saved = CustomLayout(
            id: editingId ?? UUID(),
            name: layoutName,
            zones: definitions
        )
        onSave?(saved)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        // 1. Dim veil so the desktop is still visible behind. Matches
        //    the user's reference (translucent overlay with content
        //    visible through it).
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(bounds)

        // 2. Each zone as a translucent rect with a soft blue tint +
        //    a 1pt outline, focus-aware.
        for (i, zone) in zones.enumerated() {
            let absRect = zone.absoluteRect(in: bounds).insetBy(dx: 4, dy: 4)
            let path = CGPath(roundedRect: absRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            let isFocused = (focus == .zone(i))
            ctx.setFillColor(NSColor.white.withAlphaComponent(isFocused ? 0.18 : 0.08).cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(isFocused ? 0.85 : 0.45).cgColor)
            ctx.setLineWidth(isFocused ? 2.5 : 1.25)
            ctx.addPath(path); ctx.strokePath()

            // Number badge + pixel dimensions under it. The dimensions
            // come straight from the absolute rect so they're the
            // physical size the snapped window will get on this screen.
            // Skip the dimension line for very small zones where it
            // would overflow horizontally.
            let numberLabel = NSAttributedString(
                string: "\(i + 1)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 36, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(isFocused ? 0.95 : 0.55)
                ]
            )
            let dimText = "\(Int(absRect.width)) × \(Int(absRect.height))"
            let dimLabel = NSAttributedString(
                string: dimText,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(isFocused ? 0.85 : 0.45)
                ]
            )
            let numberSize = numberLabel.size()
            let dimSize = dimLabel.size()
            let blockHeight = numberSize.height + 4 + dimSize.height
            let originY = absRect.midY - blockHeight / 2
            numberLabel.draw(at: NSPoint(
                x: absRect.midX - numberSize.width / 2,
                y: originY + dimSize.height + 4
            ))
            if absRect.width > dimSize.width + 16 {
                dimLabel.draw(at: NSPoint(
                    x: absRect.midX - dimSize.width / 2,
                    y: originY
                ))
            }
        }

        // 3. Resizers — always visible + a circular grab puck at
        //    each one's midpoint so the drag handle is obvious. The
        //    puck grows + brightens on hover / focus to match what
        //    the cursor change already implies.
        for resizer in resizers {
            let r = resizer.absoluteRect(in: bounds)
            let isFocused = (focus == .resizer(resizer.id))
            let isHovered = (hoveredResizerId == resizer.id)
            let alpha: CGFloat
            switch (isFocused, isHovered) {
            case (true, _):  alpha = 0.95
            case (_, true):  alpha = 0.75
            default:         alpha = 0.45
            }

            // Line itself
            let pillRadius = min(r.width, r.height) / 2
            let linePath = CGPath(
                roundedRect: r,
                cornerWidth: pillRadius,
                cornerHeight: pillRadius,
                transform: nil
            )
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(alpha).cgColor)
            ctx.addPath(linePath); ctx.fillPath()

            if isFocused || isHovered {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 6, color: NSColor.systemRed.withAlphaComponent(0.5).cgColor)
                ctx.setFillColor(NSColor.systemRed.withAlphaComponent(alpha).cgColor)
                ctx.addPath(linePath); ctx.fillPath()
                ctx.restoreGState()
            }

            // Grab puck — a circle in the middle of the resizer with
            // two small parallel bars inside, perpendicular to the
            // line. Tells the user "you can grab here".
            let puckRadius: CGFloat = (isFocused || isHovered) ? 14 : 11
            let puckCenter = CGPoint(x: r.midX, y: r.midY)
            let puckRect = CGRect(
                x: puckCenter.x - puckRadius,
                y: puckCenter.y - puckRadius,
                width: puckRadius * 2,
                height: puckRadius * 2
            )
            // Glow underneath the puck
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 8,
                          color: NSColor.systemRed.withAlphaComponent(0.6).cgColor)
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.95).cgColor)
            ctx.fillEllipse(in: puckRect)
            ctx.restoreGState()
            // Crisp white border so it pops against any background
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.25)
            ctx.strokeEllipse(in: puckRect.insetBy(dx: 0.6, dy: 0.6))
            // Two parallel grip bars inside, perpendicular to the
            // resizer's axis (vertical resizer ⇒ horizontal bars, and
            // vice versa).
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            let barLength: CGFloat = puckRadius * 0.7
            let barGap: CGFloat = 4
            switch resizer.orientation {
            case .vertical:
                // Resizer is a vertical strip — bars go horizontally.
                for offsetX in [-barGap / 2, barGap / 2] {
                    ctx.move(to: CGPoint(x: puckCenter.x + offsetX, y: puckCenter.y - barLength / 2))
                    ctx.addLine(to: CGPoint(x: puckCenter.x + offsetX, y: puckCenter.y + barLength / 2))
                }
            case .horizontal:
                // Resizer is a horizontal strip — bars go vertically.
                for offsetY in [-barGap / 2, barGap / 2] {
                    ctx.move(to: CGPoint(x: puckCenter.x - barLength / 2, y: puckCenter.y + offsetY))
                    ctx.addLine(to: CGPoint(x: puckCenter.x + barLength / 2, y: puckCenter.y + offsetY))
                }
            }
            ctx.strokePath()
        }

        // 4. The suggestion line — red, glow-y, spans only the
        //    enclosing zone.
        if let suggestion {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: NSColor.systemRed.withAlphaComponent(0.6).cgColor)
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(strokeWidth)
            switch suggestion.orientation {
            case .horizontal:
                ctx.move(to: CGPoint(x: suggestion.bounds.minX + 4, y: suggestion.position))
                ctx.addLine(to: CGPoint(x: suggestion.bounds.maxX - 4, y: suggestion.position))
            case .vertical:
                ctx.move(to: CGPoint(x: suggestion.position, y: suggestion.bounds.minY + 4))
                ctx.addLine(to: CGPoint(x: suggestion.position, y: suggestion.bounds.maxY - 4))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 5. The floating help card is now a real subview (see
        //    `SplitterHelpCardView` below) — it's draggable and hosts
        //    the Save / Cancel buttons. We don't draw it here.
    }
}

// MARK: - Helper types

private struct NormalisedZone {
    /// 0…1 over the screen, top-left origin to match the on-disk
    /// `ZoneDefinition.rect` convention.
    var rect: CGRect

    func absoluteRect(in viewBounds: CGRect) -> CGRect {
        // Convert top-left normalised rect to bottom-left view coords.
        CGRect(
            x: rect.minX * viewBounds.width,
            y: viewBounds.height - (rect.minY + rect.height) * viewBounds.height,
            width: rect.width * viewBounds.width,
            height: rect.height * viewBounds.height
        )
    }
}

private struct SuggestionLine {
    enum Orientation { case horizontal, vertical }
    let orientation: Orientation
    /// Absolute view coordinate (y for horizontal, x for vertical).
    let position: CGFloat
    let bounds: CGRect
    let zoneIndex: Int
}

private struct Resizer {
    enum Orientation { case horizontal, vertical }
    let id: String
    let orientation: Orientation
    /// Normalised (0…1, top-left origin).
    let position: CGFloat
    let rangeMin: CGFloat
    let rangeMax: CGFloat
    /// Indices of zones whose far edge (bottom for horizontal, right
    /// for vertical) is this resizer. They get extended when the
    /// resizer is dragged outward.
    let topOrLeftZones: [Int]
    /// Indices of zones whose near edge (top / left) is this resizer.
    let bottomOrRightZones: [Int]

    /// Convert to absolute view rect for hit-testing + drawing. The
    /// resizer is rendered as an 8pt-thick strip so it reads clearly
    /// against the dim veil, is comfortable to drag, and has room
    /// for the centered grab puck.
    func absoluteRect(in viewBounds: CGRect) -> CGRect {
        let halfWidth: CGFloat = 4
        switch orientation {
        case .horizontal:
            let y = viewBounds.height - position * viewBounds.height
            return CGRect(
                x: rangeMin * viewBounds.width,
                y: y - halfWidth,
                width: (rangeMax - rangeMin) * viewBounds.width,
                height: halfWidth * 2
            )
        case .vertical:
            let x = position * viewBounds.width
            return CGRect(
                x: x - halfWidth,
                y: viewBounds.height - rangeMax * viewBounds.height,
                width: halfWidth * 2,
                height: (rangeMax - rangeMin) * viewBounds.height
            )
        }
    }
}

private enum Focus: Equatable {
    case zone(Int)
    case resizer(String)
}

private struct DragState {
    let resizer: Resizer
    var lastPoint: NSPoint
}

// MARK: - Floating help card

/// Movable Forge-styled card that lists the splitter keyboard hints
/// and hosts Save + Cancel buttons. Lives as a subview of the splitter
/// so it always sits above the zones + suggestion line.
///
/// Interaction model:
///   • Top 44pt is the drag handle — open-hand cursor, mouse-down +
///     drag moves the card.
///   • Anywhere else in the card body is "card territory" — clicks
///     can't bleed through to start a split behind it (the splitter
///     view also gates clicks against the card's frame).
///   • Save (red Forge accent) + Cancel buttons at the bottom. Both
///     register as first-mouse so they fire even when the panel
///     isn't key yet.
final class SplitterHelpCardView: NSView {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    private let dragHandleHeight: CGFloat = 44
    private var isDragging = false
    private var dragOffset: CGPoint = .zero

    private let saveButton = SplitterHelpButton(title: "Save", style: .accent)
    private let cancelButton = SplitterHelpButton(title: "Cancel", style: .secondary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        configureButtons()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        configureButtons()
    }

    // MARK: First-mouse + hit-testing
    //
    // NSPanel + .nonactivatingPanel + .borderless = clicks on subview
    // controls don't fire on the first click unless `acceptsFirstMouse`
    // is true. Set it on the card AND every subview so the user can
    // hit Save / Cancel without an activation click first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Eat every click on the card so the splitter behind never sees
    /// a "make a split here" mouseDown. NSView's default hitTest
    /// already descends into subviews; we just guarantee a non-nil
    /// return whenever the point falls inside our bounds.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let inSelf = convert(point, from: superview)
        guard bounds.contains(inSelf) else { return nil }
        return super.hitTest(point) ?? self
    }

    // MARK: Buttons

    private func configureButtons() {
        let buttonHeight: CGFloat = 30
        let buttonY: CGFloat = 18
        cancelButton.frame = NSRect(x: bounds.width - 198, y: buttonY, width: 88, height: buttonHeight)
        cancelButton.autoresizingMask = [.minXMargin, .maxYMargin]
        cancelButton.keyEquivalent = "\u{1B}"   // Esc
        cancelButton.onTap = { [weak self] in self?.onCancel?() }
        addSubview(cancelButton)

        saveButton.frame = NSRect(x: bounds.width - 102, y: buttonY, width: 88, height: buttonHeight)
        saveButton.autoresizingMask = [.minXMargin, .maxYMargin]
        saveButton.keyEquivalent = "\r"          // Return
        saveButton.onTap = { [weak self] in self?.onSave?() }
        addSubview(saveButton)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // --- Background — Forge surfaceCard in dark mode ---
        // We're always drawing over the dim splitter veil, so use
        // the dark variant of surfaceCard (#242425) with a touch of
        // opacity so the desktop tints through slightly.
        ctx.setFillColor(NSColor(red: 0.141, green: 0.141, blue: 0.145, alpha: 0.96).cgColor)
        ctx.fill(bounds)
        // Hairline border.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))

        // --- Title bar (drag handle) ---
        let handleRect = NSRect(x: 0, y: bounds.maxY - dragHandleHeight,
                                width: bounds.width, height: dragHandleHeight)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.05).cgColor)
        ctx.fill(handleRect)
        // Bottom separator line under the title bar.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: NSPoint(x: 0, y: handleRect.minY + 0.5))
        ctx.addLine(to: NSPoint(x: bounds.width, y: handleRect.minY + 0.5))
        ctx.strokePath()

        // Title + grip dots
        let title = NSAttributedString(
            string: "Splitter",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor.white
            ]
        )
        let titleSize = title.size()
        title.draw(at: NSPoint(x: 18, y: handleRect.midY - titleSize.height / 2))

        // Grip dots, top-right corner of the handle bar — typical
        // "you can drag this" indicator.
        let dotY = handleRect.midY
        for i in 0..<3 {
            let x = bounds.width - 22 - CGFloat(2 - i) * 7
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            ctx.fillEllipse(in: NSRect(x: x - 1.5, y: dotY - 1.5, width: 3, height: 3))
        }

        // --- Hint rows ---
        let lines: [(String, String)] = [
            ("Hover",       "Red horizontal split line"),
            ("Hold Shift",  "Switch to vertical split"),
            ("Click",       "Lock the split"),
            ("Drag a line", "Resize zones"),
            ("Tab / ⇧Tab",  "Cycle zones + resizers"),
            ("← → ↑ ↓",     "Nudge focused resizer"),
            ("Delete",      "Remove focused zone / resizer"),
        ]
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(red: 0.95, green: 0.30, blue: 0.18, alpha: 1) // Forge red on dark
        ]
        let descAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let rowsTop = handleRect.minY - 16
        let rowHeight: CGFloat = 22
        for (i, (key, desc)) in lines.enumerated() {
            let y = rowsTop - CGFloat(i + 1) * rowHeight
            NSAttributedString(string: key, attributes: keyAttrs)
                .draw(at: NSPoint(x: 18, y: y))
            NSAttributedString(string: desc, attributes: descAttrs)
                .draw(at: NSPoint(x: 150, y: y))
        }
    }

    // MARK: Drag

    override func resetCursorRects() {
        super.resetCursorRects()
        let handle = NSRect(x: 0, y: bounds.maxY - dragHandleHeight,
                            width: bounds.width, height: dragHandleHeight)
        addCursorRect(handle, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let handleY = bounds.maxY - dragHandleHeight
        if local.y >= handleY {
            isDragging = true
            dragOffset = NSPoint(
                x: event.locationInWindow.x - frame.origin.x,
                y: event.locationInWindow.y - frame.origin.y
            )
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let parent = superview else { return }
        var origin = NSPoint(
            x: event.locationInWindow.x - dragOffset.x,
            y: event.locationInWindow.y - dragOffset.y
        )
        origin.x = max(8, min(parent.bounds.width - frame.width - 8, origin.x))
        origin.y = max(8, min(parent.bounds.height - frame.height - 8, origin.y))
        setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        NSCursor.openHand.set()
    }
}

// MARK: - Forge-styled button used in the help card
//
// NSButton's built-in chrome doesn't match our dark Forge surfaces;
// the rounded silver bezel jumps out visually. This is a tiny custom
// drawn button that handles its own hover / pressed / focus states
// and lets us paint the red Save CTA exactly the way the rest of
// Forge does (Capsule + accent fill).

final class SplitterHelpButton: NSView {
    enum Style { case accent, secondary }

    var onTap: (() -> Void)?
    var keyEquivalent: String = ""

    private let title: String
    private let style: Style
    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(title: String, style: Style) {
        self.title = title
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        self.title = ""
        self.style = .secondary
        super.init(coder: coder)
    }

    override var wantsDefaultClipping: Bool { false }

    // Take the click without needing the panel to be key first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.openHand.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        needsDisplay = true
        // Fire only when the up-event lands inside us — matches the
        // standard "press, drag away to cancel" UX.
        let local = convert(event.locationInWindow, from: nil)
        if wasPressed, bounds.contains(local) {
            onTap?()
        }
    }

    /// Key-equivalent hookup — the parent card uses these for ↩ and
    /// Esc. We watch the window's performKeyEquivalent path so the
    /// buttons still respond to the keyboard.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !keyEquivalent.isEmpty,
              event.charactersIgnoringModifiers == keyEquivalent
        else { return super.performKeyEquivalent(with: event) }
        onTap?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let radius = bounds.height / 2
        let path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

        let fill: NSColor
        let textColor: NSColor
        switch style {
        case .accent:
            // Forge red accent (#E72903) — slightly darker on press.
            let base = NSColor(red: 0.905, green: 0.16, blue: 0.012, alpha: 1.0)
            if isPressed {
                fill = base.blended(withFraction: 0.20, of: .black) ?? base
            } else if isHovered {
                fill = base.blended(withFraction: 0.08, of: .white) ?? base
            } else {
                fill = base
            }
            textColor = .white
        case .secondary:
            // Subtle pill that reads as a button on the dark card.
            if isPressed {
                fill = NSColor.white.withAlphaComponent(0.22)
            } else if isHovered {
                fill = NSColor.white.withAlphaComponent(0.14)
            } else {
                fill = NSColor.white.withAlphaComponent(0.08)
            }
            textColor = NSColor.white.withAlphaComponent(0.9)
        }

        ctx.setFillColor(fill.cgColor)
        ctx.addPath(path); ctx.fillPath()
        if style == .secondary {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(path); ctx.strokePath()
        }

        // Title — Forge button typography.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12,
                                     weight: style == .accent ? .semibold : .medium),
            .foregroundColor: textColor
        ]
        let label = NSAttributedString(string: title, attributes: attrs)
        let size = label.size()
        label.draw(at: NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        ))
    }
}

// MARK: - Convenience extensions

private extension ZoneRect {
    /// Read-only conversion to a CGRect for builder consumption. The
    /// `ZoneDefinition.rect` getter already returns a CGRect on the
    /// public side; this one preserves the same identity for internal
    /// callers without having to walk through ZoneDefinition.
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

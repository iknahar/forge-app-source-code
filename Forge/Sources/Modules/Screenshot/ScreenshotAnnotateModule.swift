import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    /// Broadcast right before the screenshot module captures the screen.
    /// Other overlay-style modules (e.g. Mouse Highlight) listen for this
    /// so they can dismiss their visuals — otherwise the red spotlight ring
    /// gets baked into the captured pixels. Also signals that the screenshot
    /// SESSION has begun: those modules should refuse to activate again
    /// until the matching `forgeAfterScreenshotDismiss` is broadcast.
    static let forgeBeforeScreenshotCapture = Notification.Name("forgeBeforeScreenshotCapture")

    /// Broadcast when the screenshot session ends (user copies, saves,
    /// uploads, or cancels). Modules that paused themselves at the start
    /// should resume normal behavior on receipt.
    static let forgeAfterScreenshotDismiss  = Notification.Name("forgeAfterScreenshotDismiss")
}

// MARK: - Module

/// Screenshot + Annotate — capture a region of the screen and decorate it with
/// rectangles, ellipses, freehand strokes, and text. Then copy to clipboard,
/// save locally, or upload to a public host and get a share URL.
final class ScreenshotAnnotateModule: ForgeModule, ObservableObject {

    let id = "screenshotAnnotate"
    let name = "Screenshot"
    let description = "Capture a region, annotate, copy/save/share"
    let iconName = "camera.viewfinder"
    let category: ModuleCategory = .screen
    var isEnabled: Bool = true

    private var regionWindow: NSWindow?
    private var toolbarWindow: NSPanel?
    private var fullScreenImage: CGImage?
    private var overlayView: LightshotOverlayView?
    private var sessionRef: AnnotationSession?

    func activate() {}
    func deactivate() {
        dismissLightshot()
    }

    func commands() -> [ForgeCommand] {
        [ForgeCommand(
            id: "screenshot.capture",
            title: "Screenshot — capture & annotate",
            subtitle: "Drag to select a region",
            iconName: "camera.viewfinder",
            moduleId: id,
            action: { [weak self] in self?.startCapture() },
            keywords: ["screenshot", "snap", "capture", "annotate", "draw"]
        )]
    }

    // MARK: - Capture (Lightshot-style: selection stays in place)

    func startCapture() {
        // macOS gates `CGWindowListCreateImage` and ScreenCaptureKit behind
        // the Screen Recording privacy permission. Without it the captured
        // image contains *only* the desktop wallpaper — every app window
        // is omitted, which looks like "nothing to drag against" to the
        // user. Preflight first; if we don't have access, fire the system
        // request and show a guidance alert instead of pushing a useless
        // dark overlay.
        guard CGPreflightScreenCaptureAccess() else {
            // Triggers the system permission dialog the first time it's
            // called; subsequent calls are a no-op.
            _ = CGRequestScreenCaptureAccess()
            presentScreenRecordingAlert()
            return
        }

        // Ask other transient overlays (Mouse Highlight, Find My Mouse,
        // etc.) to dismiss BEFORE we read pixels — otherwise their visuals
        // get baked into the captured image.
        NotificationCenter.default.post(name: .forgeBeforeScreenshotCapture, object: nil)

        // Let the runloop drain so AppKit actually removes those overlay
        // windows from the display before we sample the screen. Without
        // this short hop the spotlight ring would still appear in the
        // captured pixels because the orderOut hasn't been flushed yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.performCapture()
        }
    }

    /// Shown when Screen Recording permission is missing. Gives the user a
    /// one-click jump to the right Privacy pane in System Settings.
    private func presentScreenRecordingAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Forge needs Screen Recording access"
        alert.informativeText = """
        macOS requires Screen Recording permission to capture the contents \
        of other app windows. Without it Forge can only see the desktop \
        wallpaper, which is why your screenshot looks blank.

        Open System Settings → Privacy & Security → Screen Recording, \
        enable Forge, then try the shortcut again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func performCapture() {
        guard let screen = NSScreen.main else { return }

        // Use a view-local rect with origin (0, 0) for our local drawing
        // coordinate system; the WINDOW gets positioned in screen space.
        let screenFrame = screen.frame
        let viewFrame = NSRect(origin: .zero, size: screenFrame.size)

        guard let image = CGWindowListCreateImage(
            screenFrame, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]
        ) else {
            NotificationCenter.default.post(name: .forgeAfterScreenshotDismiss, object: nil)
            presentScreenRecordingAlert()
            return
        }
        // Sanity-check: if the captured image is degenerate (tiny / 0×0),
        // we lost access mid-flight. Bail with the guidance alert rather
        // than showing a black overlay.
        if image.width < 8 || image.height < 8 {
            NotificationCenter.default.post(name: .forgeAfterScreenshotDismiss, object: nil)
            presentScreenRecordingAlert()
            return
        }
        fullScreenImage = image

        let view = LightshotOverlayView(frame: viewFrame)
        view.capturedImage = image
        view.onSelectionComplete = { [weak self] rect in self?.selectionLocked(rect) }
        view.onCancel            = { [weak self] in self?.dismissLightshot() }
        view.onSelectionChanged  = { [weak self] rect in self?.repositionToolbar(near: rect) }

        let window = OverlayWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // `.statusBar` is high enough to sit above normal app windows but
        // low enough that the toolbar (placed one rung higher) can float on
        // top of the overlay. `.screenSaver` was too high — the toolbar was
        // being z-ordered under the overlay and never appeared.
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        // Force the window to the physical screen.frame *after* setting the
        // content view. Even though OverlayWindow disables the
        // constrain-to-screen trim, some macOS versions still nudge the
        // frame during makeKeyAndOrderFront(); an explicit setFrame post-
        // ordering is the safest belt-and-suspenders.
        window.setFrame(screenFrame, display: false)
        window.makeKeyAndOrderFront(nil)
        window.setFrame(screenFrame, display: true)
        window.makeFirstResponder(view)
        NSCursor.crosshair.push()
        regionWindow = window
        overlayView = view
    }

    /// User finished dragging — overlay stays alive, transitions to annotation
    /// mode (selection visible in original spot), toolbar floats below.
    private func selectionLocked(_ rect: CGRect) {
        NSCursor.pop()

        let session = AnnotationSession(baseImage: NSImage())  // pixels live in overlayView
        session.selectionSize = rect.size
        sessionRef = session
        overlayView?.session = session

        showToolbar(near: rect)
    }

    private func showToolbar(near selectionRect: CGRect) {
        guard let session = sessionRef, let screen = NSScreen.main else { return }

        let toolbar = LightshotToolbar(
            session: session,
            onCopy:    { [weak self] in self?.copyToClipboard() },
            onSave:    { [weak self] in self?.saveToFile() },
            onUpload:  { [weak self] in self?.uploadAndShare() },
            onClose:   { [weak self] in self?.dismissLightshot() }
        )
        let hosting = NSHostingController(rootView: toolbar)

        // Toolbar is a non-activating panel positioned just below the selection.
        //
        // Width is fixed for the entire session — picked to fit the action bar
        // (dimensions + tools + thickness + colors + undo + copy/save/upload + ×).
        // The uploading and success panels reuse this same width via Spacers so
        // they never visually "grow wider than the action bar".
        let toolbarHeight: CGFloat = 60
        let toolbarWidth: CGFloat = max(720, selectionRect.width + 40)
        var x = selectionRect.midX - toolbarWidth / 2
        var y = selectionRect.minY - toolbarHeight - 10
        // If there's no room below, flip to above the selection
        if y < 20 { y = selectionRect.maxY + 10 }
        // Clamp to screen edges
        x = max(20, min(screen.frame.width - toolbarWidth - 20, x))

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: toolbarWidth, height: toolbarHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // One rung above the overlay so the toolbar floats on top of the
        // dimmed veil. `.popUpMenu` (101) is well above `.statusBar` (25).
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        toolbarWindow = panel
    }

    /// Reposition toolbar when selection moves (future: drag-resize selection).
    fileprivate func repositionToolbar(near rect: CGRect) {
        guard let panel = toolbarWindow, let screen = NSScreen.main else { return }
        let w = panel.frame.width
        var x = rect.midX - w / 2
        var y = rect.minY - panel.frame.height - 10
        if y < 20 { y = rect.maxY + 10 }
        x = max(20, min(screen.frame.width - w - 20, x))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func dismissLightshot() {
        NSCursor.pop()
        regionWindow?.orderOut(nil);   regionWindow = nil
        toolbarWindow?.orderOut(nil);  toolbarWindow = nil
        overlayView = nil
        sessionRef = nil
        fullScreenImage = nil
        // Let paused overlay modules (Mouse Highlight) resume.
        NotificationCenter.default.post(name: .forgeAfterScreenshotDismiss, object: nil)
    }

    // MARK: - Export actions (operate on the live overlay's pixels)

    /// Crop the captured screen image to the user's selection, bake any
    /// annotations on top, and return PNG data.
    ///
    /// We deliberately avoid `NSImage.lockFocus()` here — on retina/HiDPI
    /// macOS it has produced empty or solid-color buffers in practice (the
    /// "blue bar" the user reported). A direct `CGContext` at pixel
    /// resolution is fully reliable.
    private func renderAnnotatedSelectionPNG() -> Data? {
        guard
            let view = overlayView,
            let session = sessionRef,
            let cgFull = fullScreenImage,
            let screen = NSScreen.main
        else { return nil }

        let rect = view.selection
        guard rect.width >= 2, rect.height >= 2 else { return nil }

        let scale = screen.backingScaleFactor
        let pixelW = max(1, Int((rect.width  * scale).rounded()))
        let pixelH = max(1, Int((rect.height * scale).rounded()))

        // 1) Crop the captured pixels (top-left origin CGImage, pixel coords).
        let cgRect = CGRect(
            x: rect.minX * scale,
            y: (screen.frame.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        guard let cropped = cgFull.cropping(to: cgRect) else { return nil }

        // 2) Fresh ARGB bitmap context at pixel resolution.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pixelW, height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // 3) Draw the cropped pixels to fill the canvas. The bitmap context
        // has top-left origin; CGContext.draw matches the destination rect
        // size, so the cropped image lands upright.
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        // 4) Bake annotations.
        //
        //    Annotations are stored in SCREEN-point coords with a bottom-left
        //    origin (matching the overlay view). The bitmap context is in
        //    pixels with a top-left origin. Convert:
        //      a) Flip Y so we can use bottom-left point arithmetic.
        //      b) Scale points → pixels.
        //      c) Translate so the selection's bottom-left maps to (0, 0).
        //
        //    We bridge an NSGraphicsContext on top of the CGContext so the
        //    existing AppKit-based AnnotationSession.draw routines work.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(pixelH))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)

        let appkitCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = appkitCtx
        for item in session.items {
            AnnotationSession.draw(item: item, in: NSRect(origin: .zero, size: screen.frame.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        // 5) Encode to PNG.
        guard let outImg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: outImg)
        return rep.representation(using: .png, properties: [:])
    }

    private func copyToClipboard() {
        guard let data = renderAnnotatedSelectionPNG(),
              let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        dismissLightshot()
    }

    private func saveToFile() {
        guard let data = renderAnnotatedSelectionPNG() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Forge-Screenshot.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
        dismissLightshot()
    }

    /// Kicks off the upload; the toolbar shows progress + result CTAs
    /// based on `session.uploadStatus`. We deliberately do NOT auto-open
    /// the URL or auto-dismiss — the user chooses Open or Copy URL.
    ///
    /// The panel keeps its fixed width across all three states (idle,
    /// uploading, success) so the URL row never visually balloons beyond
    /// the action bar.
    private func uploadAndShare() {
        guard let session = sessionRef,
              let data = renderAnnotatedSelectionPNG() else { return }

        session.uploadStatus = .uploading
        ScreenshotUploader.upload(pngData: data) { [weak self] result in
            DispatchQueue.main.async {
                guard let session = self?.sessionRef else { return }
                switch result {
                case .success(let url):
                    session.uploadStatus = .success(url: url)
                case .failure(let err):
                    session.uploadStatus = .failure(message: err.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Lightshot Overlay (selection + in-place annotation)

/// Full-screen overlay that handles BOTH phases of the screenshot flow:
/// 1. `selecting` — user drags to mark a region. Whole screen is dimmed
///    except the dragging rect, which shows the captured screen pixels.
/// 2. `annotating` — selection is locked. Captured pixels stay visible in
///    that exact spot regardless of what's now behind the overlay. User
///    draws shapes/strokes/text onto the selection.
///
/// A separate floating toolbar (managed by the module) hosts the action UI.
final class LightshotOverlayView: NSView {

    enum Phase { case selecting, annotating }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private enum HitRegion {
        case outside
        case interior
        case handle(Corner)
    }

    private enum DragMode {
        case none
        case selecting
        case moving(offset: NSPoint)   // cursor offset from selection.origin
        case resizing(corner: Corner)
        case annotating
    }

    // Inputs
    var capturedImage: CGImage?
    var onSelectionComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    /// Called whenever the selection's bounds change in annotating phase so
    /// the floating toolbar can be repositioned (move/resize).
    var onSelectionChanged: ((CGRect) -> Void)?

    // Shared state mirrored from the toolbar (set by module).
    // When the session is assigned we subscribe to its @Published `items`
    // and `tool` so SwiftUI-driven changes (toolbar Undo, tool switch)
    // immediately invalidate the overlay's draw — without this, undo
    // would update the model but never repaint the canvas.
    weak var session: AnnotationSession? {
        didSet {
            sessionSubscriptions.removeAll()
            guard let s = session else { return }
            s.$items
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.needsDisplay = true }
                .store(in: &sessionSubscriptions)
            s.$tool
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.applyCursorAtMouse() }
                .store(in: &sessionSubscriptions)
        }
    }
    private var sessionSubscriptions: Set<AnyCancellable> = []

    // Internal
    private(set) var phase: Phase = .selecting
    private(set) var selection: NSRect = .zero
    private var dragMode: DragMode = .none
    private var dragStart: NSPoint = .zero
    private var dragStartSelection: NSRect = .zero
    private var currentDrawItem: AnnotationItem?
    private var trackingArea: NSTrackingArea?

    // Handle visuals
    private let handleSize: CGFloat = 10
    private let handleHitSlop: CGFloat = 6     // generous hit-test margin around handles
    private let minSelectionSide: CGFloat = 12

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }   // bottom-left origin; matches screen coords

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }   // Esc
    }

    // MARK: Tracking (cursor feedback while mouse moves over handles / interior)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect, .cursorUpdate],
            owner: self, userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Re-evaluate the cursor at the current mouse position (used when the
    /// active tool changes via the toolbar so the cursor flips between
    /// crosshair / openHand without waiting for the next mouseMoved).
    private func applyCursorAtMouse() {
        guard let window = self.window else { return }
        let p = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        applyCursor(at: p)
    }

    private func applyCursor(at p: NSPoint) {
        let cursor: NSCursor
        switch phase {
        case .selecting:
            cursor = .crosshair
        case .annotating:
            switch regionAt(p) {
            case .handle:
                // macOS doesn't expose diagonal resize cursors publicly;
                // crosshair reads clearly as "you can resize here".
                cursor = .crosshair
            case .interior:
                cursor = (session?.tool == nil) ? .openHand : .crosshair
            case .outside:
                cursor = .arrow
            }
        }
        cursor.set()
    }

    // MARK: Hit testing

    private func handleRect(for corner: Corner) -> NSRect {
        let half = handleSize / 2
        switch corner {
        case .topLeft:
            return NSRect(x: selection.minX - half, y: selection.maxY - half,
                          width: handleSize, height: handleSize)
        case .topRight:
            return NSRect(x: selection.maxX - half, y: selection.maxY - half,
                          width: handleSize, height: handleSize)
        case .bottomLeft:
            return NSRect(x: selection.minX - half, y: selection.minY - half,
                          width: handleSize, height: handleSize)
        case .bottomRight:
            return NSRect(x: selection.maxX - half, y: selection.minY - half,
                          width: handleSize, height: handleSize)
        }
    }

    private func regionAt(_ p: NSPoint) -> HitRegion {
        guard phase == .annotating, selection.width > 0 else { return .outside }
        for c in Corner.allCases {
            if handleRect(for: c).insetBy(dx: -handleHitSlop, dy: -handleHitSlop).contains(p) {
                return .handle(c)
            }
        }
        if selection.contains(p) { return .interior }
        return .outside
    }

    // MARK: Mouse — branches on phase + hit region

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if phase == .selecting {
            dragStart = p
            selection = NSRect(origin: p, size: .zero)
            dragMode = .selecting
            updateSelectionSize()
            needsDisplay = true
            return
        }

        // phase == .annotating
        switch regionAt(p) {
        case .handle(let corner):
            dragStart = p
            dragStartSelection = selection
            dragMode = .resizing(corner: corner)

        case .interior:
            if let s = session, let tool = s.tool {
                var item = AnnotationItem(tool: tool, color: s.color, width: s.width)
                switch tool {
                case .rectangle, .ellipse:
                    item.rect = NSRect(origin: p, size: .zero)
                case .brush:
                    item.stroke = [p]
                case .text:
                    item.rect.origin = p
                    item.textSize = s.textSize
                    item.text = promptForText() ?? ""
                    if !item.text.isEmpty { s.items.append(item) }
                    dragMode = .none
                    needsDisplay = true
                    return
                }
                currentDrawItem = item
                dragMode = .annotating
            } else {
                // No tool selected → drag = move
                let offset = NSPoint(x: p.x - selection.minX, y: p.y - selection.minY)
                dragMode = .moving(offset: offset)
                dragStartSelection = selection
            }

        case .outside:
            // Click outside selection in annotating phase — ignore.
            // (We deliberately don't restart selection here; users on
            // Lightshot expect a stable selection until they explicitly
            // cancel via Esc / × in the toolbar.)
            return
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .selecting:
            selection = NSRect(
                x: min(dragStart.x, p.x), y: min(dragStart.y, p.y),
                width: abs(p.x - dragStart.x), height: abs(p.y - dragStart.y)
            )
            updateSelectionSize()

        case .moving(let offset):
            var rect = dragStartSelection
            rect.origin = NSPoint(x: p.x - offset.x, y: p.y - offset.y)
            // Clamp inside the screen.
            rect.origin.x = max(0, min(bounds.width - rect.width, rect.origin.x))
            rect.origin.y = max(0, min(bounds.height - rect.height, rect.origin.y))
            selection = rect
            updateSelectionSize()
            onSelectionChanged?(selection)

        case .resizing(let corner):
            selection = resized(rect: dragStartSelection, corner: corner, to: p)
            updateSelectionSize()
            onSelectionChanged?(selection)

        case .annotating:
            guard var item = currentDrawItem else { return }
            let clamped = NSPoint(
                x: min(max(p.x, selection.minX), selection.maxX),
                y: min(max(p.y, selection.minY), selection.maxY)
            )
            switch item.tool {
            case .rectangle, .ellipse:
                let origin = item.rect.origin
                item.rect.size = CGSize(width: clamped.x - origin.x,
                                        height: clamped.y - origin.y)
            case .brush:
                item.stroke.append(clamped)
            case .text:
                break
            }
            currentDrawItem = item

        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .selecting:
            guard selection.width > minSelectionSide,
                  selection.height > minSelectionSide else {
                selection = .zero
                updateSelectionSize()
                dragMode = .none
                needsDisplay = true
                return
            }
            phase = .annotating
            dragMode = .none
            onSelectionComplete?(selection)

        case .moving, .resizing:
            dragMode = .none

        case .annotating:
            if var item = currentDrawItem, let s = session {
                if item.tool == .rectangle || item.tool == .ellipse {
                    item.rect = NSRect(
                        x: min(item.rect.minX, item.rect.maxX),
                        y: min(item.rect.minY, item.rect.maxY),
                        width: abs(item.rect.width),
                        height: abs(item.rect.height)
                    )
                    if item.rect.width >= 2, item.rect.height >= 2 { s.items.append(item) }
                } else if item.tool == .brush, item.stroke.count > 1 {
                    s.items.append(item)
                }
            }
            currentDrawItem = nil
            dragMode = .none

        case .none:
            break
        }
        needsDisplay = true
    }

    /// Pure function — given the starting rect, the corner being dragged,
    /// and the current cursor position, return the new (always-positive)
    /// selection rect. Enforces a minimum side length.
    private func resized(rect r: NSRect, corner: Corner, to p: NSPoint) -> NSRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch corner {
        case .topLeft:
            minX = min(p.x, maxX - minSelectionSide)
            maxY = max(p.y, minY + minSelectionSide)
        case .topRight:
            maxX = max(p.x, minX + minSelectionSide)
            maxY = max(p.y, minY + minSelectionSide)
        case .bottomLeft:
            minX = min(p.x, maxX - minSelectionSide)
            minY = min(p.y, maxY - minSelectionSide)
        case .bottomRight:
            maxX = max(p.x, minX + minSelectionSide)
            minY = min(p.y, maxY - minSelectionSide)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func updateSelectionSize() {
        session?.selectionSize = selection.size
    }

    private func promptForText() -> String? {
        let alert = NSAlert()
        alert.messageText = "Add text"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        // 1. Captured screen pixels everywhere — this is what creates the
        // "frozen" effect: the selection sees the same pixels even after
        // other windows underneath have moved/changed.
        //
        // IMPORTANT: NSGraphicsContext.draw(_:in:) already orients the image
        // upright in the destination rect regardless of the view's flipped
        // state. The previous translate + scale was an *extra* flip and made
        // the screenshot render upside-down.
        if let img = capturedImage {
            ctx.draw(img, in: bounds)
        }

        // 2. Light dim veil over everything — kept subtle so the real
        // desktop is still clearly readable through it (matches Lightshot's
        // ~25-30% dim, NOT a heavy black overlay).
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.fill(bounds)

        // 3. Punch a hole in the veil for the selection (image shows through)
        if selection.width > 0, selection.height > 0 {
            ctx.setBlendMode(.clear)
            ctx.fill(selection)
            ctx.setBlendMode(.normal)
        }

        // 4. Selection border + dimensions chip + (annotating) corner handles.
        if selection.width > 0, selection.height > 0 {
            let accent = NSColor(srgbRed: 0.06, green: 0.45, blue: 0.95, alpha: 1) // Lightshot blue
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(selection)

            // Dimensions chip — sticky during the initial drag so the user
            // can see what they're framing. Hidden in annotating phase since
            // the floating toolbar shows the live dimensions.
            if phase == .selecting {
                let dims = "\(Int(selection.width)) × \(Int(selection.height))"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                let str = NSAttributedString(string: dims, attributes: attrs)
                let strSize = str.size()
                let chipRect = NSRect(
                    x: selection.maxX - strSize.width - 14,
                    y: selection.maxY + 6,
                    width: strSize.width + 14, height: strSize.height + 6
                )
                NSColor.black.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: chipRect, xRadius: 4, yRadius: 4).fill()
                str.draw(at: NSPoint(x: chipRect.minX + 7, y: chipRect.minY + 3))
            }

            // Corner handles — only visible in annotating phase. Filled
            // white with a blue border, like Lightshot.
            if phase == .annotating {
                for corner in Corner.allCases {
                    let r = handleRect(for: corner)
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fillEllipse(in: r)
                    ctx.setStrokeColor(accent.cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.strokeEllipse(in: r)
                }
            }
        }

        // 5. Draw annotations — clipped to the selection so strokes can't
        // bleed outside the frozen area.
        if phase == .annotating, let s = session, selection.width > 0 {
            ctx.saveGState()
            ctx.clip(to: selection)
            for item in s.items {
                AnnotationSession.draw(item: item, in: bounds)
            }
            if let current = currentDrawItem {
                AnnotationSession.draw(item: current, in: bounds)
            }
            ctx.restoreGState()
        }
    }
}

// MARK: - Floating Lightshot toolbar

private struct LightshotToolbar: View {
    @ObservedObject var session: AnnotationSession
    let onCopy: () -> Void
    let onSave: () -> Void
    let onUpload: () -> Void
    let onClose: () -> Void

    // Inline mini-palette
    private static let colors: [NSColor] = [
        NSColor(srgbRed: 0.93, green: 0.12, blue: 0.12, alpha: 1),  // red
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.10, alpha: 1),  // orange
        NSColor(srgbRed: 1.00, green: 0.85, blue: 0.12, alpha: 1),  // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),  // green
        NSColor(srgbRed: 0.06, green: 0.45, blue: 0.95, alpha: 1),  // blue
        NSColor(srgbRed: 0.55, green: 0.30, blue: 0.85, alpha: 1),  // purple
        NSColor.white,
        NSColor(white: 0.10, alpha: 1),                              // near-black
    ]
    private static let thicknesses: [CGFloat] = [2, 4, 7]

    var body: some View {
        Group {
            switch session.uploadStatus {
            case .idle:                   mainToolbar
            case .uploading:              uploadingPanel
            case .success(let url):       uploadedPanel(url: url)
            case .failure(let message):   failurePanel(message: message)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.10).opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: session.uploadStatus)
    }

    private var mainToolbar: some View {
        HStack(spacing: 10) {
            // Live dimensions readout — matches the Lightshot UX where the
            // user sees the locked region's W × H right inside the toolbar.
            Text(dimensionText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .frame(minWidth: 76, alignment: .leading)
                .padding(.leading, 2)

            divider

            // Tools — clicking the active tool clears it (move/resize mode).
            ForEach(AnnotationTool.allCases) { t in
                ToolbarIconButton(symbol: t.icon, isActive: session.tool == t) {
                    session.tool = (session.tool == t) ? nil : t
                }
            }
            divider

            // Thickness — 3 dot sizes (hidden in text mode or when no tool).
            if session.tool == nil {
                // No tool selected → user is in move/resize mode. No
                // thickness/text-size controls are relevant.
                EmptyView()
            } else if session.tool != .text {
                HStack(spacing: 4) {
                    ForEach(Self.thicknesses, id: \.self) { w in
                        StrokeWidthButton(width: w, isActive: session.width == w) {
                            session.width = w
                        }
                    }
                }
                divider
            } else {
                Menu {
                    ForEach([10, 12, 14, 18, 24, 32, 48], id: \.self) { s in
                        Button("\(s)") { session.textSize = CGFloat(s) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(Int(session.textSize))")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                divider
            }

            // Colors
            HStack(spacing: 4) {
                ForEach(Self.colors.indices, id: \.self) { i in
                    let c = Self.colors[i]
                    Button { session.color = c } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: c))
                            .frame(width: 16, height: 16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(session.color == c ? Color.white : Color.black.opacity(0.25),
                                            lineWidth: session.color == c ? 1.5 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            divider

            // Undo
            ToolbarIconButton(symbol: "arrow.uturn.backward",
                              isActive: false,
                              enabled: !session.items.isEmpty) {
                session.undo()
            }

            divider

            // Copy / Save / Upload
            ToolbarIconButton(symbol: "doc.on.doc.fill", isActive: false, action: onCopy)
                .help("Copy to clipboard")
            ToolbarIconButton(symbol: "square.and.arrow.down.fill", isActive: false, action: onSave)
                .help("Save to file")
            ToolbarIconButton(symbol: "icloud.and.arrow.up.fill", isActive: false, action: onUpload)
                .help("Upload & share URL")

            divider

            // Close
            ToolbarIconButton(symbol: "xmark", isActive: false, action: onClose)
                .help("Cancel")
        }
    }

    // MARK: - Upload-state panels

    /// Compact "Uploading" pill — matches the Lightshot reference where the
    /// status text shows as a small label with a spinner. Spacer fills the
    /// fixed panel width so we don't visually resize the toolbar.
    private var uploadingPanel: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.white)
            Text("Uploading…")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
            Spacer(minLength: 16)
            ToolbarIconButton(symbol: "xmark", isActive: false, action: onClose)
                .help("Cancel")
        }
    }

    /// Success: compact Lightshot-style pill — [Open] [Copy] + URL field + ×.
    /// Whichever button the user picks does the action and dismisses the
    /// screenshot session.
    private func uploadedPanel(url: String) -> some View {
        HStack(spacing: 8) {
            // Open button (primary, blue)
            Button {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                onClose()
            } label: {
                Text("Open")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.06, green: 0.45, blue: 0.95))
                    )
            }
            .buttonStyle(.plain)
            .help("Open in browser")

            // Copy button (secondary, light gray)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                onClose()
            } label: {
                Text("Copy")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.18))
                    )
            }
            .buttonStyle(.plain)
            .help("Copy URL to clipboard")

            // URL field — read-only, selectable, monospace. `maxWidth: .infinity`
            // lets it consume whatever horizontal space is left inside the
            // fixed-width panel, so the panel itself never has to grow.
            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .textSelection(.enabled)
                .help(url)

            ToolbarIconButton(symbol: "xmark", isActive: false, action: onClose)
                .help("Done")
        }
    }

    /// Upload failed — show the error and offer a retry.
    private func failurePanel(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(red: 1.0, green: 0.55, blue: 0.10))

            VStack(alignment: .leading, spacing: 1) {
                Text("Upload failed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .leading)
            }

            Spacer(minLength: 12)

            Button {
                session.uploadStatus = .idle
                onUpload()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0.06, green: 0.45, blue: 0.95))
                )
            }
            .buttonStyle(.plain)

            ToolbarIconButton(symbol: "xmark", isActive: false, action: onClose)
                .help("Dismiss")
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 22)
    }

    /// "696 × 382" — live dimensions of the selection rect.
    private var dimensionText: String {
        let w = Int(session.selectionSize.width.rounded())
        let h = Int(session.selectionSize.height.rounded())
        return "\(w) × \(h)"
    }
}

/// Stroke-width pill — the dot grows from 2pt → 4pt → 7pt across the row,
/// and the *selected* one is filled in the Lightshot accent blue with a
/// soft ring so it's unmistakable.
private struct StrokeWidthButton: View {
    let width: CGFloat
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    private static let accent = Color(red: 0.06, green: 0.45, blue: 0.95)

    var body: some View {
        Button(action: action) {
            ZStack {
                // Active state: blue circular tile with a subtle ring
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive
                          ? Self.accent
                          : (hovering ? Color.white.opacity(0.10) : Color.clear))
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(
                                isActive
                                    ? Color.white.opacity(0.25)
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )

                // The dot itself — sized by `width`, always white for contrast
                Circle()
                    .fill(Color.white)
                    .frame(width: width + 4, height: width + 4)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Stroke width \(Int(width))pt")
    }
}

private struct ToolbarIconButton: View {
    let symbol: String
    let isActive: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isActive ? .white
                                 : (enabled ? .white.opacity(0.85) : .white.opacity(0.30)))
                .frame(width: 32, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.white.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Annotation session model

enum AnnotationTool: String, CaseIterable, Identifiable {
    case rectangle, ellipse, brush, text
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .brush:     return "paintbrush.pointed.fill"
        case .text:      return "textformat"
        }
    }
}

/// One annotation primitive on the canvas. Stored in a list so we can undo.
struct AnnotationItem: Identifiable, Equatable {
    let id = UUID()
    var tool: AnnotationTool
    var color: NSColor
    var width: CGFloat
    var rect: NSRect = .zero
    var stroke: [NSPoint] = []
    var text: String = ""
    var textSize: CGFloat = 18

    static func == (lhs: AnnotationItem, rhs: AnnotationItem) -> Bool { lhs.id == rhs.id }
}

/// State of the catbox.moe upload. The toolbar binds to this and morphs
/// from the normal tool row → "Uploading…" → "Uploaded! [Open] [Copy URL]".
enum UploadStatus: Equatable {
    case idle
    case uploading
    case success(url: String)
    case failure(message: String)
}

final class AnnotationSession: ObservableObject {
    let baseImage: NSImage
    @Published var items: [AnnotationItem] = []
    /// Currently active annotation tool. `nil` means "no tool" → the user
    /// can move the selection or resize it; clicks inside the selection do
    /// NOT draw. Clicking a tool toggles it; clicking the same tool again
    /// clears it back to nil.
    @Published var tool: AnnotationTool? = nil
    @Published var color: NSColor = .systemRed
    @Published var width: CGFloat = 3
    @Published var textSize: CGFloat = 18
    /// Live size of the selection rectangle (updated by the overlay during
    /// initial drag, move, and resize). Used by the toolbar to display
    /// "696 × 382" style dimensions.
    @Published var selectionSize: CGSize = .zero
    /// Drives the upload UI in the toolbar.
    @Published var uploadStatus: UploadStatus = .idle

    init(baseImage: NSImage) { self.baseImage = baseImage }

    func undo() {
        guard !items.isEmpty else { return }
        items.removeLast()
    }

    /// Renders the current image + annotations into a fresh NSImage.
    func renderToImage() -> NSImage {
        let size = baseImage.size
        let out = NSImage(size: size)
        out.lockFocus()
        baseImage.draw(in: NSRect(origin: .zero, size: size))
        for item in items { Self.draw(item: item, in: NSRect(origin: .zero, size: size)) }
        out.unlockFocus()
        return out
    }

    static func draw(item: AnnotationItem, in canvasBounds: NSRect) {
        item.color.setStroke()
        item.color.setFill()
        switch item.tool {
        case .rectangle:
            let p = NSBezierPath(rect: item.rect)
            p.lineWidth = item.width
            p.stroke()
        case .ellipse:
            let p = NSBezierPath(ovalIn: item.rect)
            p.lineWidth = item.width
            p.stroke()
        case .brush:
            guard item.stroke.count > 1 else { return }
            let p = NSBezierPath()
            p.move(to: item.stroke[0])
            for pt in item.stroke.dropFirst() { p.line(to: pt) }
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.lineWidth = item.width
            p.stroke()
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: item.textSize, weight: .semibold),
                .foregroundColor: item.color
            ]
            let s = NSAttributedString(string: item.text, attributes: attrs)
            s.draw(at: item.rect.origin)
        }
    }
}

// MARK: - Editor SwiftUI shell

struct ScreenshotEditorView: View {
    @ObservedObject var session: AnnotationSession
    let onClose: () -> Void

    @State private var uploadState: UploadState = .idle
    @State private var lastUploadedURL: String?
    @State private var showURLPopover = false

    enum UploadState: Equatable { case idle, uploading, done(String), failed(String) }

    private static let palette: [NSColor] = [
        // Row 1 — saturated
        NSColor(white: 0.55, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.0,  blue: 0.0,  alpha: 1),    // maroon
        NSColor(srgbRed: 0.93, green: 0.12, blue: 0.12, alpha: 1),    // red
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.10, alpha: 1),    // orange
        NSColor(srgbRed: 1.00, green: 0.85, blue: 0.12, alpha: 1),    // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),    // green
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.78, alpha: 1),    // teal
        NSColor(srgbRed: 0.06, green: 0.45, blue: 0.95, alpha: 1),    // blue
        NSColor(srgbRed: 0.15, green: 0.20, blue: 0.65, alpha: 1),    // navy
        NSColor(srgbRed: 0.55, green: 0.30, blue: 0.85, alpha: 1),    // purple
        NSColor(srgbRed: 0.38, green: 0.12, blue: 0.55, alpha: 1),    // dark purple

        // Row 2 — soft pastels
        NSColor.white,
        NSColor(srgbRed: 0.62, green: 0.43, blue: 0.30, alpha: 1),    // brown
        NSColor(srgbRed: 0.96, green: 0.70, blue: 0.78, alpha: 1),    // pink
        NSColor(srgbRed: 1.00, green: 0.92, blue: 0.72, alpha: 1),    // cream
        NSColor(srgbRed: 0.90, green: 0.84, blue: 0.40, alpha: 1),    // mustard
        NSColor(srgbRed: 0.66, green: 0.86, blue: 0.55, alpha: 1),    // light green
        NSColor(srgbRed: 0.62, green: 0.83, blue: 0.94, alpha: 1),    // sky
        NSColor(srgbRed: 0.75, green: 0.75, blue: 0.92, alpha: 1),    // light blue
        NSColor(srgbRed: 0.80, green: 0.70, blue: 0.92, alpha: 1),    // lavender
    ]

    private static let textSizes: [CGFloat] = [10, 12, 14, 18, 24, 32, 48, 64]

    var body: some View {
        VStack(spacing: 10) {
            toolbarRow
            secondaryRow
            canvas
        }
        .padding(10)
        .background(Color(white: 0.10))
        .preferredColorScheme(.dark)
    }

    // Top toolbar
    private var toolbarRow: some View {
        HStack(spacing: 14) {
            Text(dimensionText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            // 4 tools
            ForEach(AnnotationTool.allCases) { t in
                ToolButton(symbol: t.icon, isActive: session.tool == t) {
                    session.tool = t
                }
            }

            Divider().frame(height: 22).background(Color.white.opacity(0.15))

            // Undo
            ToolButton(symbol: "arrow.uturn.backward",
                       isActive: false,
                       enabled: !session.items.isEmpty) {
                session.undo()
            }
            // Cancel / close
            ToolButton(symbol: "xmark", isActive: false) { onClose() }

            Divider().frame(height: 22).background(Color.white.opacity(0.15))

            // Copy to clipboard
            ToolButton(symbol: "doc.on.doc.fill", isActive: false) { copyToClipboard() }

            // Save (with menu for share/upload)
            Menu {
                Button("Save to file…")           { saveToFile() }
                Button("Upload & share URL…")     { uploadAndShare() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("SAVE")
                        .font(.system(size: 12, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundColor(Color(red: 0.06, green: 0.45, blue: 0.95))
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .popover(isPresented: $showURLPopover, arrowEdge: .top) {
                UploadResultPopover(state: uploadState, url: lastUploadedURL,
                                    onClose: { showURLPopover = false })
            }
        }
        .padding(.horizontal, 4)
    }

    // Below toolbar: thickness/text-size + colors
    private var secondaryRow: some View {
        HStack(spacing: 14) {
            if session.tool == .text {
                Menu {
                    ForEach(Self.textSizes, id: \.self) { s in
                        Button("\(Int(s))") { session.textSize = s }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("\(Int(session.textSize))")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                // Thickness dots — 3 sizes
                HStack(spacing: 8) {
                    ForEach([2.0, 4.0, 7.0], id: \.self) { (w: CGFloat) in
                        Button { session.width = w } label: {
                            ZStack {
                                Circle().fill(Color.white.opacity(0.05))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(
                                        session.width == w ? Color.white : Color.white.opacity(0.10),
                                        lineWidth: session.width == w ? 1.5 : 1))
                                Circle().fill(Color.white)
                                    .frame(width: w + 2, height: w + 2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().frame(height: 22).background(Color.white.opacity(0.15))

            // Color palette — 2 rows
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    ForEach(Self.palette.prefix(11).indices, id: \.self) { i in
                        colorSwatch(Self.palette[i])
                    }
                }
                HStack(spacing: 5) {
                    ForEach(Self.palette.suffix(from: 11).indices, id: \.self) { i in
                        colorSwatch(Self.palette[i])
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func colorSwatch(_ c: NSColor) -> some View {
        let isActive = c == session.color
        return Button { session.color = c } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: c))
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isActive ? Color.white : Color.black.opacity(0.20),
                                lineWidth: isActive ? 1.5 : 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // Canvas
    private var canvas: some View {
        AnnotationCanvasView(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.06))
            .cornerRadius(6)
    }

    private var dimensionText: String {
        let s = session.baseImage.size
        return "\(Int(s.width)) X \(Int(s.height))"
    }

    // MARK: - Actions

    private func copyToClipboard() {
        let img = session.renderToImage()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    private func saveToFile() {
        let img = session.renderToImage()
        guard
            let tiff = img.tiffRepresentation,
            let rep  = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Forge-Screenshot.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func uploadAndShare() {
        let img = session.renderToImage()
        guard
            let tiff = img.tiffRepresentation,
            let rep  = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: .png, properties: [:])
        else { return }

        uploadState = .uploading
        showURLPopover = true

        ScreenshotUploader.upload(pngData: data) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    uploadState = .done(url)
                    lastUploadedURL = url
                case .failure(let err):
                    uploadState = .failed(err.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Tool button

private struct ToolButton: View {
    let symbol: String
    let isActive: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isActive ? .white
                                 : (enabled ? .white.opacity(0.80) : .white.opacity(0.30)))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.white.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Upload result popover

private struct UploadResultPopover: View {
    let state: ScreenshotEditorView.UploadState
    let url: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .idle:
                EmptyView()
            case .uploading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Uploading…").font(.system(size: 12))
                }
            case .done(let link):
                Text("Shareable link")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Text(link)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Button {
                        if let u = URL(string: link) { NSWorkspace.shared.open(u) }
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                    Button("Close") { onClose() }.buttonStyle(.plain)
                }
            case .failed(let err):
                Label("Upload failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 12, weight: .semibold))
                Text(err).font(.system(size: 11)).foregroundColor(.secondary)
                Button("Close", action: onClose).buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

// MARK: - Uploader (Catbox.moe public host — no auth required)

enum ScreenshotUploader {
    enum UploadError: LocalizedError {
        case network
        case badResponse
        var errorDescription: String? {
            switch self {
            case .network:     return "Couldn't reach the upload server."
            case .badResponse: return "The server returned an unexpected response."
            }
        }
    }

    static func upload(pngData: Data, completion: @escaping (Result<String, Error>) -> Void) {
        let boundary = "Forge-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://catbox.moe/user/api.php")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"reqtype\"\r\n\r\nfileupload\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"screenshot.png\"\r\n")
        append("Content-Type: image/png\r\n\r\n")
        body.append(pngData)
        append("\r\n--\(boundary)--\r\n")

        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, _, err in
            if err != nil { return completion(.failure(UploadError.network)) }
            guard
                let data = data,
                let str = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                str.hasPrefix("https://")
            else { return completion(.failure(UploadError.badResponse)) }
            completion(.success(str))
        }.resume()
    }
}

// MARK: - Annotation canvas (NSView)

struct AnnotationCanvasView: NSViewRepresentable {
    @ObservedObject var session: AnnotationSession

    func makeNSView(context: Context) -> _CanvasNSView {
        let v = _CanvasNSView()
        v.session = session
        return v
    }

    func updateNSView(_ nsView: _CanvasNSView, context: Context) {
        nsView.session = session
        nsView.needsDisplay = true
    }
}

final class _CanvasNSView: NSView {
    var session: AnnotationSession? { didSet { needsDisplay = true } }
    private var currentItem: AnnotationItem?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let s = session, let tool = s.tool else { return }
        let p = convert(event.locationInWindow, from: nil)
        var item = AnnotationItem(tool: tool, color: s.color, width: s.width)
        switch tool {
        case .rectangle, .ellipse:
            item.rect = NSRect(x: p.x, y: p.y, width: 0, height: 0)
        case .brush:
            item.stroke = [p]
        case .text:
            item.rect.origin = p
            item.textSize = s.textSize
            item.text = promptForText() ?? ""
            if !item.text.isEmpty {
                s.items.append(item)
            }
            needsDisplay = true
            return
        }
        currentItem = item
    }

    override func mouseDragged(with event: NSEvent) {
        guard var item = currentItem else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch item.tool {
        case .rectangle, .ellipse:
            let origin = item.rect.origin
            item.rect = NSRect(
                x: min(origin.x, p.x), y: min(origin.y, p.y),
                width: abs(p.x - origin.x), height: abs(p.y - origin.y)
            )
            // origin tracks the initial anchor, so update only width/height & keep top-left
            item.rect.origin = origin
            item.rect.size = CGSize(width: p.x - origin.x, height: p.y - origin.y)
        case .brush:
            item.stroke.append(p)
        case .text:
            break
        }
        currentItem = item
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let item = currentItem, let s = session {
            // Normalize rect (handle dragging up/left)
            var finalItem = item
            if item.tool == .rectangle || item.tool == .ellipse {
                finalItem.rect = NSRect(
                    x: min(item.rect.minX, item.rect.maxX),
                    y: min(item.rect.minY, item.rect.maxY),
                    width: abs(item.rect.width),
                    height: abs(item.rect.height)
                )
                if finalItem.rect.width < 2 || finalItem.rect.height < 2 { currentItem = nil; return }
            }
            s.items.append(finalItem)
        }
        currentItem = nil
        needsDisplay = true
    }

    private func promptForText() -> String? {
        let alert = NSAlert()
        alert.messageText = "Add text"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        if result == .alertFirstButtonReturn { return field.stringValue }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = session else { return }

        // Image fit-to-bounds, preserve aspect
        let imgSize = s.baseImage.size
        let scale = min(bounds.width / imgSize.width, bounds.height / imgSize.height)
        let drawW = imgSize.width * scale
        let drawH = imgSize.height * scale
        let drawRect = NSRect(
            x: bounds.midX - drawW / 2,
            y: bounds.midY - drawH / 2,
            width: drawW, height: drawH
        )
        s.baseImage.draw(in: drawRect)

        // Note: annotations drawn in canvas coordinates; in this MVP we
        // overlay them directly without rescaling. (See follow-up TODO.)
        for item in s.items { AnnotationSession.draw(item: item, in: bounds) }
        if let c = currentItem { AnnotationSession.draw(item: c, in: bounds) }
    }
}

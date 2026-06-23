import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation

// MARK: - Capture scope

/// What the recorder should capture. Resolved by `CaptureScopePicker` before a
/// recording starts.
enum CaptureScope {
    case display(SCDisplay)                 // whole monitor
    case window(SCWindow)                   // one app window
    case region(SCDisplay, CGRect)          // a rect of a monitor, in that display's POINTS (top-left origin)
}

/// Device + audio choices made in the picker before recording starts.
struct CaptureOptions {
    var cameraDeviceID: String?   // nil = no camera
    var micDeviceID: String?      // nil = no microphone
    var systemAudio: Bool         // capture system / app audio
    var teleprompterScript: String?   // nil/empty = teleprompter off
}

// MARK: - Brand

/// Forge / Strativ brand accent (Strativ Orange `#FE5001`).
extension Color {
    static let forgeAccent = Color(red: 0xFE / 255, green: 0x50 / 255, blue: 0x01 / 255)
}
extension NSColor {
    static let forgeAccent = NSColor(srgbRed: 0xFE / 255, green: 0x50 / 255, blue: 0x01 / 255, alpha: 1)
}

/// Real app icon for a captured window (nicer than a generic glyph).
private func appIcon(for window: SCWindow) -> NSImage? {
    guard let pid = window.owningApplication?.processID else { return nil }
    return NSRunningApplication(processIdentifier: pid_t(pid))?.icon
}

// MARK: - Picker

/// Pre-record chooser: Full screen / Window / Region, with a monitor picker
/// when there are several displays and a window list for the window mode.
/// Loads `SCShareableContent` itself and calls back with a resolved
/// `CaptureScope` (or nil if cancelled). Region mode hands off to a
/// drag-select overlay before calling back.
enum CaptureScopePicker {

    private static var panel: NSPanel?

    static func present(completion: @escaping (CaptureScope?, CaptureOptions?) -> Void) {
        // One at a time.
        panel?.close()
        panel = nil

        Task { @MainActor in
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            let displays = content?.displays ?? []
            // Windows worth listing: on-screen, titled, not Forge, reasonable size.
            let myBundle = Bundle.main.bundleIdentifier
            let windows = (content?.windows ?? []).filter { w in
                guard let app = w.owningApplication else { return false }
                if app.bundleIdentifier == myBundle { return false }
                guard (w.title?.isEmpty == false) else { return false }
                return w.frame.width > 80 && w.frame.height > 80 && w.isOnScreen
            }
            .sorted {
                ($0.owningApplication?.applicationName ?? "") <
                ($1.owningApplication?.applicationName ?? "")
            }

            guard !displays.isEmpty else { completion(nil, nil); return }

            let model = ScopePickerModel(displays: displays, windows: windows)
            let root = ScopePickerView(model: model,
                onStart: { scope in
                    let opts = CaptureOptions(cameraDeviceID: model.selectedCameraID,
                                              micDeviceID: model.selectedMicID,
                                              systemAudio: model.systemAudioOn,
                                              teleprompterScript: model.teleprompterOn ? model.teleprompterScript : nil)
                    finish()
                    if case let .pendingRegion(display) = scope {
                        // Hand off to the drag-select overlay.
                        RegionSelector.select(on: display) { rect in
                            if let rect = rect { completion(.region(display, rect), opts) }
                            else { completion(nil, nil) }
                        }
                    } else if let resolved = scope.resolved {
                        completion(resolved, opts)
                    } else {
                        completion(nil, nil)
                    }
                },
                onCancel: { finish(); completion(nil, nil) })

            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.title = "Record"
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: root)
            p.center()
            p.level = .floating
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            panel = p
        }
    }

    private static func finish() {
        panel?.close()
        panel = nil
    }
}

/// Internal staged choice — region needs a second step (the drag overlay), so
/// it's carried as `.pendingRegion` until the rect is picked.
enum StagedScope {
    case display(SCDisplay)
    case window(SCWindow)
    case pendingRegion(SCDisplay)

    var resolved: CaptureScope? {
        switch self {
        case .display(let d): return .display(d)
        case .window(let w): return .window(w)
        case .pendingRegion: return nil   // resolved later via RegionSelector
        }
    }
}

// MARK: - Picker model + view

final class ScopePickerModel: ObservableObject {
    enum Mode: String, CaseIterable { case full = "Full Screen", window = "Window", region = "Region" }

    let displays: [SCDisplay]
    let windows: [SCWindow]

    @Published var mode: Mode = .full
    @Published var selectedDisplayID: CGDirectDisplayID
    @Published var selectedWindowID: CGWindowID?
    @Published var selectedCameraID: String?    // nil = camera off
    @Published var selectedMicID: String?       // nil = microphone off
    @Published var systemAudioOn: Bool = true
    @Published var teleprompterScript: String = ""   // empty = teleprompter off

    /// Capture devices for the Device & Tool dropdowns.
    let cameras: [AVCaptureDevice]
    let microphones: [AVCaptureDevice]

    var cameraOn: Bool { selectedCameraID != nil }
    var micOn: Bool { selectedMicID != nil }
    var teleprompterOn: Bool { !teleprompterScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var selectedCameraName: String { cameras.first { $0.uniqueID == selectedCameraID }?.localizedName ?? "None" }
    var selectedMicName: String { microphones.first { $0.uniqueID == selectedMicID }?.localizedName ?? "None" }

    init(displays: [SCDisplay], windows: [SCWindow]) {
        self.displays = displays
        self.windows = windows
        // Default to the main display.
        let main = CGMainDisplayID()
        self.selectedDisplayID = displays.first(where: { $0.displayID == main })?.displayID
            ?? displays.first!.displayID
        self.selectedWindowID = windows.first?.windowID
        self.cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
        self.microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        // Camera + mic are opt-in (off by default); system audio on.
        self.selectedCameraID = nil
        self.selectedMicID = nil
    }

    var selectedDisplay: SCDisplay {
        displays.first(where: { $0.displayID == selectedDisplayID }) ?? displays[0]
    }
    var selectedWindow: SCWindow? {
        windows.first(where: { $0.windowID == selectedWindowID })
    }

    func staged() -> StagedScope? {
        switch mode {
        case .full:   return .display(selectedDisplay)
        case .region: return .pendingRegion(selectedDisplay)
        case .window: return selectedWindow.map { .window($0) }
        }
    }
}

struct ScopePickerView: View {
    @ObservedObject var model: ScopePickerModel
    let onStart: (StagedScope) -> Void
    let onCancel: () -> Void
    @State private var showTeleprompterSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            HStack(alignment: .top, spacing: 0) {
                // LEFT — recording mode + per-mode chooser.
                VStack(alignment: .leading, spacing: 14) {
                    Text("Please select the recording mode")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    modeSelector

                    if model.mode != .window, model.displays.count > 1 { monitorPicker }
                    contentForMode

                    if model.mode != .window { Spacer(minLength: 0) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // RIGHT — device & tool column (camera / mic / system audio).
                deviceColumn
                    .frame(width: 232)
                    .padding(20)
            }

            footer
        }
        .frame(width: 760, height: 480)
        .tint(.forgeAccent)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showTeleprompterSheet) { teleprompterSheet }
    }

    private var teleprompterSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Teleprompter Script")
                .font(.system(size: 15, weight: .bold))
            Text("This scrolls on screen while you record. It is NOT included in the recording.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.teleprompterScript)
                .font(.system(size: 14))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                Button("Clear") { model.teleprompterScript = "" }
                Spacer()
                Button("Done") { showTeleprompterSheet = false }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 340)
        .tint(.forgeAccent)
    }

    private var monitorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MONITOR")
                .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                .foregroundStyle(.secondary)
            Picker("", selection: $model.selectedDisplayID) {
                ForEach(Array(model.displays.enumerated()), id: \.element.displayID) { idx, d in
                    Text("Display \(idx + 1)  ·  \(Int(d.width))×\(Int(d.height))").tag(d.displayID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.forgeAccent.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.forgeAccent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("New Recording").font(.system(size: 16, weight: .bold))
                Text("Choose what to capture").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
    }

    // MARK: Mode selector — large cards with a wallpaper-style thumbnail.

    private var modeSelector: some View {
        HStack(spacing: 12) {
            modeCard(.full,   title: "Full Screen")
            modeCard(.region, title: "Custom")
            modeCard(.window, title: "Window")
        }
    }

    private func modeCard(_ mode: ScopePickerModel.Mode, title: String) -> some View {
        let selected = model.mode == mode
        return Button {
            model.mode = mode
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    wallpaperThumb
                    modeGlyph(mode)
                }
                .frame(height: 116)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selected ? Color.forgeAccent : Color.white.opacity(0.12),
                                      lineWidth: selected ? 3 : 1)
                )
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(selected ? Color.forgeAccent : Color.primary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? Color.forgeAccent.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    /// macOS-wallpaper-like gradient used as each card's preview backdrop.
    private var wallpaperThumb: some View {
        LinearGradient(
            colors: [Color(red: 0.30, green: 0.36, blue: 0.86),
                     Color(red: 0.10, green: 0.13, blue: 0.42)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        .overlay(
            LinearGradient(colors: [.white.opacity(0.18), .clear],
                           startPoint: .topLeading, endPoint: .center))
    }

    /// What each mode captures, drawn over the thumbnail.
    @ViewBuilder private func modeGlyph(_ mode: ScopePickerModel.Mode) -> some View {
        switch mode {
        case .full:
            EmptyView()   // the whole wallpaper = full screen
        case .region:
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 60)
                ForEach(0..<4, id: \.self) { i in
                    Rectangle().fill(.white).frame(width: 7, height: 7)
                        .offset(x: i % 2 == 0 ? -48 : 48, y: i < 2 ? -30 : 30)
                }
            }
        case .window:
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.92))
                .frame(width: 118, height: 74)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(Color.gray.opacity(0.45)).frame(width: 7, height: 7)
                        }
                    }
                    .padding(9)
                }
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
    }

    // MARK: Device & Tool column (camera / microphone / system audio)

    private var deviceColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Device & Tool")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            // Camera
            deviceRow(icon: model.cameraOn ? "video.fill" : "video.slash.fill", on: model.cameraOn) {
                Picker("", selection: $model.selectedCameraID) {
                    Text("None").tag(String?.none)
                    ForEach(model.cameras, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(Optional(d.uniqueID))
                    }
                }
                .labelsHidden().pickerStyle(.menu)
                .disabled(model.cameras.isEmpty)
            }

            // Microphone
            deviceRow(icon: model.micOn ? "mic.fill" : "mic.slash.fill", on: model.micOn) {
                Picker("", selection: $model.selectedMicID) {
                    Text("None").tag(String?.none)
                    ForEach(model.microphones, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(Optional(d.uniqueID))
                    }
                }
                .labelsHidden().pickerStyle(.menu)
                .disabled(model.microphones.isEmpty)
            }

            // System audio
            deviceRow(icon: model.systemAudioOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                      on: model.systemAudioOn) {
                Picker("", selection: $model.systemAudioOn) {
                    Text("None").tag(false)
                    Text("System Audio").tag(true)
                }
                .labelsHidden().pickerStyle(.menu)
            }

            // Teleprompter — a script that scrolls on screen while recording.
            deviceRow(icon: "text.alignleft", on: model.teleprompterOn) {
                Button(model.teleprompterOn ? "Edit Script…" : "Teleprompter…") {
                    showTeleprompterSheet = true
                }
                .buttonStyle(.bordered).controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            Text("Camera + mic are recorded as separate, editable layers.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func deviceRow<Content: View>(icon: String, on: Bool,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(on ? Color.forgeAccent : Color(nsColor: .controlBackgroundColor))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(on ? Color.white : .secondary)
            }
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Per-mode content

    @ViewBuilder private var contentForMode: some View {
        switch model.mode {
        case .full:
            hint("The entire monitor will be recorded.", systemImage: "display")
        case .region:
            hint("After you press Start, drag to select the area you want to record.",
                 systemImage: "rectangle.dashed")
        case .window:
            windowChooser
        }
    }

    private func hint(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(Color.forgeAccent)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder private var windowChooser: some View {
        if model.windows.isEmpty {
            hint("No capturable windows found.", systemImage: "macwindow")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.windows.count) WINDOWS")
                    .font(.system(size: 10, weight: .semibold)).kerning(0.6)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.windows, id: \.windowID) { w in windowRow(w) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func windowRow(_ w: SCWindow) -> some View {
        let selected = model.selectedWindowID == w.windowID
        return HStack(spacing: 10) {
            Group {
                if let icon = appIcon(for: w) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: "macwindow").foregroundStyle(.secondary).frame(width: 26)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(w.owningApplication?.applicationName ?? "App")
                    .font(.system(size: 13, weight: .semibold))
                Text(w.title ?? "—")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.forgeAccent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.forgeAccent.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.forgeAccent : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedWindowID = w.windowID }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Spacer()
            Button {
                if let s = model.staged() { onStart(s) }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.mode == .window && model.selectedWindow == nil)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(.bar)
    }
}

// MARK: - Region drag-select overlay

/// Borderless full-display overlay that lets the user drag a rectangle.
/// Returns the rect in the display's POINTS (top-left origin) — exactly what
/// `SCStreamConfiguration.sourceRect` expects — or nil if cancelled (Esc).
enum RegionSelector {

    private static var window: OverlayWindow?

    static func select(on display: SCDisplay, completion: @escaping (CGRect?) -> Void) {
        // Grab a FROZEN shot of the display first, then show the overlay on top
        // of it. The dragged region draws this frozen image at full brightness
        // (rest dimmed) — so it always shows real screen content and never a
        // transparent "cut" that depends on what composites behind the window.
        Task { @MainActor in
            let frozen = await captureDisplay(display)
            present(on: display, frozen: frozen, completion: completion)
        }
    }

    private static func captureDisplay(_ display: SCDisplay) async -> CGImage? {
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.backingScaleFactor ?? 2
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(CGFloat(display.width) * scale))
        cfg.height = max(1, Int(CGFloat(display.height) * scale))
        cfg.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    @MainActor
    private static func present(on display: SCDisplay, frozen: CGImage?,
                                completion: @escaping (CGRect?) -> Void) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }) ?? NSScreen.main else { completion(nil); return }

        let frame = screen.frame
        let view = RegionDragView(frame: NSRect(origin: .zero, size: frame.size))
        view.frozen = frozen
        let win = OverlayWindow(contentRect: frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        win.level = .statusBar
        win.isOpaque = false
        win.backgroundColor = .clear
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = view
        win.setFrame(frame, display: true)

        view.onComplete = { rectInView in
            cleanup()
            guard let r = rectInView else { completion(nil); return }
            // rectInView is bottom-left origin within the screen. Convert to
            // display-relative TOP-LEFT points for SCStreamConfiguration.sourceRect.
            let topLeft = CGRect(x: r.minX,
                                 y: frame.height - r.maxY,
                                 width: r.width, height: r.height)
            completion(topLeft.integral)
        }

        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        win.makeFirstResponder(view)
        NSCursor.crosshair.push()
    }

    private static func cleanup() {
        NSCursor.pop()
        window?.orderOut(nil)
        window = nil
    }
}

/// The drag surface: dims the screen, draws the live selection, reports the
/// chosen rect on mouse-up (or nil on Esc). Shows a prominent centered hint
/// until the drag starts, and a live size read-out while dragging. Forces a
/// crosshair cursor via a tracking area + cursorUpdate (a pushed cursor alone
/// gets reset by the windowing system once the overlay takes focus).
final class RegionDragView: NSView {
    var onComplete: ((CGRect?) -> Void)?
    /// Frozen screenshot of the display, shown under the overlay so the dragged
    /// region always renders real screen content (bright) against a dimmed rest.
    var frozen: CGImage?
    private var start: NSPoint?
    private var current: NSRect = .zero
    private var trackingAreaRef: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    // MARK: Cursor (crosshair, reliably)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    // MARK: Drag

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = start else { return }
        let p = convert(event.locationInWindow, from: nil)
        current = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                         width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if current.width >= 8 && current.height >= 8 {
            onComplete?(current)
        } else {
            onComplete?(nil)   // a click, not a drag → cancel
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onComplete?(nil) }   // Esc
    }

    // MARK: Draw

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        let accent = NSColor.forgeAccent

        // Frozen screen everywhere, then a dim veil over it.
        if let frozen, let ctx { ctx.draw(frozen, in: bounds) }
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        if current.width > 0, current.height > 0 {
            // Selection: redraw the frozen screen at full brightness (or, with no
            // frozen image, fall back to a transparent punch).
            if let frozen, let ctx {
                ctx.saveGState()
                ctx.clip(to: current)
                ctx.draw(frozen, in: bounds)
                ctx.restoreGState()
            } else {
                NSColor.clear.setFill()
                current.fill(using: .clear)
            }
            accent.setStroke()
            let path = NSBezierPath(rect: current)
            path.lineWidth = 2
            path.stroke()
            drawSizeReadout()
        } else {
            drawCenteredHint()
        }
    }

    /// Big, prominent instruction pill in the middle of the screen.
    private func drawCenteredHint() {
        let title = "Drag to select an area to record"
        let sub = "Release to start  ·  Esc to cancel"

        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let subAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ]
        let tSize = title.size(withAttributes: titleAttr)
        let sSize = sub.size(withAttributes: subAttr)

        let padX: CGFloat = 32, padY: CGFloat = 22, gap: CGFloat = 8
        let boxW = max(tSize.width, sSize.width) + padX * 2
        let boxH = tSize.height + sSize.height + gap + padY * 2
        let box = NSRect(x: bounds.midX - boxW / 2, y: bounds.midY - boxH / 2,
                         width: boxW, height: boxH)

        let bg = NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16)
        NSColor.black.withAlphaComponent(0.55).setFill(); bg.fill()
        NSColor.forgeAccent.withAlphaComponent(0.9).setStroke(); bg.lineWidth = 1.5; bg.stroke()

        title.draw(at: NSPoint(x: box.midX - tSize.width / 2,
                               y: box.maxY - padY - tSize.height), withAttributes: titleAttr)
        sub.draw(at: NSPoint(x: box.midX - sSize.width / 2,
                             y: box.minY + padY), withAttributes: subAttr)
    }

    /// Live W×H read-out anchored just above the selection rectangle.
    private func drawSizeReadout() {
        let label = "\(Int(current.width)) × \(Int(current.height))"
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attr)
        let pillW = size.width + 16, pillH = size.height + 8
        var y = current.maxY + 6
        if y + pillH > bounds.maxY { y = current.maxY - pillH - 6 }   // flip below if no room above
        let pill = NSRect(x: min(max(current.minX, 4), bounds.maxX - pillW - 4),
                          y: y, width: pillW, height: pillH)
        let bg = NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6)
        NSColor.forgeAccent.setFill(); bg.fill()
        label.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 4), withAttributes: attr)
    }
}

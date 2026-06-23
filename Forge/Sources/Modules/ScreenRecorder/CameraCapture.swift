import AVFoundation
import AppKit

// MARK: - Webcam capture

/// Records the webcam to its own file alongside the screen recording, and
/// vends a live preview layer for the floating bubble. The camera is a SEPARATE
/// track (not baked into the screen capture) so the editor can place/resize it
/// freely on top — and so it isn't affected by zoom. (Phase 2/3 consume it.)
final class CameraCapture: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    private var configured = false
    private var stopCompletion: (() -> Void)?

    /// Ask for camera permission (once). Completion on main.
    static func authorize(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }

    static var hasCamera: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    /// Build the session around the front/default camera. Returns false if none.
    @discardableResult
    func configure(deviceID: String? = nil) -> Bool {
        guard !configured else { return true }
        session.beginConfiguration()
        session.sessionPreset = .high
        let chosen = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
        guard let device = chosen
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        // Mirror the camera (selfie view) for the recorded file, so the live
        // preview, editor overlay, and export all match what the user sees.
        if let oc = output.connection(with: .video), oc.isVideoMirroringSupported {
            oc.automaticallyAdjustsVideoMirroring = false
            oc.isVideoMirrored = true
        }

        let pl = AVCaptureVideoPreviewLayer(session: session)
        pl.videoGravity = .resizeAspectFill
        if let pc = pl.connection, pc.isVideoMirroringSupported {
            pc.automaticallyAdjustsVideoMirroring = false
            pc.isVideoMirrored = true
        }
        previewLayer = pl
        configured = true
        return true
    }

    /// Start the session + begin recording to `url`.
    func start(recordingTo url: URL) {
        guard configured else { return }
        if !session.isRunning {
            // startRunning blocks; do it off the main thread.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
                DispatchQueue.main.async {
                    try? FileManager.default.removeItem(at: url)
                    self?.output.startRecording(to: url, recordingDelegate: self!)
                }
            }
        } else {
            try? FileManager.default.removeItem(at: url)
            output.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// Stop recording; `completion` fires once the file is finalized.
    func stop(completion: @escaping () -> Void) {
        stopCompletion = completion
        if output.isRecording {
            output.stopRecording()          // delegate finalizes
        } else {
            session.stopRunning()
            let c = stopCompletion; stopCompletion = nil
            DispatchQueue.main.async { c?() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        session.stopRunning()
        let c = stopCompletion; stopCompletion = nil
        DispatchQueue.main.async { c?() }
    }
}

// MARK: - Floating live preview bubble

/// Borderless circular panel showing the live webcam while recording. Drag the
/// body to move; drag the bottom-right grip to resize. Excluded from the screen
/// capture (it's a Forge window), so it never bakes into the recording.
final class CameraBubblePanel: NSPanel {
    init(previewLayer: AVCaptureVideoPreviewLayer) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 150, height: 150),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar + 1
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = CameraBubbleView(previewLayer: previewLayer)
        contentView = view

        // Bottom-right of the active screen by default.
        if let f = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: f.maxX - 150 - 40, y: f.minY + 40))
        }
    }
    override var canBecomeKey: Bool { false }

    /// Fires (on the main thread) with the panel's global frame whenever the
    /// user moves or resizes the bubble — the recorder samples it as a keyframe.
    var onGeometryChange: ((NSRect) -> Void)? {
        get { (contentView as? CameraBubbleView)?.onGeometryChange }
        set { (contentView as? CameraBubbleView)?.onGeometryChange = newValue }
    }
}

final class CameraBubbleView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private var dragStart: NSPoint?
    private var resizing = false
    private let grip: CGFloat = 26
    var onGeometryChange: ((NSRect) -> Void)?

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.preview = previewLayer
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 150))
        wantsLayer = true
        layer = CALayer()
        preview.frame = bounds
        preview.cornerRadius = bounds.width / 2     // circular
        preview.masksToBounds = true
        layer?.addSublayer(preview)
        // Accent ring.
        layer?.borderColor = NSColor.forgeAccent.cgColor
        layer?.borderWidth = 3
        layer?.cornerRadius = bounds.width / 2
        layer?.masksToBounds = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = bounds
        preview.cornerRadius = bounds.width / 2
        layer?.cornerRadius = bounds.width / 2
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Bottom-right grip → resize (view is non-flipped: bottom-right = maxX, minY).
        resizing = p.x > bounds.maxX - grip && p.y < grip
        dragStart = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let win = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        dragStart = now
        if resizing {
            var s = win.frame
            let delta = dx                       // horizontal drag controls size
            let newW = min(360, max(90, s.width + delta))
            s.origin.y += (s.width - newW)       // keep top-left anchored visually
            s.size = NSSize(width: newW, height: newW)
            win.setFrame(s, display: true)
        } else {
            win.setFrameOrigin(NSPoint(x: win.frame.minX + dx, y: win.frame.minY + dy))
        }
        onGeometryChange?(win.frame)
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: bounds.maxX - grip, y: 0, width: grip, height: grip),
                      cursor: .crosshair)
        addCursorRect(NSRect(x: 0, y: grip, width: bounds.width, height: bounds.height - grip),
                      cursor: .openHand)
    }
}

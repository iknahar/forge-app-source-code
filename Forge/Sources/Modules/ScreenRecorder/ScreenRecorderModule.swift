import SwiftUI
import AppKit
import AVFoundation
import ScreenCaptureKit

/// Phase 1 of the Cursorful-style recorder (see RECORDING.md).
///
/// Captures the main display via **ScreenCaptureKit** (`SCStream`) and encodes
/// to an H.264 `.mov` with **AVAssetWriter**, including system audio. Region
/// selection, cursor emphasis, and the auto-zoom post-production pass come in
/// later phases — but the capture→encode→file pipeline lives here.
///
/// Why SCStream (not `CGWindowListCreateImage`/`CGDisplayStream`): those are
/// deprecated and broken on macOS 14+/26 (same root cause we hit for
/// screenshots in 1.0.14). SCStream is the supported path and also lets us
/// exclude Forge's own windows from the capture.
final class ScreenRecorderModule: NSObject, ForgeModule, ObservableObject,
                                  SCStreamOutput, SCStreamDelegate {
    let id = "screenRecorder"
    let name = "Screen Recorder"
    // `description` is overridden (not stored) because NSObject already
    // declares it via NSObjectProtocol — a stored property can't override it.
    override var description: String { "Record the screen to a video file" }
    let iconName = "record.circle"
    let category: ModuleCategory = .screen
    var isEnabled: Bool = true

    /// UI-facing state (menu bar / control bar observe these).
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsed: TimeInterval = 0   // seconds, excludes paused time
    @Published private(set) var isMicMuted = false          // mic toggle (HUD)
    @Published private(set) var isCameraLive = false        // camera bubble shown (HUD)

    // Capture + encode
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?               // microphone (separate track)
    private var outputURL: URL?

    // Floating control bar + elapsed ticker (main thread)
    private var controlPanel: NSPanel?
    private var regionHintPanel: NSPanel?     // border showing the recorded region (Region mode)
    private var elapsedTimer: Timer?

    // Webcam (Phase 1): recorded to a separate camera.mov + a live bubble.
    var cameraEnabled = false
    private let camera = CameraCapture()
    private var cameraBubble: CameraBubblePanel?
    private var cameraURL: URL?

    // Microphone (chosen in the picker; captured via SCStream on macOS 15+).
    var micEnabled = false
    var micDeviceID: String?
    var cameraDeviceID: String?
    var systemAudioOn = true
    var teleprompterScript = ""
    private var teleprompterPanel: TeleprompterPanel?

    // Phase 3a — interaction track (cursor/clicks) captured alongside the video.
    private let interaction = InteractionRecorder()
    private var recordedScreenSize: CGSize = .zero
    private var recordedOrigin: CGPoint = .zero   // global bottom-left of the captured canvas
    private var recordedScale: CGFloat = 1

    // Pause bookkeeping (outputQueue only). AVAssetWriter has no native
    // pause, so we accumulate the paused duration and subtract it from every
    // appended sample's timestamp — paused time is removed, not frozen.
    private var paused = false
    private var micMuted = false          // outputQueue only — drops mic buffers when true
    private var pauseOffset = CMTime.zero
    private var pauseAnchorPTS: CMTime?   // PTS of the first sample seen while paused

    // All writer mutation happens on this serial queue (same queue SCStream
    // delivers samples on), so the sample handler and stop/finalize can never
    // race on the writer/inputs.
    private let outputQueue = DispatchQueue(label: "com.toolkit.forge.recorder.output")
    private var startedSession = false   // outputQueue only
    private var finishing = false        // outputQueue only

    func activate() {}
    func deactivate() { if isRecording { stopRecording() } }

    // MARK: - Public control

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func togglePause() { isPaused ? resumeRecording() : pauseRecording() }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        interaction.pause()
        outputQueue.async { [weak self] in self?.paused = true }
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        isPaused = false
        interaction.resume()
        // The handler clears `paused` and folds the gap into `pauseOffset`
        // on the next sample, so just flip the flag here.
        outputQueue.async { [weak self] in self?.paused = false }
    }

    /// Mute/unmute the microphone live — muted mic buffers are dropped, leaving
    /// silence in the mic track for that span. Reflected in preview + export.
    func toggleMicMute() {
        guard isRecording, micEnabled else { return }
        isMicMuted.toggle()
        let v = isMicMuted
        outputQueue.async { [weak self] in self?.micMuted = v }
    }

    /// Show/hide the live avatar bubble mid-recording. While hidden we stop
    /// sampling its position so the recorded path holds (and the editor can
    /// hide it for that span).
    func toggleCamera() {
        guard isRecording, cameraEnabled else { return }
        if isCameraLive {
            cameraBubble?.orderOut(nil)
            isCameraLive = false
            interaction.cameraOff()      // omit the avatar from export for this span
        } else {
            cameraBubble?.orderFrontRegardless()
            isCameraLive = true
            interaction.cameraOn()
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            return
        }
        // Ask first: full monitor / window / region (+ which monitor). The
        // picker resolves everything (incl. the region rect) and hands back a
        // concrete CaptureScope; nil means the user cancelled.
        CaptureScopePicker.present { [weak self] scope, opts in
            guard let self = self, let scope = scope, let opts = opts else { return }
            self.cameraEnabled = opts.cameraDeviceID != nil
            self.cameraDeviceID = opts.cameraDeviceID
            self.micEnabled = opts.micDeviceID != nil
            self.micDeviceID = opts.micDeviceID
            self.systemAudioOn = opts.systemAudio
            self.teleprompterScript = opts.teleprompterScript ?? ""
            // Microphone needs its own TCC grant; ask before capture starts.
            if self.micEnabled {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        if !granted { self.micEnabled = false }
                        self.beginRecording(scope: scope)
                    }
                }
            } else {
                self.beginRecording(scope: scope)
            }
        }
    }

    // MARK: - Camera (Phase 1)

    /// Start webcam capture to `<movie>.camera.mov` + show the live bubble.
    private func startCameraIfEnabled() {
        guard cameraEnabled, let movie = outputURL else { return }
        let camURL = movie.deletingPathExtension().appendingPathExtension("camera.mov")
        CameraCapture.authorize { [weak self] ok in
            guard let self = self, ok, self.isRecording, self.camera.configure(deviceID: self.cameraDeviceID),
                  let pl = self.camera.previewLayer else { return }
            self.cameraURL = camURL
            self.camera.start(recordingTo: camURL)
            let bubble = CameraBubblePanel(previewLayer: pl)
            // Sample the avatar's position/size as the user drags it live, so
            // the editor + export can replay the movement.
            bubble.onGeometryChange = { [weak self] frame in
                self?.interaction.recordCameraKeyframe(
                    centerX: Double(frame.midX), centerY: Double(frame.midY), height: Double(frame.height))
            }
            bubble.orderFrontRegardless()
            self.cameraBubble = bubble
            self.isCameraLive = true
            // Seed the starting position so a never-moved bubble still lands in
            // the right place in the editor (fixes the side-swap default).
            let f0 = bubble.frame
            self.interaction.recordCameraKeyframe(
                centerX: Double(f0.midX), centerY: Double(f0.midY), height: Double(f0.height))
        }
    }

    private func stopCameraIfNeeded() {
        cameraBubble?.orderOut(nil)
        cameraBubble = nil
        isCameraLive = false
        isMicMuted = false
        camera.stop { }     // finalizes camera.mov asynchronously
    }

    /// Backing-scale (pixels-per-point) for a given display, via its NSScreen.
    private func scale(for displayID: CGDirectDisplayID) -> CGFloat {
        nsScreen(for: displayID)?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// The NSScreen for a display ID (its `.frame` is global, bottom-left origin).
    private func nsScreen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    /// Builds the SCContentFilter + SCStreamConfiguration for the chosen scope
    /// and starts the capture→encode pipeline.
    private func beginRecording(scope: CaptureScope) {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                )
                let ourApps = content.applications.filter {
                    $0.bundleIdentifier == Bundle.main.bundleIdentifier
                }

                let filter: SCContentFilter
                let config = SCStreamConfiguration()
                let pxW: Int, pxH: Int
                var regionHint: (id: CGDirectDisplayID, rect: CGRect)? = nil

                switch scope {
                case .display(let display):
                    let sc = self.scale(for: display.displayID)
                    pxW = max(1, Int(CGFloat(display.width) * sc))
                    pxH = max(1, Int(CGFloat(display.height) * sc))
                    filter = SCContentFilter(display: display,
                                             excludingApplications: ourApps, exceptingWindows: [])
                    self.recordedScreenSize = CGSize(width: display.width, height: display.height)
                    self.recordedScale = sc
                    // Whole display: its NSScreen frame origin (bottom-left global; (0,0) for primary).
                    self.recordedOrigin = self.nsScreen(for: display.displayID)?.frame.origin ?? .zero

                case .window(let window):
                    // Scale of whichever screen the window's centre sits on.
                    let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
                    let sc = NSScreen.screens.first { $0.frame.contains(centre) }?.backingScaleFactor
                        ?? NSScreen.main?.backingScaleFactor ?? 2
                    pxW = max(1, Int(window.frame.width * sc))
                    pxH = max(1, Int(window.frame.height * sc))
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    self.recordedScreenSize = window.frame.size
                    self.recordedScale = sc
                    // SCWindow.frame is TOP-LEFT global; flip to bottom-left using the
                    // primary display's height (same space as NSEvent.mouseLocation).
                    let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                        ?? NSScreen.main?.frame.height ?? 0
                    self.recordedOrigin = CGPoint(x: window.frame.minX, y: primaryH - window.frame.maxY)

                case .region(let display, let rect):
                    let sc = self.scale(for: display.displayID)
                    pxW = max(1, Int(rect.width * sc))
                    pxH = max(1, Int(rect.height * sc))
                    filter = SCContentFilter(display: display,
                                             excludingApplications: ourApps, exceptingWindows: [])
                    config.sourceRect = rect          // points, top-left, display-relative
                    self.recordedScreenSize = rect.size
                    self.recordedScale = sc
                    regionHint = (display.displayID, rect)
                    // Region origin (bottom-left global): display origin + rect offset,
                    // mirroring the region-hint math (df.maxY - rect.maxY).
                    if let df = self.nsScreen(for: display.displayID)?.frame {
                        self.recordedOrigin = CGPoint(x: df.minX + rect.minX, y: df.maxY - rect.maxY)
                    } else {
                        self.recordedOrigin = .zero
                    }
                }

                config.width = pxW
                config.height = pxH
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)  // 60fps cap
                config.queueDepth = 6
                // Hide the real cursor — the editor/export draw an enlarged
                // synthetic pointer from the interaction track instead (the OS
                // can't scale the captured system cursor).
                config.showsCursor = false
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.capturesAudio = self.systemAudioOn   // system audio (macOS 13+)
                // Microphone (macOS 15+): captured as its own track alongside
                // system audio, so the user can narrate.
                if #available(macOS 15.0, *), self.micEnabled {
                    config.captureMicrophone = true
                    if let id = self.micDeviceID { config.microphoneCaptureDeviceID = id }
                }

                try self.makeWriter(width: pxW, height: pxH)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.outputQueue)
                if #available(macOS 15.0, *), self.micEnabled {
                    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: self.outputQueue)
                }
                try await stream.startCapture()
                self.stream = stream
                await MainActor.run {
                    self.isRecording = true
                    self.isPaused = false
                    self.elapsed = 0
                    self.interaction.start()
                    self.showControlBar()
                    self.showTeleprompter()
                    self.showRegionHint(regionHint)
                    self.startElapsedTimer()
                    self.startCameraIfEnabled()
                }
            } catch {
                NSLog("[Forge Recorder] start failed: \(error.localizedDescription)")
                self.outputQueue.async { self.resetWriterState() }
                await MainActor.run { self.isRecording = false }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isPaused = false
        hideControlBar()
        stopElapsedTimer()
        stopCameraIfNeeded()
        let s = stream
        stream = nil
        Task { [weak self] in
            guard let self = self else { return }
            try? await s?.stopCapture()
            self.finalizeOnOutputQueue()
        }
    }

    // MARK: - Control bar + elapsed ticker (main thread)

    private func showControlBar() {
        guard controlPanel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar + 1
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecorderControlBar(recorder: self))
        if let screen = NSScreen.main {
            let f = screen.frame
            let sz = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - sz.width / 2, y: f.minY + 80))
        }
        panel.orderFrontRegardless()
        controlPanel = panel
    }

    private func hideControlBar() {
        controlPanel?.orderOut(nil)
        controlPanel = nil
        hideRegionHint()
        hideTeleprompter()
    }

    /// Floating, auto-scrolling teleprompter (recording-only; a Forge window the
    /// capture filter excludes, so it never appears in the recording).
    private func showTeleprompter() {
        guard teleprompterPanel == nil,
              !teleprompterScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let panel = TeleprompterPanel(script: teleprompterScript)
        if let f = NSScreen.main?.visibleFrame {
            let sz = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - sz.width / 2, y: f.maxY - sz.height - 80))
        }
        panel.orderFrontRegardless()
        teleprompterPanel = panel
    }

    private func hideTeleprompter() {
        teleprompterPanel?.orderOut(nil)
        teleprompterPanel = nil
    }

    /// Show a persistent brand-red border around the recorded region (Region
    /// mode only), so the user always sees what's being captured. It's a Forge
    /// window, so the capture filter excludes it — the border never bakes in.
    private func showRegionHint(_ info: (id: CGDirectDisplayID, rect: CGRect)?) {
        guard let info = info, regionHintPanel == nil else { return }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == info.id
        } ?? NSScreen.main
        guard let screen = screen else { return }
        let df = screen.frame
        // `rect` is top-left, display-relative points → global, bottom-left origin.
        let global = NSRect(x: df.minX + info.rect.minX,
                            y: df.maxY - info.rect.maxY,
                            width: info.rect.width, height: info.rect.height)
        let panel = NSPanel(contentRect: global,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar                 // below the control bar (statusBar + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true          // click-through to the content below
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RegionRecordingHint())
        panel.orderFrontRegardless()
        regionHintPanel = panel
    }

    private func hideRegionHint() {
        regionHintPanel?.orderOut(nil)
        regionHintPanel = nil
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording, !self.isPaused else { return }
            self.elapsed += 0.5
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// Finish the interaction recorder and write `<movie>.forgerec.json`
    /// beside the video (Phase 3a). Must run on the main thread (removes the
    /// NSEvent monitors).
    @discardableResult
    private func writeInteractionSidecar(for movieURL: URL) -> InteractionTrack {
        let track = interaction.finish(screenSize: recordedScreenSize, scale: recordedScale, origin: recordedOrigin)
        let sidecar = movieURL.deletingPathExtension().appendingPathExtension("forgerec.json")
        do {
            let data = try JSONEncoder().encode(track)
            try data.write(to: sidecar, options: .atomic)
            NSLog("[Forge Recorder] interaction track: \(track.events.count) events → \(sidecar.lastPathComponent)")
        } catch {
            NSLog("[Forge Recorder] sidecar write failed: \(error.localizedDescription)")
        }
        return track
    }

    // MARK: - Writer setup / teardown

    private func makeWriter(width: Int, height: Int) throws {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let folder = movies.appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent("Forge-Recording \(fmt.string(from: Date())).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        vInput.expectsMediaDataInRealTime = true
        if writer.canAdd(vInput) { writer.add(vInput) }

        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48000,
            AVEncoderBitRateKey: 128_000,
        ])
        aInput.expectsMediaDataInRealTime = true
        if writer.canAdd(aInput) { writer.add(aInput) }

        // Microphone → its own AAC track (only when a mic was chosen).
        var mInput: AVAssetWriterInput?
        if micEnabled {
            let m = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 96_000,
            ])
            m.expectsMediaDataInRealTime = true
            if writer.canAdd(m) { writer.add(m); mInput = m }
        }

        guard writer.startWriting() else {
            throw NSError(domain: "ForgeRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "startWriting failed"
            ])
        }

        self.outputURL = url
        self.writer = writer
        self.videoInput = vInput
        self.audioInput = aInput
        self.micInput = mInput
        self.outputQueue.sync {
            self.startedSession = false
            self.finishing = false
            self.paused = false
            self.micMuted = false
            self.pauseOffset = .zero
            self.pauseAnchorPTS = nil
        }
    }

    /// Finalize the file. Runs the markAsFinished/finishWriting on the same
    /// serial queue as sample delivery so nothing appends after we close.
    private func finalizeOnOutputQueue() {
        outputQueue.async { [weak self] in
            guard let self = self, let writer = self.writer, !self.finishing else { return }
            self.finishing = true
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.micInput?.markAsFinished()
            let url = self.outputURL
            let camURL = self.cameraURL
            writer.finishWriting {
                let ok = writer.status == .completed
                if !ok {
                    NSLog("[Forge Recorder] finish status=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "nil")")
                }
                DispatchQueue.main.async {
                    // Write the interaction-track sidecar (Phase 3a), then OPEN
                    // THE EDITOR (Phase 3c) for this recording — manual box-zoom,
                    // background, and Export (which drives RecordingRenderer).
                    // No auto-render: the user decides the zoom in the editor.
                    if ok, let url = url {
                        let track = self.writeInteractionSidecar(for: url)
                        let cam = (camURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
                        RecordingEditor.open(movieURL: url, track: track, cameraURL: cam)
                    }
                }
                self.outputQueue.async { self.resetWriterState() }
            }
        }
    }

    private func resetWriterState() {
        writer = nil
        videoInput = nil
        audioInput = nil
        micInput = nil
        outputURL = nil
        cameraURL = nil
        recordedOrigin = .zero
        startedSession = false
        finishing = false
        paused = false
        micMuted = false
        pauseOffset = .zero
        pauseAnchorPTS = nil
    }

    // MARK: - SCStreamOutput (runs on outputQueue)

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !finishing, let writer = writer, writer.status == .writing,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // Drop SCK "incomplete" screen frames (idle / blank).
        if type == .screen,
           let attaches = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
               as? [[SCStreamFrameInfo: Any]],
           let raw = attaches.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Pause handling: while paused, mark where the gap started and drop
        // every sample. On the first sample after resume, fold the gap into
        // `pauseOffset` so it's subtracted from now on (paused time vanishes).
        if paused {
            if pauseAnchorPTS == nil { pauseAnchorPTS = pts }
            return
        }
        if let anchor = pauseAnchorPTS {
            pauseOffset = pauseOffset + (pts - anchor)
            pauseAnchorPTS = nil
        }

        // Microphone (macOS 15+) arrives as its own stream type → its own track.
        // While muted we drop the buffers (silence in the mic track).
        if #available(macOS 15.0, *), type == .microphone {
            guard startedSession, !micMuted, let m = micInput, m.isReadyForMoreMediaData,
                  let buf = retimed(sampleBuffer, by: pauseOffset) else { return }
            m.append(buf)
            return
        }

        switch type {
        case .screen:
            if !startedSession {
                writer.startSession(atSourceTime: pts)   // pauseOffset is .zero here
                startedSession = true
            }
            guard let v = videoInput, v.isReadyForMoreMediaData,
                  let buf = retimed(sampleBuffer, by: pauseOffset) else { return }
            v.append(buf)

        case .audio:
            guard startedSession, let a = audioInput, a.isReadyForMoreMediaData,
                  let buf = retimed(sampleBuffer, by: pauseOffset) else { return }
            a.append(buf)

        @unknown default:
            break
        }
    }

    /// Copy of `sb` with all timestamps shifted back by `offset` (to delete
    /// paused time). Returns the original untouched when `offset` is zero.
    private func retimed(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        if offset == .zero { return sb }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
                sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return sb }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
                sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count) == noErr
        else { return sb }
        for i in 0..<count {
            if infos[i].presentationTimeStamp.isValid {
                infos[i].presentationTimeStamp = infos[i].presentationTimeStamp - offset
            }
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = infos[i].decodeTimeStamp - offset
            }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sb,
            sampleTimingEntryCount: count, sampleTimingArray: &infos, sampleBufferOut: &out)
        return status == noErr ? out : sb
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Forge Recorder] stream stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.stopRecording()
        }
    }
}

// MARK: - Region recording hint

/// A brand-red border drawn around the region being recorded (Region mode).
/// Hosted in a click-through Forge panel that the capture filter excludes, so
/// it stays on screen for the user but never appears in the recording.
private struct RegionRecordingHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.forgeAccent, lineWidth: 3)
            .padding(1.5)
            .allowsHitTesting(false)
    }
}

// MARK: - Floating control bar

/// Small always-on-top recording HUD: ● elapsed · Pause/Resume · Stop.
/// Lives in its own NSPanel which is a Forge window, so the SCStream filter
/// (which excludes Forge's own windows) keeps it OUT of the recording.
private struct RecorderControlBar: View {
    @ObservedObject var recorder: ScreenRecorderModule

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(recorder.isPaused ? Color.secondary : Color.forgeAccent)
                .frame(width: 9, height: 9)

            Text(timeString(recorder.elapsed))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(minWidth: 46, alignment: .leading)

            Button { recorder.togglePause() } label: {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(recorder.isPaused ? "Resume" : "Pause")

            if recorder.cameraEnabled {
                Button { recorder.toggleCamera() } label: {
                    Image(systemName: recorder.isCameraLive ? "video.fill" : "video.slash.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(recorder.isCameraLive ? .white : Color.forgeAccent)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(recorder.isCameraLive ? "Hide camera" : "Show camera")
            }

            if recorder.micEnabled {
                Button { recorder.toggleMicMute() } label: {
                    Image(systemName: recorder.isMicMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(recorder.isMicMuted ? Color.forgeAccent : .white)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(recorder.isMicMuted ? "Unmute microphone" : "Mute microphone")
            }

            Button { recorder.stopRecording() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color.forgeAccent)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Stop")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        .padding(4)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

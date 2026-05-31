import AVFoundation
import AppKit
import Combine

// MARK: - Sound Types

enum AmbientSound: String, CaseIterable, Identifiable, Codable {
    case rain       = "Rain"
    case whiteNoise = "White Noise"
    case coffeeShop = "Coffee Shop"
    case deepFocus  = "Deep Focus"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .rain:       return "cloud.rain.fill"
        case .whiteNoise: return "waveform"
        case .coffeeShop: return "cup.and.saucer.fill"
        case .deepFocus:  return "brain.head.profile"
        }
    }
}

// MARK: - Module

/// Ambient Focus Sounds — procedurally generated noise textures for
/// concentration. Auto-pauses when a meeting starts and resumes when
/// it ends, so the user never has to reach for a mute button.
final class AmbientSoundModule: ForgeModule, ObservableObject {

    let id = "ambientSound"
    let name = "Focus Sounds"
    let description = "Ambient noise for concentration"
    let iconName = "headphones"
    let category: ModuleCategory = .system
    var isEnabled: Bool = true

    // MARK: - Published state (UI-facing)

    @Published var currentSound: AmbientSound = .rain
    @Published private(set) var isPlaying = false
    /// `true` when the engine is paused because a meeting started.
    /// Distinguished from a manual pause so we can auto-resume later.
    @Published private(set) var autoPaused = false
    @Published var volume: Float = 0.5 {
        didSet { audioVolume = volume }
    }

    // MARK: - Audio engine

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    /// Audio-thread-safe copies — read from the render block without
    /// touching @Published wrappers. Updated on the main thread; a
    /// Float/enum read from the audio thread is safe (no tearing on
    /// 64-bit platforms for values <= word size).
    private var audioSoundType: AmbientSound = .rain
    private var audioVolume: Float = 0.5

    // Generator state (persistent across render callbacks)
    private var brownState: Float = 0       // random-walk state for brown/rain noise
    private var pinkState: [Float] = Array(repeating: 0, count: 7)

    // MARK: - Meeting auto-pause

    weak var calendarRef: CalendarModule?
    private var meetingCheckTimer: Timer?
    private var wasMeetingOngoing = false

    // MARK: - Lifecycle

    func activate() {
        startMeetingWatch()
        print("[Forge AmbientSound] Activated")
    }

    func deactivate() {
        stop()
        meetingCheckTimer?.invalidate()
        meetingCheckTimer = nil
        print("[Forge AmbientSound] Deactivated")
    }

    // MARK: - Playback API

    func play(sound: AmbientSound? = nil) {
        if let s = sound {
            currentSound = s
            audioSoundType = s
        } else {
            audioSoundType = currentSound
        }
        autoPaused = false

        if engine != nil { stop() }
        buildEngine()

        do {
            try engine?.start()
            isPlaying = true
            print("[Forge AmbientSound] Playing \(currentSound.rawValue)")
        } catch {
            print("[Forge AmbientSound] Failed to start: \(error)")
            isPlaying = false
        }
    }

    func stop() {
        engine?.stop()
        sourceNode = nil
        engine = nil
        isPlaying = false
        autoPaused = false
        // Reset generator state
        brownState = 0
        pinkState = Array(repeating: 0, count: 7)
    }

    func toggle() {
        if isPlaying {
            stop()
        } else {
            play()
        }
    }

    // MARK: - Audio Engine Setup

    private func buildEngine() {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44100,
            channels: 1
        )!

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList -> OSStatus in
            guard let self = self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            let soundType = self.audioSoundType
            let vol = self.audioVolume

            for buffer in abl {
                let buf = UnsafeMutableBufferPointer<Float>(buffer)
                for frame in 0..<Int(frameCount) {
                    buf[frame] = self.generateSample(type: soundType) * vol
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        self.engine = engine
        self.sourceNode = node
    }

    // MARK: - Audio Synthesis

    /// Generates one sample for the given sound type. Called at 44.1 kHz
    /// on the audio thread. All state mutations are on simple Floats —
    /// no locks needed.
    private func generateSample(type: AmbientSound) -> Float {
        switch type {
        case .whiteNoise:
            return Float.random(in: -1...1) * 0.3

        case .rain:
            // Brown noise: integrate white noise with a leak factor.
            // Produces a warm, low rumble that resembles steady rain.
            let white = Float.random(in: -1...1)
            brownState = brownState * 0.98 + white * 0.02
            // Clamp to prevent drift over long sessions
            brownState = max(-1, min(1, brownState))
            return brownState * 0.7

        case .coffeeShop:
            // Pink noise (1/f): Voss-McCartney algorithm using 7 octaves.
            // Produces a warmer, more natural rumble — think distant
            // chatter and clinking cups.
            return pinkNoiseSample() * 0.35

        case .deepFocus:
            // Very deep brown noise — heavier integration produces an
            // ultra-low drone that masks distractions.
            let white = Float.random(in: -1...1)
            brownState = brownState * 0.995 + white * 0.005
            brownState = max(-1, min(1, brownState))
            return brownState * 0.8
        }
    }

    /// Voss-McCartney pink noise generator — uses 7 octave bands to
    /// approximate a 1/f spectrum. Each band updates at half the rate
    /// of the previous one.
    private var pinkCounter: UInt32 = 0
    private func pinkNoiseSample() -> Float {
        pinkCounter &+= 1
        var sum: Float = 0
        // Update each octave band when its bit flips
        for i in 0..<7 {
            if pinkCounter & (1 << i) != 0 {
                pinkState[i] = Float.random(in: -1...1)
                break   // Voss: update only the lowest changed bit
            }
        }
        for val in pinkState { sum += val }
        return sum / 7.0
    }

    // MARK: - Meeting Auto-Pause

    private func startMeetingWatch() {
        meetingCheckTimer?.invalidate()
        meetingCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkMeeting()
        }
        meetingCheckTimer?.tolerance = 3
    }

    private func checkMeeting() {
        guard let cal = calendarRef else { return }
        let now = Date()
        let meetingNow = cal.activeEvents.contains {
            $0.startDate <= now && $0.endDate > now && !$0.isAllDay
        }

        if meetingNow && !wasMeetingOngoing && isPlaying {
            // Meeting just started — auto-pause
            engine?.pause()
            isPlaying = false
            autoPaused = true
            print("[Forge AmbientSound] Auto-paused for meeting")
        } else if !meetingNow && wasMeetingOngoing && autoPaused {
            // Meeting just ended — auto-resume
            do {
                try engine?.start()
                isPlaying = true
                autoPaused = false
                print("[Forge AmbientSound] Auto-resumed after meeting")
            } catch {
                print("[Forge AmbientSound] Resume failed: \(error)")
                autoPaused = false
            }
        }

        wasMeetingOngoing = meetingNow
    }
}

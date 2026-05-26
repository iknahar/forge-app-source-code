import AppKit
import Vision
import NaturalLanguage
import Network

/// Pipeline for the on-screen translator that lives inside the screenshot
/// tool: take the selection's pixels → run Vision OCR (per-line bounding
/// boxes preserved) → translate each block → return structured blocks
/// the overlay can paint over the original text.
///
/// The translation backend itself is still a stub (Apple's
/// `TranslationSession` is only exposed via SwiftUI's
/// `.translationPresentation` on macOS 14, and we want inline results).
/// When a real backend is wired in, only `translateText(_:from:to:)`
/// needs to change — every layer above it is structured around the new
/// `TextBlock` shape.
struct ScreenTranslator {

    /// One recognized line of text from the image. The `boundingBox` is
    /// in Vision's normalised coordinate space (0...1, **bottom-left**
    /// origin) — the overlay flips Y when drawing.
    struct TextBlock: Identifiable {
        let id = UUID()
        let original: String
        var translated: String?
        let boundingBox: CGRect
    }

    /// What the UI gets back from a translate request.
    struct Result {
        var blocks: [TextBlock]
        let detectedLanguage: String?   // BCP-47 (e.g. "sv"), via NLLanguageRecognizer
        let sourceLanguage: String      // What we actually translated FROM
        let targetLanguage: String      // What the user asked for
        /// Set when translation couldn't run — UI shows source text + this
        /// note instead of pretending the call succeeded.
        let translationUnavailableReason: String?
        /// True when the failure mode is "device has no network" — the
        /// overlay shows a small offline badge instead of the generic
        /// "translation coming" copy.
        let isOffline: Bool

        var joinedSourceText: String {
            blocks.map(\.original).joined(separator: "\n")
        }
        var joinedTranslatedText: String {
            blocks.compactMap(\.translated).joined(separator: "\n")
        }
    }

    enum TranslateError: Error, LocalizedError {
        case noTextFound
        case ocrFailed(String)
        var errorDescription: String? {
            switch self {
            case .noTextFound:        return "No text found in the selected region."
            case .ocrFailed(let s):   return "Couldn't read text from the image: \(s)"
            }
        }
    }

    /// Languages exposed in the on-screen language dropdowns + Settings.
    /// "auto" only valid as a SOURCE language.
    static let supportedLanguages: [(code: String, label: String)] = [
        ("auto", "Auto-detect"),
        ("sv",   "Swedish"),
        ("en",   "English"),
        ("es",   "Spanish"),
        ("fr",   "French"),
        ("de",   "German"),
        ("it",   "Italian"),
        ("pt",   "Portuguese"),
        ("nl",   "Dutch"),
        ("da",   "Danish"),
        ("no",   "Norwegian"),
        ("fi",   "Finnish"),
        ("ja",   "Japanese"),
        ("ko",   "Korean"),
        ("zh",   "Chinese"),
        ("ar",   "Arabic"),
        ("ru",   "Russian"),
        ("hi",   "Hindi"),
        ("bn",   "Bengali"),
    ]

    static func label(forCode code: String) -> String {
        supportedLanguages.first(where: { $0.code == code })?.label ?? code
    }

    // MARK: - Main entry point (OCR + per-block translate)

    /// Run the full OCR → detect → translate pipeline. Returns a
    /// `Result` with `blocks` populated even when translation fails
    /// (the overlay then shows the source text dimmed but visible).
    static func translate(image: CGImage,
                          sourceLanguage: String,
                          targetLanguage: String) async throws -> Result {
        // 1. OCR — per-line observations with bounding boxes
        let observations = try await runOCR(on: image, hintedLanguage: sourceLanguage)
        guard !observations.isEmpty else { throw TranslateError.noTextFound }

        var blocks: [TextBlock] = observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return TextBlock(
                original: candidate.string,
                translated: nil,
                boundingBox: obs.boundingBox   // Vision unit coords, bottom-left
            )
        }

        // 2. Language detection across the combined OCR text. If the
        // user asked for "auto", this becomes the source language.
        let combined = blocks.map(\.original).joined(separator: " ")
        let detected = detectLanguage(text: combined)
        let resolvedSource: String = {
            if sourceLanguage == "auto" { return detected ?? "und" }
            return sourceLanguage
        }()

        // 3. Translate each block. Offline check first — if no network,
        // bail with the offline flag so the overlay shows the small
        // "Offline" badge instead of a misleading "coming soon" hint.
        var reason: String? = nil
        var offline = false
        if resolvedSource == targetLanguage {
            reason = "Source and target are the same — nothing to translate."
        } else if !Reachability.isOnline() {
            offline = true
            reason = "You're offline. Translation needs an internet connection."
        } else {
            // Translate one line at a time. This produces results
            // incrementally — when we make this async-stream-based the
            // overlay will reveal blocks as they land.
            await withTaskGroup(of: (Int, String?).self) { group in
                for i in blocks.indices {
                    let original = blocks[i].original
                    group.addTask {
                        let t = await translateText(
                            original,
                            from: resolvedSource,
                            to: targetLanguage
                        )
                        return (i, t)
                    }
                }
                for await (i, t) in group {
                    blocks[i].translated = t
                }
            }
            if blocks.allSatisfy({ $0.translated == nil }) {
                reason = "Translation service unreachable. Try again in a moment."
            }
        }

        return Result(
            blocks: blocks,
            detectedLanguage: detected,
            sourceLanguage: resolvedSource,
            targetLanguage: targetLanguage,
            translationUnavailableReason: reason,
            isOffline: offline
        )
    }

    // MARK: - OCR

    private static func runOCR(on image: CGImage,
                               hintedLanguage: String) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[VNRecognizedTextObservation], Error>) in
            let request = VNRecognizeTextRequest { req, err in
                if let err = err {
                    cont.resume(throwing: TranslateError.ocrFailed(err.localizedDescription))
                    return
                }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                cont.resume(returning: observations)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if hintedLanguage != "auto" {
                request.recognitionLanguages = [hintedLanguage, "en"]
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: TranslateError.ocrFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Language detection

    /// Best-guess BCP-47 code from the recognized text. Returns nil for
    /// very short / ambiguous input.
    static func detectLanguage(text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    // MARK: - Translation backend (online — no API key)

    /// Translate a single string. Two-stage fallback:
    ///   1. Google Translate's public web endpoint
    ///      (`translate.googleapis.com/translate_a/single`) — same
    ///      endpoint browser extensions use, no API key needed.
    ///   2. MyMemory free API (`api.mymemory.translated.net/get`) —
    ///      backup when Google rate-limits or blocks the request.
    /// Both expect BCP-47 codes; we strip any region suffix ("en-US"
    /// → "en") before sending.
    private static func translateText(_ text: String,
                                      from: String,
                                      to: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let src = simpleCode(from)
        let dst = simpleCode(to)
        guard src != dst else { return text }

        if let google = await googleTranslate(text: trimmed, from: src, to: dst) {
            return google
        }
        if let mm = await myMemoryTranslate(text: trimmed, from: src, to: dst) {
            return mm
        }
        return nil
    }

    /// Strip region/script tags so backend gets a plain ISO 639-1 code.
    private static func simpleCode(_ code: String) -> String {
        if let i = code.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(code[..<i]).lowercased()
        }
        return code.lowercased()
    }

    /// Public Google endpoint used by browser extensions. Returns nil
    /// on any error so the caller can fall through to MyMemory.
    private static func googleTranslate(text: String,
                                        from: String,
                                        to: String) async -> String? {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        comps?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl",     value: from),    // source
            URLQueryItem(name: "tl",     value: to),      // target
            URLQueryItem(name: "dt",     value: "t"),     // translation only
            URLQueryItem(name: "q",      value: text),
        ]
        guard let url = comps?.url else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("Mozilla/5.0 Forge", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            // Response is a deeply-nested JSON array:
            //   [ [ ["translated chunk", "source chunk", ...], ... ], ... ]
            // We rebuild the translation by joining every chunk[0] in
            // outer[0].
            guard
                let raw = try JSONSerialization.jsonObject(with: data) as? [Any],
                let outer = raw.first as? [Any]
            else { return nil }
            let chunks: [String] = outer.compactMap { item in
                guard let arr = item as? [Any] else { return nil }
                return arr.first as? String
            }
            let joined = chunks.joined()
            return joined.isEmpty ? nil : joined
        } catch {
            return nil
        }
    }

    /// MyMemory fallback. Free up to 5000 chars/day per IP, no key.
    private static func myMemoryTranslate(text: String,
                                          from: String,
                                          to: String) async -> String? {
        var comps = URLComponents(string: "https://api.mymemory.translated.net/get")
        comps?.queryItems = [
            URLQueryItem(name: "q",        value: text),
            URLQueryItem(name: "langpair", value: "\(from)|\(to)"),
        ]
        guard let url = comps?.url else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let responseData = json["responseData"] as? [String: Any],
                let translated = responseData["translatedText"] as? String,
                !translated.isEmpty
            else { return nil }
            return translated
        } catch {
            return nil
        }
    }

    // MARK: - Fallback escape hatch

    /// Copies the source text to the clipboard and opens macOS's
    /// Translate app, so the user has a one-paste path to finish the
    /// job while we wire up an in-app backend.
    static func openInSystemTranslate(text: String, target: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let url = URL(string: "translate://") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Reachability helper

/// Tiny wrapper around `NWPathMonitor` so the translator can do a
/// best-effort offline check before issuing HTTP requests. The path
/// monitor's status is observed continuously in the background; calls
/// to `isOnline()` are a synchronous snapshot.
final class Reachability {
    static let shared = Reachability()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "forge.reachability")
    private var currentStatus: NWPath.Status = .satisfied

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.currentStatus = path.status
        }
        monitor.start(queue: queue)
    }

    static func isOnline() -> Bool {
        shared.currentStatus == .satisfied
    }
}

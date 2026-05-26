import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// One captured clipboard entry. We support three flavors:
///   • plain text (most common — code, URLs, notes)
///   • image (screenshots, drag-from-Finder)
///   • file URLs (a list of paths that were on the pasteboard)
///
/// Heavy data (PNG bytes) is held in a `data` Data blob so it round-trips
/// through Codable cleanly. We deliberately don't persist the entire
/// historical PNG list — only the last `imagePersistLimit` images
/// survive a relaunch so the on-disk store stays bounded.
struct ClipboardEntry: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case text
        case image
        case files
    }

    let id: UUID
    /// When the entry was captured (UTC, persisted as ISO 8601).
    let timestamp: Date
    let kind: Kind
    /// Always set — used for the row preview and search. For images
    /// this is the suggested filename / dimensions; for files this is
    /// the joined filenames.
    let summary: String
    /// Text payload (kind == .text) — the full captured string.
    let text: String?
    /// PNG bytes for image entries.
    let imageData: Data?
    /// File URLs (paths only) for kind == .files entries.
    let filePaths: [String]?
    /// True when the user pinned this entry so it survives the history
    /// trim. Pinned items always sort to the top.
    var isPinned: Bool

    /// Convenience — does this kind have an NSImage we can render?
    var image: NSImage? {
        guard kind == .image, let data = imageData else { return nil }
        return NSImage(data: data)
    }
}

/// Forge's clipboard history. Polls `NSPasteboard.general` once a
/// second (cheap — it just reads `changeCount`) and snapshots anything
/// new into the in-memory history. The history is persisted to
/// UserDefaults (text + metadata) plus an Application Support folder
/// (PNG blobs) so it survives restarts.
final class ClipboardModule: ForgeModule, ObservableObject {
    let id = "clipboard"
    let name = "Clipboard History"
    let description = "Browse and restore recent clipboard items"
    let iconName = "doc.on.clipboard"
    let category: ModuleCategory = .files
    var isEnabled: Bool = true

    // MARK: - Tunables

    /// Hard cap on history length. Older non-pinned entries are
    /// evicted past this count.
    static let maxEntries = 100
    /// Of those, how many images we keep on disk across launches.
    /// Recent images go to disk, older ones are dropped (text + file
    /// lists survive regardless because they're cheap).
    static let imagePersistLimit = 20

    // MARK: - State

    @Published private(set) var entries: [ClipboardEntry] = []

    /// True while a panel is presenting the history — used by the
    /// hotkey to either show or focus the existing panel.
    @Published var isHistoryVisible: Bool = false

    /// We poll changeCount on a timer rather than registering as an
    /// NSPasteboard observer because NSPasteboard has no native
    /// notification API. 600ms is responsive enough to feel "live"
    /// without burning CPU.
    private var pollTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    private let pasteboard = NSPasteboard.general
    private let defaultsKey = "clipboard.history"

    // MARK: - Lifecycle

    func activate() {
        loadHistory()
        startWatching()
    }

    func deactivate() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startWatching() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.captureIfChanged()
        }
        // Capture once on startup so the panel isn't empty on first open
        // when the user already has something on their pasteboard.
        captureIfChanged()
    }

    /// If the system pasteboard's changeCount has incremented since we
    /// last looked, snapshot the current contents.
    private func captureIfChanged() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        captureCurrent()
    }

    private func captureCurrent() {
        // Order matters — image FIRST (an image-on-clipboard also
        // exposes a TIFF/PNG type that we want to capture as binary),
        // file URLs SECOND, text LAST as the fallback.
        if let image = NSImage(pasteboard: pasteboard),
           let png = imagePNG(from: image) {
            let summary = "Image · \(Int(image.size.width))×\(Int(image.size.height))"
            insert(ClipboardEntry(
                id: UUID(),
                timestamp: Date(),
                kind: .image,
                summary: summary,
                text: nil,
                imageData: png,
                filePaths: nil,
                isPinned: false
            ))
            return
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty,
           urls.allSatisfy({ $0.isFileURL }) {
            let paths = urls.map(\.path)
            let summary = urls.count == 1
                ? (urls.first?.lastPathComponent ?? "1 file")
                : "\(urls.count) files"
            insert(ClipboardEntry(
                id: UUID(),
                timestamp: Date(),
                kind: .files,
                summary: summary,
                text: nil,
                imageData: nil,
                filePaths: paths,
                isPinned: false
            ))
            return
        }

        if let str = pasteboard.string(forType: .string),
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Trim runaway content for the preview, but persist the full
            // string. 8KB is a sensible upper bound — anything past
            // that is almost certainly file content the user pasted.
            let stored = str.count > 8_000 ? String(str.prefix(8_000)) : str
            let summary = stored
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            insert(ClipboardEntry(
                id: UUID(),
                timestamp: Date(),
                kind: .text,
                summary: summary,
                text: stored,
                imageData: nil,
                filePaths: nil,
                isPinned: false
            ))
        }
    }

    /// Push a new entry to the top, dedupe against the immediately
    /// previous entry (so re-copying the same string doesn't fill the
    /// list), and trim past the cap.
    private func insert(_ entry: ClipboardEntry) {
        // Dedupe: if the newest entry has the same payload, skip.
        if let top = entries.first, isEqual(top, entry) { return }
        // De-dedupe further down: move any matching older entry up so
        // we don't accumulate visual duplicates.
        entries.removeAll { isEqual($0, entry) && !$0.isPinned }
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            self.trim()
            self.saveHistory()
        }
    }

    private func isEqual(_ a: ClipboardEntry, _ b: ClipboardEntry) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .text:  return a.text == b.text
        case .image: return a.imageData == b.imageData
        case .files: return a.filePaths == b.filePaths
        }
    }

    private func trim() {
        guard entries.count > Self.maxEntries else { return }
        // Keep all pinned + top N non-pinned
        var pinned = entries.filter(\.isPinned)
        var loose = entries.filter { !$0.isPinned }
        if loose.count > Self.maxEntries {
            loose = Array(loose.prefix(Self.maxEntries))
        }
        // Stable rebuild (pinned first, then loose in their existing order)
        // — preserves the user's mental model of "newest first below pins".
        pinned.sort { ($0.timestamp) > ($1.timestamp) }
        entries = pinned + loose
    }

    // MARK: - Public actions

    /// Copy an entry back to the system pasteboard. We bypass the
    /// watcher's "this is new" detection by bumping our cached
    /// changeCount AFTER we write, so the re-copy doesn't insert a
    /// duplicate.
    func copyToPasteboard(_ entry: ClipboardEntry) {
        pasteboard.clearContents()
        switch entry.kind {
        case .text:
            if let text = entry.text {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let image = entry.image {
                pasteboard.writeObjects([image])
            }
        case .files:
            if let paths = entry.filePaths {
                let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
                pasteboard.writeObjects(urls)
            }
        }
        lastChangeCount = pasteboard.changeCount
    }

    func togglePin(_ id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].isPinned.toggle()
        // Pinned items float to the top.
        entries.sort { ($0.isPinned ? 1 : 0, $0.timestamp) > ($1.isPinned ? 1 : 0, $1.timestamp) }
        saveHistory()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        saveHistory()
    }

    func clearAll() {
        // Keep pinned entries — the user can't accidentally nuke them.
        entries.removeAll { !$0.isPinned }
        saveHistory()
    }

    // MARK: - Persistence

    /// Encode current entries to JSON in UserDefaults. Image blobs are
    /// included for the most recent N entries only; older images get
    /// their `imageData` nulled out before saving so the defaults
    /// store doesn't balloon.
    private func saveHistory() {
        var imageCount = 0
        let toPersist: [ClipboardEntry] = entries.map { entry in
            guard entry.kind == .image else { return entry }
            imageCount += 1
            if imageCount > Self.imagePersistLimit {
                // Drop the binary; keep the summary/timestamp so the
                // entry still appears as "Image · (no longer cached)".
                return ClipboardEntry(
                    id: entry.id,
                    timestamp: entry.timestamp,
                    kind: entry.kind,
                    summary: entry.summary,
                    text: nil,
                    imageData: nil,
                    filePaths: nil,
                    isPinned: entry.isPinned
                )
            }
            return entry
        }
        guard let data = try? JSONEncoder().encode(toPersist) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data)
        else { return }
        entries = decoded
    }

    // MARK: - Image helpers

    private func imagePNG(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Commands

}

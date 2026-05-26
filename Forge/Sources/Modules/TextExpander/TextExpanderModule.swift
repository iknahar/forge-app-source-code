import AppKit
import Combine

// MARK: - Snippet groups

/// A folder in the snippet tree. Groups can nest (`parentId`) and
/// hold a flat list of snippets. Toggling a group's `enabled` flag
/// mutes every snippet it contains — handy for putting "work email"
/// snippets to sleep on weekends without losing them.
struct SnippetGroup: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Parent group's id, or `nil` if this is a top-level group.
    var parentId: UUID?
    /// Sort order within `parentId`. Lower numbers sort first.
    var order: Int
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        parentId: UUID? = nil,
        order: Int = 0,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.order = order
        self.enabled = enabled
    }
}

// MARK: - Per-snippet behavior knobs

/// When in the typed stream a snippet's trigger should fire.
///
/// Three modes:
///   • `afterAbbreviation`       — fire the instant the trigger appears
///                                 (no delimiter required). Use for
///                                 things like "->" → "→".
///   • `afterDelimiterKeep`      — fire when the user types a boundary
///                                 char (space / punctuation / etc.)
///                                 AFTER the trigger; leave that
///                                 boundary char in the result.
///   • `afterDelimiterDiscard`   — fire on boundary, but swallow the
///                                 boundary char. Snippet replaces
///                                 trigger AND the delimiter that
///                                 followed it. (Classic aText
///                                 behavior.)
enum ExpandTrigger: CaseIterable, Identifiable, Equatable {
    case afterAbbreviation
    case afterDelimiterKeep
    case afterDelimiterDiscard

    static var allCases: [ExpandTrigger] {
        [.afterAbbreviation, .afterDelimiterKeep, .afterDelimiterDiscard]
    }

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .afterAbbreviation:     return "afterAbbreviation"
        case .afterDelimiterKeep:    return "afterDelimiterKeep"
        case .afterDelimiterDiscard: return "afterDelimiterDiscard"
        }
    }

    var displayName: String {
        switch self {
        case .afterAbbreviation:     return "After typing abbreviation"
        case .afterDelimiterKeep:    return "After typing abbreviation and delimiter (keep delimiter)"
        case .afterDelimiterDiscard: return "After typing abbreviation and delimiter (discard delimiter)"
        }
    }
}

// Custom Codable maps old (v1) enum values to the new cases so
// existing snippet files keep working without a migration script.
extension ExpandTrigger: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "afterAbbreviation", "immediate":
            self = .afterAbbreviation
        case "afterDelimiterKeep":
            self = .afterDelimiterKeep
        case "afterDelimiterDiscard", "boundary", "spaceOrReturn", "tabOnly":
            // Old "boundary" / "spaceOrReturn" / "tabOnly" all fired
            // on a boundary char + swallowed it — closest match is
            // `.afterDelimiterDiscard`.
            self = .afterDelimiterDiscard
        default:
            self = .afterDelimiterDiscard
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Per-snippet app filter. The expander consults this before firing
/// — `onlyIn` allow-lists by bundle ID, `exceptIn` block-lists.
enum AppScope: Codable, Equatable {
    case allApps
    case onlyIn(Set<String>)
    case exceptIn(Set<String>)

    /// Returns true if a snippet with this scope is allowed to fire
    /// inside the given bundle ID.
    func allows(bundleId: String?) -> Bool {
        switch self {
        case .allApps:
            return true
        case .onlyIn(let set):
            guard let bundleId else { return false }
            return set.contains(bundleId)
        case .exceptIn(let set):
            guard let bundleId else { return true }
            return !set.contains(bundleId)
        }
    }
}

// MARK: - Snippet model

/// A single text-expansion entry.
///
/// Placeholders allowed inside `expansion`:
///   • `{date}`      — current date in user's locale, medium style
///   • `{time}`      — current time in short style
///   • `{datetime}`  — date + time combined
///   • `{clipboard}` — current clipboard text contents
///   • `{cursor}`    — caret lands here after the expansion is
///                     inserted (single placeholder per snippet —
///                     extra `{cursor}` markers are dropped).
struct TextSnippet: Codable, Identifiable, Equatable {
    let id: UUID
    var trigger: String
    var expansion: String
    var enabled: Bool
    /// Legacy display label — kept for backward compatibility. New
    /// code reads `name` instead.
    var label: String

    // v2 fields
    /// Human label shown in the snippet tree. Falls back to `trigger`
    /// when empty.
    var name: String
    /// The group this snippet lives in. `nil` only during construction
    /// — `loadSnippets()` reassigns to a real group on launch.
    var groupId: UUID?
    var expandOn: ExpandTrigger
    var caseSensitive: Bool
    var appScope: AppScope

    init(
        id: UUID = UUID(),
        trigger: String,
        expansion: String,
        enabled: Bool = true,
        label: String = "",
        name: String = "",
        groupId: UUID? = nil,
        expandOn: ExpandTrigger = .afterDelimiterDiscard,
        caseSensitive: Bool = false,
        appScope: AppScope = .allApps
    ) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.enabled = enabled
        self.label = label
        self.name = name
        self.groupId = groupId
        self.expandOn = expandOn
        self.caseSensitive = caseSensitive
        self.appScope = appScope
    }

    // Custom Codable so old (v1) JSON without the new fields still
    // decodes cleanly — missing keys take sensible defaults. We also
    // silently drop any `tags` field from older data: the feature was
    // discarded but the on-disk JSON may still carry it.
    enum CodingKeys: String, CodingKey {
        case id, trigger, expansion, enabled, label
        case name, groupId, expandOn, caseSensitive, appScope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self,   forKey: .id)
        trigger       = try c.decode(String.self, forKey: .trigger)
        expansion     = try c.decode(String.self, forKey: .expansion)
        enabled       = (try? c.decode(Bool.self,   forKey: .enabled)) ?? true
        label         = (try? c.decode(String.self, forKey: .label))   ?? ""
        name          = (try? c.decode(String.self, forKey: .name))    ?? ""
        groupId       = try? c.decode(UUID.self,           forKey: .groupId)
        expandOn      = (try? c.decode(ExpandTrigger.self, forKey: .expandOn))      ?? .afterDelimiterDiscard
        caseSensitive = (try? c.decode(Bool.self,          forKey: .caseSensitive)) ?? false
        appScope      = (try? c.decode(AppScope.self,      forKey: .appScope))      ?? .allApps
    }

    /// Friendly display name — falls back to legacy label then trigger
    /// then a placeholder, so the snippet tree never shows a blank row.
    var displayName: String {
        if !name.isEmpty    { return name }
        if !label.isEmpty   { return label }
        if !trigger.isEmpty { return trigger }
        return "Untitled"
    }
}

// MARK: - Module

/// Text Expander — system-wide snippet expansion. Sits on a low-level
/// CGEventTap so it sees every keystroke the user types, regardless
/// of which app is focused. When the typed sequence ends with a
/// trigger + boundary character (space, punctuation, return), we
/// rewind the trigger via synthesized backspaces and paste the
/// expansion via `CGEvent.keyboardSetUnicodeString`.
///
/// The expander deliberately re-uses the Accessibility permission
/// Forge already needs for Pin Window / FancyZones — no extra grant.
final class TextExpanderModule: ForgeModule, ObservableObject {
    let id = "textExpander"
    let name = "Text Expander"
    let description = "Type a trigger, get an expansion. Like aText."
    let iconName = "text.cursor"
    let category: ModuleCategory = .keyboard
    var isEnabled: Bool = true

    /// User-defined snippets. The Settings UI binds to this directly
    /// via `@Published`; mutations persist on next `save()`.
    @Published var snippets: [TextSnippet] = [] {
        didSet { schedulePersist() }
    }

    /// User-defined groups (folders) that snippets live inside.
    @Published var groups: [SnippetGroup] = [] {
        didSet { schedulePersist() }
    }

    /// Apps the expander refuses to fire inside. Bundle IDs like
    /// `com.apple.keychainaccess` — useful so triggers don't expand
    /// while typing passwords or 1Password Search Anything queries.
    @Published var blockedBundleIds: Set<String> = [] {
        didSet { schedulePersist() }
    }

    // MARK: Internals

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Rolling buffer of the most recently-typed characters. Capped
    /// at the longest active trigger length so we can scan it in
    /// O(buffer × snippets) on every keystroke without allocating.
    private var typedBuffer: String = ""
    private var maxBufferLength: Int = 32

    /// When the expander itself synthesizes keystrokes we set this
    /// to a positive count so the event tap can ignore those events
    /// (otherwise we'd recurse forever — the backspaces we send
    /// would be seen by us as "user typed").
    private var synthesizedEventsToIgnore: Int = 0

    /// Debounced persistence — every snippet edit shouldn't write to
    /// disk synchronously.
    private var persistTimer: Timer?

    /// Suppresses `schedulePersist()` while we're reading from disk
    /// during launch — otherwise migration writes back immediately
    /// for no good reason.
    private var isLoading = false

    // MARK: Lifecycle

    func activate() {
        loadSnippets()
        startEventTap()
    }

    func deactivate() {
        stopEventTap()
        persistNow()
    }

    // MARK: Event tap

    private func startEventTap() {
        // Don't double-install (e.g. if the module is toggled on
        // twice during testing).
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else {
            print("[TextExpander] AX permission missing — expander disabled")
            return
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let me = Unmanaged<TextExpanderModule>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return me.handleKeyDown(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            print("[TextExpander] CGEvent.tapCreate failed")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        typedBuffer = ""
    }

    /// CGEventTap callback. Walks the typed buffer, looks for a
    /// matching trigger + boundary char, fires the expansion if so.
    private func handleKeyDown(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS occasionally disables an event tap (e.g. the user's
        // system is under heavy load). Re-enable here so we don't
        // silently stop expanding.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Skip our own synthesized events — otherwise we'd recurse.
        if synthesizedEventsToIgnore > 0 {
            synthesizedEventsToIgnore -= 1
            return Unmanaged.passUnretained(event)
        }

        // Block: per-app global refusal (independent of per-snippet
        // appScope — this is the kill-switch for whole apps).
        let frontmostBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let bundle = frontmostBundle, blockedBundleIds.contains(bundle) {
            return Unmanaged.passUnretained(event)
        }

        // Inspect modifier flags. Modifier-only keystrokes (Cmd-Tab,
        // Cmd-S, …) don't contribute to the buffer.
        let flags = event.flags
        let isCmd = flags.contains(.maskCommand)
        let isCtrl = flags.contains(.maskControl)
        let isOpt = flags.contains(.maskAlternate)
        if isCmd || isCtrl || isOpt {
            // Reset the buffer when the user does something
            // shortcut-y — otherwise we'd expand mid-Cmd-A "btw …".
            typedBuffer = ""
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Backspace shortens the buffer — keep our model in sync.
        if keyCode == 51 {                      // kVK_Delete
            if !typedBuffer.isEmpty { typedBuffer.removeLast() }
            return Unmanaged.passUnretained(event)
        }
        // Arrow keys / Escape break the typing streak — clear.
        // (Return + Tab fall through so they can act as boundary
        // characters for delimiter-mode snippets.)
        if [123, 124, 125, 126, 53].contains(keyCode) {
            typedBuffer = ""
            return Unmanaged.passUnretained(event)
        }

        // Pull the Unicode chars produced by this keystroke (handles
        // dead keys, IME, etc.).
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return Unmanaged.passUnretained(event) }
        var ucBuf = Array<UniChar>(repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &ucBuf)
        let typed = String(utf16CodeUnits: ucBuf, count: length)

        typedBuffer.append(typed)
        if typedBuffer.count > maxBufferLength {
            typedBuffer.removeFirst(typedBuffer.count - maxBufferLength)
        }

        // ── First pass: afterAbbreviation snippets (no delimiter) ──
        // Fire the instant the buffer ends with the trigger, no
        // boundary char required. The last char of the trigger is
        // the keystroke our tap is currently processing — it hasn't
        // been delivered to the app yet, so we delete one fewer than
        // trigger.count and return nil to suppress this keystroke.
        if let immediate = findImmediateMatch(buffer: typedBuffer, frontmost: frontmostBundle) {
            fireExpansion(
                snippet: immediate,
                deleteCount: max(0, immediate.trigger.count - 1),
                appendBoundary: nil
            )
            return nil
        }

        // ── Second pass: delimiter-mode snippets ──
        // The user just typed a boundary char. The full trigger has
        // already been delivered to the app; this delimiter event is
        // what we're suppressing. So delete trigger.count, never the
        // delimiter (since the delimiter is killed by `return nil`).
        guard let lastChar = typed.last, isBoundaryChar(lastChar) else {
            return Unmanaged.passUnretained(event)
        }
        let bufferWithoutBoundary = String(typedBuffer.dropLast())

        if let match = findBoundaryMatch(
            bufferWithoutBoundary: bufferWithoutBoundary,
            boundary: lastChar,
            frontmost: frontmostBundle
        ) {
            switch match.expandOn {
            case .afterDelimiterKeep:
                // Type the delimiter ourselves at the end so it lands
                // AFTER the expansion. Always return nil — we want
                // tight control over event ordering.
                fireExpansion(
                    snippet: match,
                    deleteCount: match.trigger.count,
                    appendBoundary: String(lastChar)
                )
                return nil
            case .afterDelimiterDiscard:
                fireExpansion(
                    snippet: match,
                    deleteCount: match.trigger.count,
                    appendBoundary: nil
                )
                return nil
            case .afterAbbreviation:
                // Handled in the first pass.
                return Unmanaged.passUnretained(event)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// Returns true when this character ENDS a typed word — i.e.
    /// punctuation / whitespace / return.
    private func isBoundaryChar(_ ch: Character) -> Bool {
        if ch.isWhitespace || ch.isNewline { return true }
        if let scalar = ch.unicodeScalars.first,
           CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar) {
            return true
        }
        return false
    }

    /// O(snippets) scan for an afterAbbreviation snippet whose trigger
    /// terminates `buffer` and is preceded by a boundary (or start).
    private func findImmediateMatch(buffer: String, frontmost: String?) -> TextSnippet? {
        let enabledGroups = enabledGroupIds()
        for snippet in snippets {
            guard snippet.expandOn == .afterAbbreviation else { continue }
            guard snippet.enabled else { continue }
            guard !snippet.trigger.isEmpty else { continue }
            guard isFireable(snippet, enabledGroupIds: enabledGroups, frontmost: frontmost) else { continue }
            if triggerEndsBuffer(snippet: snippet, buffer: buffer) {
                return snippet
            }
        }
        return nil
    }

    /// O(snippets) scan for a delimiter-mode snippet whose trigger
    /// terminates `bufferWithoutBoundary`. The two delimiter modes
    /// (`keep` vs `discard`) differ only in how we handle the typed
    /// boundary char afterwards — both match the same way here.
    private func findBoundaryMatch(
        bufferWithoutBoundary: String,
        boundary: Character,
        frontmost: String?
    ) -> TextSnippet? {
        let enabledGroups = enabledGroupIds()
        for snippet in snippets {
            switch snippet.expandOn {
            case .afterDelimiterKeep, .afterDelimiterDiscard:
                break
            case .afterAbbreviation:
                continue
            }
            guard snippet.enabled else { continue }
            guard !snippet.trigger.isEmpty else { continue }
            guard isFireable(snippet, enabledGroupIds: enabledGroups, frontmost: frontmost) else { continue }
            if triggerEndsBuffer(snippet: snippet, buffer: bufferWithoutBoundary) {
                return snippet
            }
        }
        return nil
    }

    /// Match the snippet's trigger against the tail of `buffer`,
    /// respecting the snippet's `caseSensitive` flag. The character
    /// before the trigger must also be a word boundary (or the
    /// trigger must sit at the buffer start).
    private func triggerEndsBuffer(snippet: TextSnippet, buffer: String) -> Bool {
        let trigger = snippet.trigger
        let bufLen = buffer.count
        let trgLen = trigger.count
        guard bufLen >= trgLen else { return false }

        let startIdx = buffer.index(buffer.endIndex, offsetBy: -trgLen)
        let tail = buffer[startIdx..<buffer.endIndex]

        let matches: Bool
        if snippet.caseSensitive {
            matches = tail == trigger[...]
        } else {
            matches = tail.lowercased() == trigger.lowercased()
        }
        guard matches else { return false }

        if startIdx > buffer.startIndex {
            let prev = buffer[buffer.index(before: startIdx)]
            if !isBoundaryChar(prev) { return false }
        }
        return true
    }

    /// True if the snippet's group is enabled AND its appScope allows
    /// the frontmost app.
    private func isFireable(
        _ snippet: TextSnippet,
        enabledGroupIds: Set<UUID>,
        frontmost: String?
    ) -> Bool {
        if let gid = snippet.groupId, !enabledGroupIds.contains(gid) {
            return false
        }
        return snippet.appScope.allows(bundleId: frontmost)
    }

    /// Set of group IDs that are themselves enabled (transitively —
    /// a child group is considered disabled if any ancestor is off).
    private func enabledGroupIds() -> Set<UUID> {
        let byId = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var result: Set<UUID> = []
        for g in groups {
            var cursor: SnippetGroup? = g
            var ok = true
            while let cur = cursor {
                if !cur.enabled { ok = false; break }
                if let parent = cur.parentId {
                    cursor = byId[parent]
                } else {
                    cursor = nil
                }
            }
            if ok { result.insert(g.id) }
        }
        return result
    }

    // MARK: Expansion synthesis

    /// Synthesize `deleteCount` backspaces (to remove whatever the
    /// caller knows is currently in the focused text field that
    /// shouldn't be), paste the resolved expansion, then optionally
    /// type a trailing `appendBoundary` (for the "keep delimiter"
    /// flow). `{cursor}` inside the expansion lands the caret at
    /// that spot afterwards.
    private func fireExpansion(snippet: TextSnippet, deleteCount: Int, appendBoundary: String?) {
        let resolved = resolvePlaceholders(in: snippet.expansion)
        // Split on {cursor} (max 1 use). Anything past the marker is
        // typed second, then we move the caret left by that many
        // characters.
        let parts = resolved.components(separatedBy: "{cursor}")
        let beforeCursor = parts.first ?? resolved
        let afterCursor = parts.dropFirst().joined()

        for _ in 0..<deleteCount {
            sendBackspace()
        }

        // Reset our buffer — we just rewrote the tail.
        typedBuffer = ""

        // Type the expansion text. Order:
        //   1. text before {cursor}
        //   2. text after {cursor}
        //   3. trailing delimiter (keep-mode only)
        //   4. arrow-left back to where {cursor} was, if any
        sendUnicodeString(beforeCursor)
        if !afterCursor.isEmpty {
            sendUnicodeString(afterCursor)
        }
        if let boundary = appendBoundary, !boundary.isEmpty {
            sendUnicodeString(boundary)
        }
        if !afterCursor.isEmpty {
            let leftCount = afterCursor.unicodeScalars.count
            for _ in 0..<leftCount {
                sendArrowLeft()
            }
        }
    }

    /// Replace `{date}`, `{time}`, `{datetime}`, `{clipboard}` with
    /// runtime values. `{cursor}` is left in place — the caller
    /// handles it during paste.
    private func resolvePlaceholders(in template: String) -> String {
        var result = template
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        result = result.replacingOccurrences(of: "{date}", with: df.string(from: Date()))
        df.dateStyle = .none
        df.timeStyle = .short
        result = result.replacingOccurrences(of: "{time}", with: df.string(from: Date()))
        df.dateStyle = .medium
        df.timeStyle = .short
        result = result.replacingOccurrences(of: "{datetime}", with: df.string(from: Date()))
        if result.contains("{clipboard}") {
            let cb = NSPasteboard.general.string(forType: .string) ?? ""
            result = result.replacingOccurrences(of: "{clipboard}", with: cb)
        }
        return result
    }

    private func sendBackspace() {
        sendKeyCode(51)
    }

    private func sendArrowLeft() {
        sendKeyCode(123)
    }

    private func sendKeyCode(_ keyCode: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return }
        synthesizedEventsToIgnore += 2
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Post a Unicode string as a single keystroke. This is the only
    /// reliable way to "type" arbitrary text including punctuation,
    /// emoji, and accented characters without doing layout-aware
    /// keycode translation.
    private func sendUnicodeString(_ s: String) {
        guard !s.isEmpty else { return }
        // Chunk to avoid the (mostly mythical) Unicode string length
        // limit on CGEventKeyboardSetUnicodeString.
        let chunk = 20
        let units = Array(s.utf16)
        var i = 0
        while i < units.count {
            let end = min(i + chunk, units.count)
            let slice = Array(units[i..<end])
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                event.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: slice)
                synthesizedEventsToIgnore += 1
                event.post(tap: .cghidEventTap)
            }
            i = end
        }
    }

    // MARK: Persistence

    private var snippetsURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("text_expander.json")
    }

    private struct PersistedState: Codable {
        let snippets: [TextSnippet]
        let groups: [SnippetGroup]?
        let blockedBundleIds: [String]
        /// One-shot flag: true after we've seeded the Examples folder
        /// at least once. We never re-seed after this — so deleting
        /// the Examples folder is permanent (which is the right
        /// instinct: the user owns their snippets).
        let examplesSeeded: Bool?
    }

    /// Tracks whether we've ever seeded the Examples folder for this
    /// install. Mirrors `PersistedState.examplesSeeded` so the next
    /// `persistNow()` writes it.
    private var examplesSeeded: Bool = false

    private func loadSnippets() {
        isLoading = true
        defer { isLoading = false }

        let onDisk = FileManager.default.fileExists(atPath: snippetsURL.path)
        if onDisk,
           let data = try? Data(contentsOf: snippetsURL),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            snippets = state.snippets
            groups = state.groups ?? []
            blockedBundleIds = Set(state.blockedBundleIds)
            examplesSeeded = state.examplesSeeded ?? false
        }

        // Seed Examples on first launch — and ALSO retroactively for
        // existing installs that don't yet carry the seeded flag.
        // After this runs once, the flag is set and we never touch
        // Examples again.
        if !examplesSeeded {
            seedExamples()
            examplesSeeded = true
        }

        ensureDefaultGroup()
        recomputeBufferCap()
    }

    /// One-time seed: creates an "Examples" group and populates it
    /// with snippets that demonstrate placeholders and the three
    /// expand-on modes. Idempotent via `examplesSeeded` — runs once
    /// per install, then never again, even if the user deletes the
    /// folder. Existing user groups and snippets are preserved.
    private func seedExamples() {
        // Track whether this is a truly fresh install so we can also
        // drop in a "My Snippets" sibling for the user's own stuff.
        let wasEmpty = groups.isEmpty
        // Bump existing root-level groups one position to make room
        // for the Examples folder at the top.
        for i in groups.indices where groups[i].parentId == nil {
            groups[i].order += 1
        }
        let examples = SnippetGroup(name: "Examples", order: 0)
        groups.insert(examples, at: 0)
        if wasEmpty {
            groups.append(SnippetGroup(name: "My Snippets", parentId: nil, order: 1))
        }

        let seeded: [TextSnippet] = [
            TextSnippet(
                trigger: "ddate",
                expansion: "{date}",
                name: "Today's date",
                groupId: examples.id,
                expandOn: .afterDelimiterDiscard
            ),
            TextSnippet(
                trigger: "ttime",
                expansion: "{time}",
                name: "Current time",
                groupId: examples.id,
                expandOn: .afterDelimiterDiscard
            ),
            TextSnippet(
                trigger: "dnow",
                expansion: "{datetime}",
                name: "Date + time",
                groupId: examples.id,
                expandOn: .afterDelimiterDiscard
            ),
            TextSnippet(
                trigger: ";clip",
                expansion: "{clipboard}",
                name: "Paste clipboard",
                groupId: examples.id,
                expandOn: .afterDelimiterDiscard
            ),
            TextSnippet(
                trigger: ";todo",
                expansion: "- [ ] {cursor}",
                name: "Markdown todo",
                groupId: examples.id,
                expandOn: .afterDelimiterDiscard
            ),
            TextSnippet(
                trigger: "btw",
                expansion: "by the way",
                name: "By the way",
                groupId: examples.id,
                expandOn: .afterDelimiterKeep
            ),
            TextSnippet(
                trigger: "omw",
                expansion: "On my way!",
                name: "On my way",
                groupId: examples.id,
                expandOn: .afterDelimiterKeep
            ),
            TextSnippet(
                trigger: "tyvm",
                expansion: "Thank you very much",
                name: "Thank you",
                groupId: examples.id,
                expandOn: .afterDelimiterKeep
            ),
            TextSnippet(
                trigger: "->",
                expansion: "→",
                name: "Right arrow",
                groupId: examples.id,
                expandOn: .afterAbbreviation
            ),
            TextSnippet(
                trigger: "<-",
                expansion: "←",
                name: "Left arrow",
                groupId: examples.id,
                expandOn: .afterAbbreviation
            ),
        ]
        snippets.append(contentsOf: seeded)
    }

    /// Guarantees:
    ///   1. At least one root group exists ("My Snippets" on first
    ///      run).
    ///   2. Every snippet has a `groupId` pointing at an existing
    ///      group. Orphans are reparented to the first root group so
    ///      they don't vanish from the tree.
    private func ensureDefaultGroup() {
        if groups.isEmpty {
            groups = [SnippetGroup(name: "My Snippets", order: 0)]
        }
        let knownIds = Set(groups.map(\.id))
        let fallback = groups.first(where: { $0.parentId == nil })?.id ?? groups[0].id
        for i in snippets.indices {
            if let gid = snippets[i].groupId, knownIds.contains(gid) { continue }
            snippets[i].groupId = fallback
        }
    }

    private func schedulePersist() {
        guard !isLoading else { return }
        recomputeBufferCap()
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.persistNow()
        }
    }

    private func persistNow() {
        let state = PersistedState(
            snippets: snippets,
            groups: groups,
            blockedBundleIds: Array(blockedBundleIds),
            examplesSeeded: examplesSeeded
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: snippetsURL, options: .atomic)
    }

    private func recomputeBufferCap() {
        let longest = snippets.map { $0.trigger.count }.max() ?? 0
        // +8 gives breathing room for boundary chars + the "char
        // before trigger" check at expand time.
        maxBufferLength = max(32, longest + 8)
    }

    // MARK: Group CRUD (used by Settings UI)

    /// Insert a new group as a child of `parentId` (nil = root) and
    /// return it so the UI can immediately select / focus its name
    /// field.
    @discardableResult
    func addGroup(name: String = "New Group", parentId: UUID? = nil) -> SnippetGroup {
        let siblings = groups.filter { $0.parentId == parentId }
        let nextOrder = (siblings.map(\.order).max() ?? -1) + 1
        let group = SnippetGroup(name: name, parentId: parentId, order: nextOrder)
        groups.append(group)
        return group
    }

    /// Delete a group + all its descendants + all the snippets they
    /// contain. The UI confirms first — this is destructive.
    func deleteGroup(_ id: UUID) {
        // Walk the subtree to collect every descendant.
        var toDelete: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for g in groups where !toDelete.contains(g.id) {
                if let p = g.parentId, toDelete.contains(p) {
                    toDelete.insert(g.id)
                    changed = true
                }
            }
        }
        groups.removeAll { toDelete.contains($0.id) }
        snippets.removeAll { s in
            guard let gid = s.groupId else { return false }
            return toDelete.contains(gid)
        }
        // Make sure we didn't delete the last group — UI assumes
        // there's always at least one.
        ensureDefaultGroup()
    }

    /// Rename a group in place.
    func renameGroup(_ id: UUID, to newName: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = newName
    }

    /// Insert a new group as a sibling immediately AFTER the group
    /// with id `referenceId`. When the reference is nil (or not
    /// found), the new group is appended at the root.
    ///
    /// Used by the toolbar's "New Group" button: if the user has a
    /// group (or a snippet inside one) selected, the new folder
    /// drops in right next to it instead of way at the bottom.
    @discardableResult
    func addGroup(after referenceId: UUID?, name: String = "New Group") -> SnippetGroup {
        if let refId = referenceId,
           let ref = groups.first(where: { $0.id == refId }) {
            let parent = ref.parentId
            // Push all later siblings down by one to make room.
            for i in groups.indices
            where groups[i].parentId == parent && groups[i].order > ref.order {
                groups[i].order += 1
            }
            let newG = SnippetGroup(
                name: name,
                parentId: parent,
                order: ref.order + 1
            )
            groups.append(newG)
            return newG
        }
        // Fallback: append at root.
        let nextOrder = (groups.filter { $0.parentId == nil }.map(\.order).max() ?? -1) + 1
        let newG = SnippetGroup(name: name, parentId: nil, order: nextOrder)
        groups.append(newG)
        return newG
    }

    /// Reparent/reorder `groupId` so it becomes a sibling immediately
    /// AFTER the group with id `targetId`. Used by drag-to-reorder
    /// in the tree.
    ///
    /// Refuses to make a group its own descendant — silently no-ops
    /// in that case to avoid corrupting the tree.
    func moveGroup(_ groupId: UUID, toBeAfter targetId: UUID) {
        guard groupId != targetId else { return }
        guard let groupIdx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        guard let targetIdx = groups.firstIndex(where: { $0.id == targetId }) else { return }
        if isDescendant(targetId, of: groupId) { return }

        let newParent = groups[targetIdx].parentId
        groups[groupIdx].parentId = newParent

        // Rebuild ordering for the destination parent: walk siblings
        // in current order (excluding the dragged group), then drop
        // the dragged group in right after the target. Reassign
        // contiguous integer orders so the model stays clean.
        let sortedSiblings = groups
            .filter { $0.parentId == newParent && $0.id != groupId }
            .sorted { $0.order < $1.order }
        var newOrderIds: [UUID] = []
        for sib in sortedSiblings {
            newOrderIds.append(sib.id)
            if sib.id == targetId {
                newOrderIds.append(groupId)
            }
        }
        for (i, id) in newOrderIds.enumerated() {
            if let idx = groups.firstIndex(where: { $0.id == id }) {
                groups[idx].order = i
            }
        }
    }

    /// True if `candidate` is `ancestorId` itself, or any descendant
    /// of it. Used to block illegal drags (a group can't be nested
    /// inside its own subtree).
    private func isDescendant(_ candidate: UUID, of ancestorId: UUID) -> Bool {
        var current: UUID? = candidate
        while let id = current {
            if id == ancestorId { return true }
            current = groups.first(where: { $0.id == id })?.parentId
        }
        return false
    }

    // MARK: Snippet CRUD (used by Settings UI)

    /// Append a fresh blank snippet into `groupId` and return it so
    /// the UI can select + focus the trigger field immediately.
    @discardableResult
    func addSnippet(in groupId: UUID? = nil) -> TextSnippet {
        let targetGroup = groupId ?? groups.first?.id
        var snippet = TextSnippet(trigger: "", expansion: "", groupId: targetGroup)
        snippet.name = ""
        snippets.append(snippet)
        return snippet
    }

    func deleteSnippet(_ id: UUID) {
        snippets.removeAll { $0.id == id }
    }

    /// Move snippet to a different group. Idempotent — no-op if the
    /// snippet already lives there.
    func moveSnippet(_ id: UUID, to groupId: UUID) {
        guard let idx = snippets.firstIndex(where: { $0.id == id }) else { return }
        guard snippets[idx].groupId != groupId else { return }
        snippets[idx].groupId = groupId
    }

    // MARK: Query helpers (used by Settings UI)

    /// Sub-groups of `parentId`, sorted by `order`.
    func subgroups(of parentId: UUID?) -> [SnippetGroup] {
        groups.filter { $0.parentId == parentId }.sorted { $0.order < $1.order }
    }

    /// Snippets that live directly inside `groupId`.
    func snippets(in groupId: UUID) -> [TextSnippet] {
        snippets.filter { $0.groupId == groupId }
    }

    /// Case-insensitive full-text search across name + trigger +
    /// expansion. Kept around as a model-level utility even though
    /// there's no dedicated search pane right now.
    func search(_ query: String) -> [TextSnippet] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return snippets.filter { s in
            if s.displayName.lowercased().contains(q) { return true }
            if s.trigger.lowercased().contains(q) { return true }
            if s.expansion.lowercased().contains(q) { return true }
            return false
        }
    }
}

import SwiftUI
import AppKit

/// Floating list of recent clipboard entries. Opens as a centered panel
/// when the user triggers the global shortcut (⌃⌥V by default). Click
/// a row to copy it back to the pasteboard and dismiss; pinned items
/// float to the top and survive "Clear All".
struct ClipboardHistoryView: View {
    @ObservedObject var module: ClipboardModule
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var searchFocused: Bool

    private var filtered: [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return module.entries }
        return module.entries.filter {
            $0.summary.lowercased().contains(trimmed)
                || ($0.text?.lowercased().contains(trimmed) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, entry in
                            row(entry, index: idx)
                            if idx != filtered.count - 1 {
                                Divider().opacity(0.10).padding(.leading, 56)
                            }
                        }
                    }
                }
            }
            footer
        }
        .frame(width: 480, height: 540)
        .background(ForgeTheme.Colors.surfaceCard)
        // Hidden buttons that register window-level keyboard
        // shortcuts. macOS hands these key combos to the buttons
        // before the focused TextField sees them, so arrow keys
        // navigate, Enter pastes, etc — all while the search
        // field still receives normal typing.
        .background(keyboardShortcuts)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        }
        // Whenever the query changes, snap the highlighted row back to
        // the top of the filtered list so Enter always pastes the
        // most-relevant match without an extra arrow-down.
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
    }

    // MARK: - Keyboard shortcuts (hidden buttons)

    /// Hidden ZStack of buttons whose only job is to carry
    /// `.keyboardShortcut` modifiers. macOS routes these key combos
    /// to the buttons at the window level, which works even while
    /// the search TextField has focus (a plain `.onKeyPress` on the
    /// outer view wouldn't, because the focused TextField would
    /// swallow the event first).
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Paste selected") {
                guard filtered.indices.contains(selectedIndex) else { return }
                commit(filtered[selectedIndex])
            }
            .keyboardShortcut(.return, modifiers: [])

            Button("Move up") {
                let n = filtered.count
                guard n > 0 else { return }
                selectedIndex = max(selectedIndex - 1, 0)
            }
            .keyboardShortcut(.upArrow, modifiers: [])

            Button("Move down") {
                let n = filtered.count
                guard n > 0 else { return }
                selectedIndex = min(selectedIndex + 1, n - 1)
            }
            .keyboardShortcut(.downArrow, modifiers: [])

            // ⌘⌫ removes the selected entry. We deliberately use the
            // Cmd modifier (not a bare ⌫) so that backspace inside
            // the search field still deletes characters as expected.
            Button("Remove selected") {
                guard filtered.indices.contains(selectedIndex) else { return }
                let entry = filtered[selectedIndex]
                module.remove(entry.id)
                // After removal, keep the highlight visually stable:
                // clamp to the last valid row.
                selectedIndex = min(selectedIndex, max(filtered.count - 2, 0))
            }
            .keyboardShortcut(.delete, modifiers: .command)

            // ⌘P toggles the pin on the selected entry.
            Button("Toggle pin on selected") {
                guard filtered.indices.contains(selectedIndex) else { return }
                module.togglePin(filtered[selectedIndex].id)
            }
            .keyboardShortcut("p", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Header (title + search)

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.accent)
                Text("Clipboard History")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                Spacer()
                Text("\(module.entries.count) item\(module.entries.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(ForgeTheme.Colors.surfaceHover))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                TextField("Search clipboard…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ForgeTheme.Colors.surfaceHover)
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Row

    private func row(_ entry: ClipboardEntry, index: Int) -> some View {
        let isSelected = index == selectedIndex
        return HStack(alignment: .top, spacing: 12) {
            // Preview thumbnail
            iconBlock(for: entry)
                .frame(width: 40, height: 40)

            // Summary + meta
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(ForgeTheme.Colors.accent)
                    }
                    Text(displaySummary(for: entry))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text(kindLabel(for: entry))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(kindColor(for: entry))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(
                            Capsule().fill(kindColor(for: entry).opacity(0.12))
                        )
                    Text(timeAgo(entry.timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                }
            }

            Spacer(minLength: 4)

            // Hover actions
            HStack(spacing: 6) {
                Button {
                    module.togglePin(entry.id)
                } label: {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundColor(entry.isPinned
                                         ? ForgeTheme.Colors.accent
                                         : ForgeTheme.Colors.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(ForgeTheme.Colors.surfaceHover.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help(entry.isPinned ? "Unpin" : "Pin")
                Button {
                    module.remove(entry.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(ForgeTheme.Colors.surfaceHover.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            isSelected
                ? ForgeTheme.Colors.accent.opacity(0.08)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { selectedIndex = index }
        }
        .onTapGesture {
            commit(entry)
        }
    }

    @ViewBuilder
    private func iconBlock(for entry: ClipboardEntry) -> some View {
        switch entry.kind {
        case .text:
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ForgeTheme.Colors.surfaceHover)
                Image(systemName: "text.alignleft")
                    .font(.system(size: 14))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
            }
        case .image:
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ForgeTheme.Colors.surfaceHover)
                if let image = entry.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                }
            }
        case .files:
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ForgeTheme.Colors.surfaceHover)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28))
                .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.6))
            Text(query.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.textPrimary)
            Text(query.isEmpty
                 ? "Forge starts capturing the moment you copy anything."
                 : "Try a different search term.")
                .font(.system(size: 11))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("↑↓ Navigate · ↩ Paste · ⌘P Pin · ⌘⌫ Remove")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
            Spacer()
            Button {
                module.clearAll()
            } label: {
                Text("Clear All")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .disabled(module.entries.filter { !$0.isPinned }.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(ForgeTheme.Colors.surfaceSubtle)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(ForgeTheme.Colors.borderDefault),
                    alignment: .top
                )
        )
    }

    // MARK: - Helpers

    /// User picked an entry from the history list. We:
    ///   1. Push the entry to the system pasteboard.
    ///   2. Capture which app was frontmost before we showed.
    ///   3. Dismiss the panel.
    ///   4. Explicitly `NSApp.deactivate()` so Forge gives up focus —
    ///      on macOS 14+ this is the most reliable way to hand control
    ///      back to the previous app. `NSRunningApplication.activate`
    ///      is async and the macOS 14+ activation rules don't always
    ///      honor it.
    ///   5. After a beat, run an AppleScript that sends ⌘V to the
    ///      now-frontmost app via System Events.
    ///
    /// Every step is logged to `~/Library/Logs/Forge/clipboard-paste.log`
    /// so we can `tail -f` the file and see what's happening when the
    /// paste isn't landing.
    private func commit(_ entry: ClipboardEntry) {
        module.copyToPasteboard(entry)
        let targetBundle = ClipboardHistoryPanel.takePreviousAppBundleID()
        Self.log("─────── commit() ───────")
        Self.log("pasteboard='\(entry.summary.prefix(40))…'  target=\(targetBundle ?? "<nil>")")
        onDismiss()

        // BELT: NSRunningApplication.activate with the deprecated
        // .activateIgnoringOtherApps option set — still works on
        // macOS 14+ and is more forceful than the empty-options
        // call we tried earlier.
        if let id = targetBundle,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate(options: [.activateIgnoringOtherApps])
            Self.log("NSRunningApplication.activate(\(id)) called  → isActive=\(app.isActive)")
        } else {
            Self.log("⚠️ no NSRunningApplication found for bundleID \(targetBundle ?? "<nil>")")
        }

        // SUSPENDERS: Forge deactivates itself so macOS hands focus
        // to whatever app it just activated above.
        NSApp.deactivate()
        Self.log("NSApp.deactivate() called  → NSApp.isActive=\(NSApp.isActive)")

        // Longer delay (150ms) — macOS 14+ activation transitions can
        // take a full runloop tick or two. The AppleScript also has
        // its own internal delay as a third layer of safety.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Self.pasteIntoApp(bundleID: targetBundle)
        }
    }

    /// Run an AppleScript that (optionally) activates `bundleID` and
    /// keystrokes ⌘V into it via System Events. Writes a log line on
    /// every attempt so failure modes are visible without attaching
    /// a debugger.
    private static func pasteIntoApp(bundleID: String?) {
        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<unknown>"
        log("pasteIntoApp(): frontmost = \(frontBefore)  intendedTarget = \(bundleID ?? "<nil>")")
        log("AXIsProcessTrusted = \(AXIsProcessTrusted())")

        // Post the FULL physical ⌘V sequence: Cmd↓, V↓, V↑, Cmd↑.
        // Setting `.flags = .maskCommand` on just the V keyDown is
        // enough for most native AppKit apps, but Chromium-based
        // apps (Claude Desktop, Chrome, VS Code, Notion, Slack, etc.)
        // watch the actual modifier-key stream — they want to see a
        // real flagsChanged for Cmd press/release surrounding the V
        // keystroke, the way a hardware keypress flows. Without the
        // explicit Cmd↓/Cmd↑ frames, those apps see "a V key with a
        // Cmd flag on it" and silently drop it.
        //
        // Source `nil` keeps the synthesized events free of inherited
        // physical-keyboard state — see TextExpanderModule.sendKeyCode
        // which uses the same pattern.
        let cmdKey: CGKeyCode = 0x37   // left Command
        let vKey:   CGKeyCode = 0x09   // V on a US layout

        if let e = CGEvent(keyboardEventSource: nil, virtualKey: cmdKey, keyDown: true) {
            e.flags = .maskCommand
            e.post(tap: .cghidEventTap)
        }
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: true) {
            e.flags = .maskCommand
            e.post(tap: .cghidEventTap)
        }
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: false) {
            e.flags = .maskCommand
            e.post(tap: .cghidEventTap)
        }
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: cmdKey, keyDown: false) {
            e.flags = []
            e.post(tap: .cghidEventTap)
        }

        log("✓ Full ⌘V keystroke sequence posted (Cmd↓ V↓ V↑ Cmd↑)")

        let frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<unknown>"
        log("frontmost AFTER paste = \(frontAfter)")
    }

    /// Append a timestamped line to `~/Library/Logs/Forge/clipboard-paste.log`.
    /// Cheap, fire-and-forget; failures are silently ignored so logging
    /// can't break the paste flow itself.
    fileprivate static func log(_ message: String) {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Forge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("clipboard-paste.log")
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: file.path) {
                if let handle = try? FileHandle(forWritingTo: file) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: file)
            }
        }
        print("[Forge Clipboard] \(message)")
    }

    private func displaySummary(for entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .text:
            return entry.text?.replacingOccurrences(of: "\n", with: " ") ?? entry.summary
        case .image, .files:
            return entry.summary
        }
    }

    private func kindLabel(for entry: ClipboardEntry) -> String {
        switch entry.kind {
        case .text:  return "TEXT"
        case .image: return "IMAGE"
        case .files: return "FILES"
        }
    }

    private func kindColor(for entry: ClipboardEntry) -> Color {
        switch entry.kind {
        case .text:  return .blue
        case .image: return .purple
        case .files: return .orange
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60       { return "just now" }
        if s < 3600     { return "\(Int(s/60))m ago" }
        if s < 86400    { return "\(Int(s/3600))h ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

// MARK: - Panel host

/// Borderless NSPanel hosting the SwiftUI history view. Lives at the
/// center of the active screen; clicking outside or pressing Esc closes.
final class ClipboardHistoryPanel: NSPanel {
    private static var current: ClipboardHistoryPanel?
    /// The app that was frontmost when the panel was opened. Captured
    /// so we can hand focus back to it on dismiss — without this, the
    /// synthetic ⌘V from `ClipboardHistoryView.commit(_:)` would fire
    /// while Forge was still the active app, and the paste would land
    /// nowhere useful.
    private static var previousApp: NSRunningApplication?

    /// Re-activate whichever app was frontmost before the panel
    /// opened, so a follow-up synthesized keystroke (the auto-paste
    /// after an item is clicked) reaches THAT app's text field, not
    /// Forge.
    static func restorePreviousAppFocus() {
        guard let prev = previousApp else { return }
        prev.activate(options: [])
        previousApp = nil
    }

    /// Hand the previous app's bundle identifier to the caller and
    /// clear the slot. Used by the auto-paste flow so the AppleScript
    /// can activate the right app even if `NSRunningApplication.activate`
    /// doesn't transfer focus in time (a known macOS 14+ quirk —
    /// `activate(options:)` returns immediately while the actual
    /// focus transition happens asynchronously, and our keystroke
    /// would fire before that transition completed).
    static func takePreviousAppBundleID() -> String? {
        let id = previousApp?.bundleIdentifier
        previousApp = nil
        return id
    }

    /// Toggle the floating history panel. If already open, brings it
    /// to front; if closed, builds + shows it.
    static func toggle(module: ClipboardModule) {
        if let existing = current, existing.isVisible {
            existing.close()
            return
        }
        // Remember the user's current app BEFORE we steal focus.
        previousApp = NSWorkspace.shared.frontmostApplication
        let host = NSHostingController(rootView: ClipboardHistoryView(
            module: module,
            onDismiss: { Self.current?.close() }
        ))
        let panel = ClipboardHistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
            styleMask: [.titled, .borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Center on the active screen
        if let screen = NSScreen.main {
            let x = screen.frame.midX - 240
            let y = screen.frame.midY - 270
            panel.setFrame(NSRect(x: x, y: y, width: 480, height: 540), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        current = panel
    }
}

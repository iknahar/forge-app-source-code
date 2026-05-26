import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag payloads

/// Identifies one or more snippets being dragged from the tree onto a
/// group. Carries an array so a multi-selected drag (shift-click +
/// drag any of the selected rows) moves every selected snippet to
/// the drop target in one gesture.
struct SnippetDragID: Codable, Transferable {
    let ids: [UUID]

    init(ids: [UUID]) { self.ids = ids }
    init(id: UUID)    { self.ids = [id] }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .text)
    }
}

/// Identifies a group folder being dragged. Distinct from
/// `SnippetDragID` so a drop target can tell whether it's receiving
/// a snippet (nest as child) or another group (reorder as sibling
/// immediately after this row).
struct GroupDragID: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        // Distinct UTType so SwiftUI dispatches to the right
        // dropDestination handler based on payload kind.
        CodableRepresentation(contentType: .utf8PlainText)
    }
}

// MARK: - Wheel-passthrough multi-line editor

/// `NSTextView` wrapper whose enclosing `NSScrollView` forwards
/// mouse-wheel events to its `nextResponder`. This means hovering
/// the expansion field while spinning the scroll wheel scrolls the
/// PARENT page rather than the tiny inner editor. You can still
/// scroll inside via arrow keys or the trackpad scrollbar.
struct WheelPassthroughTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// SwiftUI font size for the document.
    var fontSize: CGFloat = 12

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = WheelPassthroughScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.string = text

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            let safeEnd = min(sel.location, (text as NSString).length)
            tv.setSelectedRange(NSRange(location: safeEnd, length: 0))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WheelPassthroughTextEditor
        init(_ parent: WheelPassthroughTextEditor) { self.parent = parent }
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

private final class WheelPassthroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - Forge-styled primary / secondary buttons

/// Primary CTA pill in the Forge style — capsule shape, filled with
/// the accent red, white text. Matches the "Connect Google account"
/// button on the Calendar settings page so the look-and-feel is
/// consistent across the app. Hovering darkens the fill by ~15% so
/// the button feels responsive.
private struct ForgePrimaryButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Capsule().fill(
                    isHovering
                        ? ForgeTheme.Colors.accent.opacity(0.85)
                        : ForgeTheme.Colors.accent
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Secondary CTA pill — same dimensions and typography as the primary
/// button, but rendered as an outlined capsule (transparent fill,
/// accent border, accent text). Used for adjacent actions that share
/// equal importance with the primary visually but read as the
/// "ghost" partner — e.g. "New Group" next to "New Snippet".
/// Hovering fills the capsule with a translucent accent so it
/// telegraphs interactivity.
private struct ForgeSecondaryButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(ForgeTheme.Colors.accent)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Capsule().fill(
                    isHovering
                        ? ForgeTheme.Colors.accent.opacity(0.10)
                        : Color.clear
                )
            )
            .overlay(
                Capsule().strokeBorder(ForgeTheme.Colors.accent, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - Thin red scrollbar

/// `NSScrollView` wrapper whose vertical scroller is a custom
/// `ForgeRedScroller` — a 3.5pt slim red knob centered in the
/// scroller's natural ~15pt hit area. So the visual bar is delicate
/// (doesn't compete with content) but the user can still grab and
/// drag it easily, because the click target is the full underlying
/// scroller width — not just the visible knob.
///
/// Use this in place of SwiftUI's `ScrollView` anywhere we want the
/// Forge-themed scroll treatment.
struct ThinRedScrollView<Content: View>: NSViewRepresentable {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = false
        // Overlay style = floating bar on top of content (instead of
        // reserving its own column), and uses our custom drawing.
        scrollView.scrollerStyle = .overlay

        let scroller = ForgeRedScroller(
            frame: NSRect(x: 0, y: 0, width: 14, height: 100)
        )
        scroller.scrollerStyle = .overlay
        scrollView.verticalScroller = scroller

        // Host the SwiftUI content inside an NSHostingView. The
        // host's intrinsic content size drives the scrollable height
        // — Auto Layout reads it and the scrollView responds.
        let hosting = NSHostingView(rootView: AnyView(content()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: clip.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            hosting.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let hosting = nsView.documentView as? NSHostingView<AnyView> else { return }
        hosting.rootView = AnyView(content())
        // SwiftUI sometimes doesn't recompute intrinsic size on root
        // swaps — force it so dynamic content (selection switching,
        // snippet adds) re-measures.
        hosting.invalidateIntrinsicContentSize()
    }
}

/// Custom `NSScroller` that paints a slim red knob centered in the
/// scroller's wider hit area. The full hit area accepts clicks and
/// drags as usual; only the visible knob is drawn slim, so the bar
/// looks delicate without sacrificing grabability.
final class ForgeRedScroller: NSScroller {
    /// Required so AppKit allows this subclass to participate in the
    /// overlay-style scroller subsystem.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        let knobRect = self.rect(for: .knob)
        // 3.5pt visible width — slim, centered in the ~14pt hit
        // area of the scroller's frame. So the user sees a delicate
        // red line, but their cursor lands on the wider hit zone
        // and drags as expected.
        let visualWidth: CGFloat = 3.5
        let inset: CGFloat = 3
        let centered = NSRect(
            x: knobRect.midX - visualWidth / 2,
            y: knobRect.minY + inset,
            width: visualWidth,
            height: max(20, knobRect.height - inset * 2)
        )
        let radius = visualWidth / 2
        let path = NSBezierPath(roundedRect: centered, xRadius: radius, yRadius: radius)
        // Forge accent #E72903 with a touch of translucency so the
        // bar feels lighter than solid red over content.
        NSColor(srgbRed: 0.906, green: 0.161, blue: 0.012, alpha: 0.82).setFill()
        path.fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Transparent track — the slim red knob alone provides the
        // visual cue; a track would compete with the content behind it.
    }
}

// MARK: - Selection model

/// What's currently selected in the editor. Drives the detail panel:
/// a snippet shows its editor, a group shows group settings,
/// `.allSnippets` shows the getting-started landing.
enum TXSelection: Hashable {
    case allSnippets
    case snippet(UUID)
    case group(UUID)
}

// MARK: - Top-level view

/// aText-style snippet editor. Layout:
///
///   ┌────────────────────────────────────────────────────┐
///   │ All Snippets         [+ New Snippet] [+ New Group] │
///   ├──────────┬───────────────────┬─────────────────────┤
///   │ Sidebar  │  Folder tree      │  Detail editor      │
///   └──────────┴───────────────────┴─────────────────────┘
struct TextExpanderSettingsView: View {
    @ObservedObject var module: TextExpanderModule

    /// "Primary" selection — drives which editor is shown in the
    /// right pane. In a multi-select, this is the most-recently
    /// clicked item.
    @State private var selection: TXSelection = .allSnippets
    /// Every row currently selected (the set the user is acting on
    /// when they press Delete / drag / right-click). For a normal
    /// single click, this contains exactly the clicked item.
    @State private var multiSelection: Set<TXSelection> = []
    /// "Anchor" point for shift-range selection — the item the user
    /// most recently single-clicked WITHOUT shift. Shift-clicking
    /// any other item then selects everything between this anchor
    /// and the clicked item in tree-display order.
    @State private var anchorSelection: TXSelection?
    /// Drives the batch-delete confirmation dialog. Flipped to true
    /// by the Delete key, the "Delete N Selected" context menu, and
    /// the per-row trash button.
    @State private var confirmingBatchDelete = false
    /// Local NSEvent monitor for the Delete key. Lives at the
    /// `TextExpanderSettingsView` level (not inside the tree) so it
    /// catches Delete regardless of which child view has SwiftUI
    /// focus — clicking a row gives focus to the row's Button,
    /// which `.onKeyPress(.delete)` then misses. The monitor sees
    /// every keyDown in the Settings window and decides whether to
    /// swallow it based on selection state + whether a text field
    /// is currently being edited.
    @State private var deleteKeyMonitor: Any?
    /// Filter for the folder tree. When non-empty, the tree shows a
    /// flat list of matches across all groups instead of the normal
    /// hierarchy.
    @State private var searchQuery: String = ""
    /// IDs slated to claim keyboard focus on next render — used so
    /// "New Snippet" / "New Group" can drop you straight into typing
    /// without a second click.
    @State private var focusedSnippetID: UUID?
    @State private var focusedGroupID: UUID?

    var body: some View {
        // Match the rest of the Settings pane: 24pt between the
        // hero (which acts like SectionHero here) and the content
        // card below it — same rhythm every other tab uses inside
        // its ScrollableContainer.
        VStack(alignment: .leading, spacing: 20) {
            heroHeader
            // Wrap the two-pane editor in matching SettingsCard
            // chrome: 14pt rounded corners, surfaceCard fill, soft
            // shadow, subtle border. This lets Text Expander read as
            // "a soft card on the page" like every other section,
            // instead of a bare two-column grid.
            HStack(spacing: 0) {
                TXGroupTree(
                    module: module,
                    selection: $selection,
                    multiSelection: $multiSelection,
                    anchorSelection: $anchorSelection,
                    searchQuery: $searchQuery,
                    focusedGroupID: $focusedGroupID,
                    onRequestBatchDelete: { confirmingBatchDelete = true }
                )
                .frame(width: 260)

                // Softer vertical separator than a hard Divider — a
                // thin tinted line that blends with the card chrome
                // instead of slicing through it.
                Rectangle()
                    .fill(ForgeTheme.Colors.borderDefault.opacity(0.45))
                    .frame(width: 1)

                TXDetailPanel(
                    module: module,
                    selection: $selection,
                    focusedSnippetID: $focusedSnippetID
                )
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Clip so the inner panes' backgrounds + scrollbars
            // honor the card's 14pt corner radius.
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ForgeTheme.Colors.surfaceCard)
                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            batchDeleteTitle,
            isPresented: $confirmingBatchDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performBatchDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(batchDeleteMessage)
        }
        .onAppear {
            // First render: pick something useful to show.
            if let firstSnippet = module.snippets.first {
                selection = .snippet(firstSnippet.id)
                multiSelection = [.snippet(firstSnippet.id)]
                anchorSelection = .snippet(firstSnippet.id)
            } else if let firstGroup = module.groups.first {
                selection = .group(firstGroup.id)
                multiSelection = [.group(firstGroup.id)]
                anchorSelection = .group(firstGroup.id)
            }
            installDeleteKeyMonitor()
        }
        .onDisappear {
            if let m = deleteKeyMonitor {
                NSEvent.removeMonitor(m)
                deleteKeyMonitor = nil
            }
        }
    }

    // MARK: - Delete-key monitor

    /// Install a local keyDown monitor that catches the Delete key
    /// whenever the user has a non-empty `multiSelection` AND isn't
    /// currently editing a text field. Avoids SwiftUI focus
    /// quirks — `.onKeyPress(.delete)` on the tree view stopped
    /// firing once clicking a row moved focus to that row's Button.
    private func installDeleteKeyMonitor() {
        guard deleteKeyMonitor == nil else { return }
        deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 0x33 = Delete/Backspace, 0x75 = forward Delete (Fn-Delete).
            guard event.keyCode == 0x33 || event.keyCode == 0x75 else { return event }
            // Don't intercept Delete while the user is typing in any
            // text field — search box, snippet name, trigger field,
            // expansion editor. NSText is the common ancestor for
            // every editable text surface (NSTextField uses an
            // internal NSText field editor; NSTextView is an NSText
            // subclass).
            if let fr = NSApp.keyWindow?.firstResponder as? NSText, fr.isEditable {
                return event
            }
            // Only fire if we actually have something selected.
            if multiSelection.isEmpty { return event }
            confirmingBatchDelete = true
            return nil   // swallow — don't let anyone else handle this Delete
        }
    }

    // MARK: Batch delete

    /// Title for the confirmation dialog — adapts to how many items
    /// are about to be deleted and whether they're groups (which
    /// cascade their contents) or just snippets.
    private var batchDeleteTitle: String {
        let n = multiSelection.count
        if n <= 1 {
            if case .group = multiSelection.first { return "Delete this group?" }
            return "Delete this snippet?"
        }
        return "Delete \(n) selected items?"
    }

    private var batchDeleteMessage: String {
        let groupCount = multiSelection.reduce(0) { acc, sel in
            if case .group = sel { return acc + 1 }
            return acc
        }
        if groupCount > 0 {
            return "Deleting a group also removes all its subgroups and snippets. This can't be undone."
        }
        return "This can't be undone."
    }

    /// Delete every item in the current `multiSelection`. Groups go
    /// first so their cascade catches any snippets that were ALSO in
    /// the selection (avoids a "snippet not found" race). Resets
    /// selection back to the landing state afterward.
    private func performBatchDelete() {
        let groupIds = multiSelection.compactMap { sel -> UUID? in
            if case .group(let id) = sel { return id }
            return nil
        }
        let snippetIds = multiSelection.compactMap { sel -> UUID? in
            if case .snippet(let id) = sel { return id }
            return nil
        }
        for id in groupIds   { module.deleteGroup(id) }
        for id in snippetIds { module.deleteSnippet(id) }
        multiSelection = []
        anchorSelection = nil
        selection = .allSnippets
    }

    // MARK: Hero header

    /// Title + subtitle on the left, action buttons on the right —
    /// one horizontal row so they share the same baseline area at the
    /// very top of the tab. Uses `.firstTextBaseline` to lock the
    /// button text baseline to the big title's baseline, the way
    /// macOS Settings panes do it.
    private var heroHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Text Expander")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.primary)
                Text("Type a trigger, get an expansion. Like aText / TextExpander.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer()
            // Order: secondary action (New Group, outlined) on the
            // left, primary action (New Snippet, filled) on the
            // right — matches the standard macOS pattern where the
            // primary CTA sits closest to the eye's final resting
            // position on the trailing edge.
            ForgeSecondaryButton(
                icon: "folder.badge.plus",
                label: "New Group",
                action: newGroup
            )
            ForgePrimaryButton(
                icon: "plus.square.fill",
                label: "New Snippet",
                action: newSnippet
            )
        }
    }

    // MARK: Toolbar actions

    /// Insert a new snippet into whichever group makes sense given
    /// the current selection (group selected → that group; snippet
    /// selected → its group; nothing → first group). Then drop
    /// focus into the name field so the user can start typing.
    private func newSnippet() {
        let targetGroup = currentGroupContext()
        let snippet = module.addSnippet(in: targetGroup)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            selection = .snippet(snippet.id)
            focusedSnippetID = snippet.id
        }
    }

    /// Create a new group as a sibling immediately AFTER the group
    /// that's currently relevant (selected group, OR the parent
    /// group of a selected snippet). If nothing's selected, the
    /// group goes at the end of the root list. Then focus its name
    /// field so it can be renamed immediately.
    private func newGroup() {
        let referenceId: UUID?
        switch selection {
        case .group(let id):
            referenceId = id
        case .snippet(let id):
            referenceId = module.snippets.first(where: { $0.id == id })?.groupId
        case .allSnippets:
            referenceId = nil
        }
        let group = module.addGroup(after: referenceId, name: "New Group")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            selection = .group(group.id)
            focusedGroupID = group.id
        }
    }

    /// Group that "New Snippet" should target given the current
    /// selection.
    private func currentGroupContext() -> UUID? {
        switch selection {
        case .group(let id):
            return id
        case .snippet(let id):
            return module.snippets.first(where: { $0.id == id })?.groupId
        case .allSnippets:
            return module.groups.first?.id
        }
    }
}

// MARK: - Group tree

/// Left column: folder tree of groups + snippets, with a search
/// field at the top. Groups can be dragged onto other groups to
/// reorder (the dragged group becomes the sibling immediately
/// AFTER the drop target). Snippets can be dragged onto groups to
/// reparent. Both drag types use distinct `Transferable` types so
/// the drop handlers don't get confused.
private struct TXGroupTree: View {
    @ObservedObject var module: TextExpanderModule
    @Binding var selection: TXSelection
    @Binding var multiSelection: Set<TXSelection>
    @Binding var anchorSelection: TXSelection?
    @Binding var searchQuery: String
    @Binding var focusedGroupID: UUID?
    /// Parent hook — fires when the tree wants to show the batch
    /// delete confirmation (Delete key pressed, or "Delete Selected"
    /// chosen from a context menu).
    let onRequestBatchDelete: () -> Void

    /// Group IDs that the user has collapsed.
    @State private var collapsed: Set<UUID> = []
    /// Tracks pointer hover so we can subtly tint the active pane's
    /// background — telegraphs to the user "scroll wheel will affect
    /// THIS column". The detail pane has its own equivalent.
    @State private var isHovering = false

    /// True when the user has typed something into the search box —
    /// the tree swaps to a flat results list instead of the folder
    /// hierarchy.
    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Click handling (single / shift-range / cmd-toggle)

    /// Resolve modifier keys from the current AppKit event so we can
    /// branch to single / shift-range / cmd-toggle. Falls back to a
    /// plain single-select if there's no live event (synthetic taps).
    private func handleClick(on item: TXSelection) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift), let anchor = anchorSelection {
            // Shift-range select. Honors current collapsed state.
            applyRangeSelection(from: anchor, to: item)
            selection = item
        } else if flags.contains(.command) {
            // Cmd-toggle — extend or shrink the set, don't reset.
            if multiSelection.contains(item) {
                multiSelection.remove(item)
                // If the user shrank away the primary selection,
                // promote any remaining member; otherwise fall back.
                if selection == item {
                    selection = multiSelection.first ?? .allSnippets
                }
            } else {
                multiSelection.insert(item)
                selection = item
            }
            anchorSelection = item
        } else {
            // Plain click — single select.
            multiSelection = [item]
            selection = item
            anchorSelection = item
        }
    }

    /// Build the flat tree-order list of currently-visible items,
    /// then take everything between `from` and `to` (inclusive,
    /// regardless of direction) as the new multi-selection. Items
    /// inside collapsed groups are excluded — they aren't "visible"
    /// for the user, so they shouldn't silently join the selection.
    private func applyRangeSelection(from: TXSelection, to: TXSelection) {
        let items = visibleTreeItems()
        guard
            let a = items.firstIndex(of: from),
            let b = items.firstIndex(of: to)
        else { return }
        let range = a <= b ? a...b : b...a
        multiSelection = Set(items[range])
    }

    /// Flat, top-down list of items the user CAN see — used as the
    /// linear order for shift-range selection. Collapsed groups
    /// contribute themselves but not their hidden children.
    private func visibleTreeItems() -> [TXSelection] {
        var result: [TXSelection] = []
        func walk(_ parentId: UUID?) {
            for group in module.subgroups(of: parentId) {
                result.append(.group(group.id))
                if !collapsed.contains(group.id) {
                    walk(group.id)
                    for snippet in module.snippets(in: group.id) {
                        result.append(.snippet(snippet.id))
                    }
                }
            }
        }
        walk(nil)
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 5)
            Divider().opacity(0.25)
            // Slim red scroll knob inside a wider hit area — visual
            // stays out of the way, but it's still easy to click and
            // drag. Independent from the detail pane's own scroller.
            ThinRedScrollView {
                VStack(spacing: 0) {
                    if isSearching {
                        searchResults
                    } else {
                        ForEach(module.subgroups(of: nil)) { group in
                            groupNode(group, depth: 0)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(
            // Subtle dark tint distinguishes the tree column from
            // the detail column on the right — gives the left side a
            // gentle "list rail" feel inside the surrounding card.
            // Hover deepens the tint slightly so the user knows
            // which pane their scroll wheel is currently driving.
            (isHovering
                ? Color.black.opacity(0.06)
                : Color.black.opacity(0.03))
            .animation(.easeOut(duration: 0.12), value: isHovering)
        )
        .onHover { hovering in isHovering = hovering }
        // Delete-key handling lives at the `TextExpanderSettingsView`
        // level as an NSEvent local monitor — `.onKeyPress(.delete)`
        // here was getting bypassed because clicking a row moved
        // SwiftUI focus to that row's Button.
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
            TextField("Search snippets…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if isSearching {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(ForgeTheme.Colors.surfaceHover)
        )
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = module.search(searchQuery)
        if results.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.5))
                Text("No matches")
                    .font(.system(size: 11))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else {
            ForEach(results) { s in
                snippetRow(s, depth: 0)
            }
        }
    }

    /// Recursive group + snippet row builder. Returns `AnyView`
    /// because Swift can't infer a concrete opaque type for a
    /// self-recursive view function.
    private func groupNode(_ group: SnippetGroup, depth: Int) -> AnyView {
        let isExpanded = !collapsed.contains(group.id)
        return AnyView(
            VStack(spacing: 0) {
                groupRow(group, depth: depth, isExpanded: isExpanded)
                if isExpanded {
                    ForEach(module.subgroups(of: group.id)) { sub in
                        groupNode(sub, depth: depth + 1)
                    }
                    ForEach(module.snippets(in: group.id)) { snip in
                        snippetRow(snip, depth: depth + 1)
                    }
                }
            }
        )
    }

    private func groupRow(_ group: SnippetGroup, depth: Int, isExpanded: Bool) -> some View {
        let token: TXSelection = .group(group.id)
        let isSelected = multiSelection.contains(token)
        return Button {
            handleClick(on: token)
        } label: {
            HStack(spacing: 6) {
                Button {
                    if isExpanded { collapsed.insert(group.id) }
                    else          { collapsed.remove(group.id) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                Image(systemName: group.enabled ? "folder.fill" : "folder")
                    .font(.system(size: 11))
                    .foregroundColor(
                        group.enabled
                            ? ForgeTheme.Colors.accent.opacity(0.85)
                            : ForgeTheme.Colors.textSecondary.opacity(0.5)
                    )
                Text(group.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                let count = module.snippets(in: group.id).count
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.7))
                }
            }
            .padding(.leading, 6 + CGFloat(depth) * 12)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(rowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        // Group is itself draggable — drop onto another group to
        // reorder/reparent. Preview shows a small folder pill so
        // the user sees what they're carrying.
        .draggable(GroupDragID(id: group.id)) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(ForgeTheme.Colors.accent.opacity(0.85))
            )
            .foregroundColor(.white)
        }
        // Accept SNIPPETS: a snippet (or a batch of them, if the user
        // shift-selected multiple) dropped onto this row joins this
        // group. The drag payload's `ids` array is flattened across
        // every dragged item.
        .dropDestination(for: SnippetDragID.self) { items, _ in
            for item in items {
                for id in item.ids {
                    module.moveSnippet(id, to: group.id)
                }
            }
            return !items.isEmpty
        } isTargeted: { hovering in
            if hovering { collapsed.remove(group.id) }
        }
        // Accept GROUPS: a group dropped onto this row becomes the
        // sibling immediately after it (or reparents into this row's
        // parent + slots in just below).
        .dropDestination(for: GroupDragID.self) { items, _ in
            for item in items {
                module.moveGroup(item.id, toBeAfter: group.id)
            }
            return !items.isEmpty
        }
        .contextMenu {
            // If the right-clicked group is part of a multi-selection
            // (> 1 row), offer the batch delete. Otherwise, the
            // single-row actions: New Here / Rename / Delete.
            let token: TXSelection = .group(group.id)
            let inBatch = multiSelection.contains(token) && multiSelection.count > 1
            if inBatch {
                Button("Delete \(multiSelection.count) Selected", role: .destructive) {
                    onRequestBatchDelete()
                }
            } else {
                Button("New Snippet Here") {
                    let s = module.addSnippet(in: group.id)
                    selection = .snippet(s.id)
                    multiSelection = [.snippet(s.id)]
                    anchorSelection = .snippet(s.id)
                }
                Button("Rename") {
                    focusedGroupID = group.id
                    selection = .group(group.id)
                    multiSelection = [.group(group.id)]
                    anchorSelection = .group(group.id)
                }
                Divider()
                Button("Delete Group", role: .destructive) {
                    // Route through the central confirmation so the
                    // user always sees the same dialog. Replace the
                    // current selection with just this group, then
                    // ask.
                    selection = .group(group.id)
                    multiSelection = [.group(group.id)]
                    anchorSelection = .group(group.id)
                    onRequestBatchDelete()
                }
            }
        }
    }

    private func snippetRow(_ snippet: TextSnippet, depth: Int) -> some View {
        let token: TXSelection = .snippet(snippet.id)
        let isSelected = multiSelection.contains(token)
        return Button {
            handleClick(on: token)
        } label: {
            HStack(spacing: 6) {
                Spacer().frame(width: 12)
                Image(systemName: "text.alignleft")
                    .font(.system(size: 9))
                    .foregroundColor(
                        snippet.enabled
                            ? ForgeTheme.Colors.textSecondary
                            : ForgeTheme.Colors.textSecondary.opacity(0.4)
                    )
                Text(snippet.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(
                        snippet.enabled
                            ? ForgeTheme.Colors.textPrimary
                            : ForgeTheme.Colors.textSecondary.opacity(0.7)
                    )
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !snippet.trigger.isEmpty {
                    Text(snippet.trigger)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(ForgeTheme.Colors.accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(ForgeTheme.Colors.accent.opacity(0.12))
                        )
                }
            }
            .padding(.leading, 6 + CGFloat(depth) * 12)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(rowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        // Drag carries either just this row OR the whole multi-snippet
        // selection if this row is part of one. Drag preview shows
        // the row's name plus an "+N" badge when batched, so the
        // user sees how many they're carrying.
        .draggable(dragPayload(for: snippet)) {
            dragPreview(for: snippet)
        }
        .contextMenu {
            let token: TXSelection = .snippet(snippet.id)
            let inBatch = multiSelection.contains(token) && multiSelection.count > 1
            if inBatch {
                Button("Delete \(multiSelection.count) Selected", role: .destructive) {
                    onRequestBatchDelete()
                }
            } else {
                Button("Delete Snippet", role: .destructive) {
                    selection = .snippet(snippet.id)
                    multiSelection = [.snippet(snippet.id)]
                    anchorSelection = .snippet(snippet.id)
                    onRequestBatchDelete()
                }
            }
        }
    }

    /// Build the drag payload at drag-start time. If this row is part
    /// of a multi-selection, include every selected snippet ID — so
    /// dragging any one of them moves them all.
    private func dragPayload(for snippet: TextSnippet) -> SnippetDragID {
        let token: TXSelection = .snippet(snippet.id)
        if multiSelection.contains(token) && multiSelection.count > 1 {
            let batchIds = multiSelection.compactMap { sel -> UUID? in
                if case .snippet(let id) = sel { return id }
                return nil
            }
            if batchIds.count > 1 {
                return SnippetDragID(ids: batchIds)
            }
        }
        return SnippetDragID(id: snippet.id)
    }

    /// Drag-preview pill. Single-row drag shows just the snippet
    /// name; batch drag adds an "+N more" badge so the user sees
    /// the multi-move is in progress.
    @ViewBuilder
    private func dragPreview(for snippet: TextSnippet) -> some View {
        let token: TXSelection = .snippet(snippet.id)
        let snippetsInBatch = multiSelection.compactMap { sel -> UUID? in
            if case .snippet(let id) = sel { return id }
            return nil
        }.count
        let isBatch = multiSelection.contains(token) && snippetsInBatch > 1
        HStack(spacing: 6) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 10))
            Text(snippet.displayName)
                .font(.system(size: 11, weight: .semibold))
            if isBatch {
                Text("+\(snippetsInBatch - 1)")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.25)))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(ForgeTheme.Colors.accent.opacity(0.85))
        )
        .foregroundColor(.white)
    }

    @ViewBuilder
    private func rowBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 5)
                .fill(ForgeTheme.Colors.accent.opacity(0.18))
                .padding(.horizontal, 4)
        } else {
            Color.clear
        }
    }
}

// MARK: - Detail panel

private struct TXDetailPanel: View {
    @ObservedObject var module: TextExpanderModule
    @Binding var selection: TXSelection
    @Binding var focusedSnippetID: UUID?

    /// Pointer-over flag — same idea as `TXGroupTree.isHovering`.
    /// Brightens the background when the cursor enters so the user
    /// sees which pane's scroll wheel they're currently driving.
    @State private var isHovering = false

    var body: some View {
        ThinRedScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch selection {
                case .snippet(let id):
                    if let idx = module.snippets.firstIndex(where: { $0.id == id }) {
                        SnippetEditor(
                            snippet: $module.snippets[idx],
                            module: module,
                            shouldFocusName: focusedSnippetID == id,
                            onFocusConsumed: { focusedSnippetID = nil },
                            onDelete: {
                                module.deleteSnippet(id)
                                selection = .allSnippets
                            }
                        )
                    } else {
                        emptyPlaceholder("Select a snippet")
                    }
                case .group(let id):
                    if let idx = module.groups.firstIndex(where: { $0.id == id }) {
                        GroupEditor(
                            group: $module.groups[idx],
                            module: module,
                            onDelete: {
                                module.deleteGroup(id)
                                selection = .allSnippets
                            }
                        )
                    } else {
                        emptyPlaceholder("Select a group")
                    }
                case .allSnippets:
                    gettingStartedPanel
                }
            }
            // Tighter padding (was 20) — the user noted the previous
            // version had unwanted whitespace around the editor.
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(
            // Detail pane sits flush with the card's surfaceCard
            // background when idle — the tree's "list rail" tint to
            // the left is enough to differentiate the two columns.
            // Hover adds a barely-there tint so the user still has
            // the cue that this is the active scroll pane.
            (isHovering
                ? Color.black.opacity(0.02)
                : Color.clear)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        )
        .onHover { hovering in isHovering = hovering }
    }

    private func emptyPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(ForgeTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Default landing — shown when nothing specific is selected.
    private var gettingStartedPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroHeader
            placeholdersCard
        }
    }

    private var heroHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "text.cursor")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.accent)
                .frame(width: 36, height: 36)
                .background(ForgeTheme.Colors.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text("Type triggers, get expansions.")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                Text("Like aText / Rocket Typist. Type a trigger followed by a delimiter (or just the trigger itself, depending on the snippet) — and Forge swaps it for the expansion.")
                    .font(.system(size: 12))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var placeholdersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.accent)
                Text("Placeholders")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.4)
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
            }
            VStack(spacing: 0) {
                placeholderRow("{date}",      "Today's date (e.g. May 25, 2026)")
                Divider().opacity(0.2)
                placeholderRow("{time}",      "Current time (e.g. 14:30)")
                Divider().opacity(0.2)
                placeholderRow("{datetime}",  "Date + time combined")
                Divider().opacity(0.2)
                placeholderRow("{clipboard}", "Current clipboard text")
                Divider().opacity(0.2)
                placeholderRow("{cursor}",    "Caret lands here after the expansion")
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(ForgeTheme.Colors.surfaceCard.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(ForgeTheme.Colors.borderDefault.opacity(0.4), lineWidth: 1)
            )
        }
    }

    private func placeholderRow(_ token: String, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Text(token)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(ForgeTheme.Colors.accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(ForgeTheme.Colors.accent.opacity(0.10)))
            Text(desc)
                .font(.system(size: 11))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
    }
}

// MARK: - Snippet editor

private struct SnippetEditor: View {
    @Binding var snippet: TextSnippet
    @ObservedObject var module: TextExpanderModule
    let shouldFocusName: Bool
    let onFocusConsumed: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            // Name + Trigger share a row so the editor reads as
            // "the snippet's identity at a glance". Equal-width
            // 50/50 split — same `.frame(maxWidth: .infinity)` on
            // both makes them each claim half the available space.
            HStack(alignment: .top, spacing: 12) {
                field(label: "Name") {
                    TextField("Greeting", text: $snippet.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(fieldBackground)
                        .focused($nameFocused)
                        .onChange(of: shouldFocusName) { _, newValue in
                            if newValue { nameFocused = true; onFocusConsumed() }
                        }
                        .onAppear {
                            if shouldFocusName { nameFocused = true; onFocusConsumed() }
                        }
                }
                .frame(maxWidth: .infinity)

                field(label: "Trigger", hint: "e.g. btw") {
                    TextField("btw", text: $snippet.trigger)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(ForgeTheme.Colors.textPrimary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(fieldBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(ForgeTheme.Colors.accent.opacity(0.30), lineWidth: 1)
                        )
                }
                .frame(maxWidth: .infinity)
            }

            field(label: "Expansion", hint: "What Forge types instead") {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ForgeTheme.Colors.borderDefault, lineWidth: 1)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(ForgeTheme.Colors.surfaceCard)
                        )
                    WheelPassthroughTextEditor(text: $snippet.expansion)
                        .padding(2)
                        .frame(minHeight: 120, maxHeight: 220)
                    if snippet.expansion.isEmpty {
                        Text("by the way{cursor}")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.55))
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
            }

            Divider().opacity(0.3).padding(.vertical, 4)

            // "Expand on" / case checkbox / app scope — these used to
            // sit under "Behavior" / "Case" / "Apps" subheadings, but
            // the labels added noise without information. The field
            // labels already say what each control does.
            field(label: "Expand on") {
                Picker("", selection: $snippet.expandOn) {
                    ForEach(ExpandTrigger.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Case-sensitive checkbox sits inline — no separate "Case"
            // label, since the toggle's own text reads as a full
            // sentence ("Trigger is case-sensitive").
            Toggle(isOn: $snippet.caseSensitive) {
                Text("Trigger is case-sensitive")
                    .font(.system(size: 12))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
            }
            .toggleStyle(.checkbox)

            field(label: "Apps") {
                appScopeEditor
            }
        }
        .confirmationDialog(
            "Delete this snippet?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Header bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text(snippet.displayName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.textPrimary)
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: $snippet.enabled)
                .toggleStyle(.forge)
                .labelsHidden()
            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(ForgeTheme.Colors.surfaceHover))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: App scope editor

    private var appScopeEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding<Int>(
                get: {
                    switch snippet.appScope {
                    case .allApps:   return 0
                    case .onlyIn:    return 1
                    case .exceptIn:  return 2
                    }
                },
                set: { newVal in
                    switch newVal {
                    case 0: snippet.appScope = .allApps
                    case 1:
                        if case .exceptIn(let set) = snippet.appScope {
                            snippet.appScope = .onlyIn(set)
                        } else if case .allApps = snippet.appScope {
                            snippet.appScope = .onlyIn([])
                        }
                    case 2:
                        if case .onlyIn(let set) = snippet.appScope {
                            snippet.appScope = .exceptIn(set)
                        } else if case .allApps = snippet.appScope {
                            snippet.appScope = .exceptIn([])
                        }
                    default: break
                    }
                }
            )) {
                Text("All apps").tag(0)
                Text("Only in selected").tag(1)
                Text("Except in selected").tag(2)
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if case .allApps = snippet.appScope {
                EmptyView()
            } else {
                appList
                Button {
                    addAppViaOpenPanel()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11))
                        Text("Add app…")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(ForgeTheme.Colors.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var appList: some View {
        let bundles: [String] = {
            switch snippet.appScope {
            case .onlyIn(let s), .exceptIn(let s): return Array(s).sorted()
            default: return []
            }
        }()
        if bundles.isEmpty {
            Text(snippet.appScope.isOnlyIn
                 ? "No apps yet — the snippet won't fire anywhere until you add one."
                 : "No apps yet — the snippet still fires everywhere.")
                .font(.system(size: 11))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
                .padding(.vertical, 2)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(bundles, id: \.self) { id in
                    appChip(id)
                }
            }
        }
    }

    private func appChip(_ bundleId: String) -> some View {
        HStack(spacing: 4) {
            Text(displayName(for: bundleId))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.textPrimary)
            Button {
                removeAppFromScope(bundleId)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            Capsule().fill(ForgeTheme.Colors.surfaceHover)
        )
        .overlay(
            Capsule().strokeBorder(ForgeTheme.Colors.borderDefault.opacity(0.4), lineWidth: 1)
        )
    }

    private func displayName(for bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
           let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return bundleId
    }

    /// Pop NSOpenPanel restricted to .app bundles. Multi-select so
    /// the user can ⌘-click or Shift-click many apps at once.
    private func addAppViaOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.message = "Pick one or more apps (⌘-click to multi-select)."
        guard panel.runModal() == .OK else { return }
        var newIds: Set<String> = []
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty {
                newIds.insert(id)
            }
        }
        guard !newIds.isEmpty else { return }
        addAppsToScope(newIds)
    }

    /// Union the supplied bundle IDs into the current scope set,
    /// promoting `.allApps` to `.onlyIn` on first add.
    private func addAppsToScope(_ bundleIds: Set<String>) {
        switch snippet.appScope {
        case .allApps:
            snippet.appScope = .onlyIn(bundleIds)
        case .onlyIn(var set):
            set.formUnion(bundleIds)
            snippet.appScope = .onlyIn(set)
        case .exceptIn(var set):
            set.formUnion(bundleIds)
            snippet.appScope = .exceptIn(set)
        }
    }

    private func removeAppFromScope(_ bundleId: String) {
        switch snippet.appScope {
        case .allApps: break
        case .onlyIn(var set):
            set.remove(bundleId)
            snippet.appScope = .onlyIn(set)
        case .exceptIn(var set):
            set.remove(bundleId)
            snippet.appScope = .exceptIn(set)
        }
    }

    // MARK: Layout helpers

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(ForgeTheme.Colors.surfaceHover)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundColor(ForgeTheme.Colors.textSecondary)
    }

    private func field<Content: View>(
        label: String,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.6))
                }
            }
            content()
        }
    }
}

private extension AppScope {
    var isOnlyIn: Bool {
        if case .onlyIn = self { return true }
        return false
    }
}

// MARK: - Group editor

private struct GroupEditor: View {
    @Binding var group: SnippetGroup
    @ObservedObject var module: TextExpanderModule
    let onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 18))
                    .foregroundColor(ForgeTheme.Colors.accent)
                    .frame(width: 32, height: 32)
                    .background(ForgeTheme.Colors.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(group.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Toggle("", isOn: $group.enabled)
                    .toggleStyle(.forge)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                TextField("Group name", text: $group.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(ForgeTheme.Colors.surfaceHover)
                    )
            }

            let snippetCount = module.snippets(in: group.id).count
            let subgroupCount = module.subgroups(of: group.id).count
            HStack(spacing: 18) {
                statBlock(value: "\(snippetCount)", label: "Snippet\(snippetCount == 1 ? "" : "s")")
                statBlock(value: "\(subgroupCount)", label: "Subgroup\(subgroupCount == 1 ? "" : "s")")
            }

            Spacer().frame(height: 6)

            Text("Disabling a group mutes every snippet inside it — including snippets in subgroups. Delete removes the group, its subgroups, and all their snippets. There's no undo, so keep it tidy.")
                .font(.system(size: 11))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button {
                    confirmDelete = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("Delete Group")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.red.opacity(0.85))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog(
            "Delete \(group.name)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the group, all its subgroups, and every snippet they contain.")
        }
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(ForgeTheme.Colors.textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ForgeTheme.Colors.surfaceCard.opacity(0.6))
        )
    }
}

// MARK: - FlowLayout (wraps app chips)

/// Wraps its children onto multiple lines, like CSS flex-wrap. SwiftUI
/// doesn't ship one of these, so we hand-roll a `Layout`.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += sz.width + spacing
            maxX = max(maxX, x)
            rowHeight = max(rowHeight, sz.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
    }
}

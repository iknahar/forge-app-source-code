import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings → Launchers page. Surfaces the user's list of launcher
/// entries (app / file / URL) and lets them add, edit, re-bind, or
/// delete each one. Routes through `LaunchersModule` for persistence
/// + global-hotkey registration.
struct LaunchersSettingsView: View {
    @ObservedObject var module: LaunchersModule
    @EnvironmentObject var moduleRegistry: ModuleRegistry
    @EnvironmentObject var settings: SettingsManager

    /// `nil` = no sheet shown. Holds the launcher under edit (or a
    /// fresh blank one when the user clicked "Add launcher").
    @State private var sheetTarget: LauncherSheetMode?

    private var isEnabled: Bool {
        moduleRegistry.isEnabled(module.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            masterToggleCard
            listCard
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.45)
            footer
        }
        .sheet(item: $sheetTarget) { mode in
            LauncherEditSheet(
                mode: mode,
                otherLaunchers: module.launchers,
                forgeBindings: settings.shortcutBindings,
                onSave: { launcher in
                    switch mode {
                    case .add:
                        module.addLauncher(launcher)
                    case .edit:
                        module.updateLauncher(launcher)
                    }
                    sheetTarget = nil
                },
                onCancel: { sheetTarget = nil }
            )
        }
    }

    // MARK: - Master toggle

    private var masterToggleCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ForgeTheme.Colors.accent.opacity(0.12))
                )
            Text(isEnabled
                 ? "\(module.launchers.count) launcher\(module.launchers.count == 1 ? "" : "s") armed."
                 : "Launchers paused.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(ForgeTheme.Colors.textPrimary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { moduleRegistry.isEnabled(module.id) },
                set: { _ in moduleRegistry.toggleModule(module.id) }
            ))
            .toggleStyle(.forge)
            .labelsHidden()
            .tint(ForgeTheme.Colors.accent)
        }
        .padding(16)
        .background(ForgeTheme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }

    // MARK: - List

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row with the Add button.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your launchers")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Bind a shortcut to open any app, document, or URL.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: {
                    sheetTarget = .add(Launcher(name: "", kind: .app, target: ""))
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Add launcher")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(ForgeTheme.Colors.accent))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.3)

            if module.launchers.isEmpty {
                emptyState
            } else {
                ForEach(module.launchers) { launcher in
                    LauncherRowView(
                        launcher: launcher,
                        onEdit:   { sheetTarget = .edit(launcher) },
                        onToggle: { module.toggleEnabled(launcher.id) },
                        onDelete: { module.removeLauncher(launcher.id) }
                    )
                    Divider().opacity(0.2)
                }
            }
        }
        .background(ForgeTheme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text("No launchers yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Click \"Add launcher\" to bind your first shortcut.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HOW IT WORKS")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.2)
                .foregroundColor(.secondary)
            Text("Each launcher gets its own global shortcut. Press the combo from anywhere — Forge calls the system opener for the target (NSWorkspace) so the right app comes up, whether that's a `.app` bundle, a document with its default handler, or a URL.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Sheet mode

/// What the edit sheet should do when it saves. Distinguishes
/// "Add" (append to list) vs. "Edit" (replace by ID).
enum LauncherSheetMode: Identifiable {
    case add(Launcher)
    case edit(Launcher)

    var id: String {
        switch self {
        case .add(let l):  return "add-\(l.id.uuidString)"
        case .edit(let l): return "edit-\(l.id.uuidString)"
        }
    }

    var launcher: Launcher {
        switch self {
        case .add(let l), .edit(let l): return l
        }
    }

    var titleVerb: String {
        switch self {
        case .add:  return "Add launcher"
        case .edit: return "Edit launcher"
        }
    }
}

// MARK: - Row

private struct LauncherRowView: View {
    let launcher: Launcher
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var deleteHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Kind icon chip.
            Image(systemName: launcher.kind.iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(launcher.enabled ? ForgeTheme.Colors.accent : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill((launcher.enabled ? ForgeTheme.Colors.accent : Color.gray).opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(launcher.name.isEmpty ? "(no name)" : launcher.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                Text(targetPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Shortcut chip (or "Set shortcut" placeholder).
            shortcutChip

            // Enable / disable toggle.
            Toggle("", isOn: Binding(
                get: { launcher.enabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.forge)
            .labelsHidden()
            .controlSize(.mini)
            .tint(ForgeTheme.Colors.accent)

            // Delete (trash icon).
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundColor(deleteHovering ? .red : .secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .onHover { deleteHovering = $0 }
                .onTapGesture { onDelete() }
                .help("Delete this launcher")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onEdit() }
    }

    /// Short display of the target — collapses long paths so the
    /// row stays one-line.
    private var targetPreview: String {
        switch launcher.kind {
        case .app:
            // Show just the .app filename.
            let url = URL(fileURLWithPath: launcher.target)
            return url.deletingPathExtension().lastPathComponent.isEmpty
                ? launcher.target
                : url.lastPathComponent
        case .file:
            return launcher.target
        case .url:
            return launcher.target
        }
    }

    @ViewBuilder
    private var shortcutChip: some View {
        if let binding = launcher.shortcut {
            Text(binding.displayString)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(ForgeTheme.Colors.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(ForgeTheme.Colors.accent.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(ForgeTheme.Colors.accent.opacity(0.32), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { onEdit() }
                .help("Edit shortcut")
        } else {
            Text("Set shortcut")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(ForgeTheme.Colors.surfaceHover)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { onEdit() }
        }
    }
}

// MARK: - Edit sheet

private struct LauncherEditSheet: View {
    @State var mode: LauncherSheetMode
    /// Other launchers the user already has — used to flag in-app
    /// conflicts (so two launchers don't bind the same combo).
    let otherLaunchers: [Launcher]
    /// Forge's built-in shortcut bindings (screenshot, clipboard,
    /// color picker, etc.). Conflict check runs against these too.
    let forgeBindings: [String: ShortcutBinding]
    let onSave: (Launcher) -> Void
    let onCancel: () -> Void

    // Working copy mutated by the sheet's controls. Initialised
    // from the mode in `onAppear`.
    @State private var draft: Launcher = Launcher(name: "", kind: .app, target: "")
    @State private var isRecordingShortcut: Bool = false
    /// Human-readable conflict description for the currently
    /// captured shortcut, or `nil` when the combo is safe.
    @State private var shortcutConflict: String? = nil
    /// Hard-modal alert flag — opened when the user tries to Save
    /// while the captured combo still has a known conflict.
    @State private var showConflictAlert: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode.titleVerb)
                .font(.system(size: 18, weight: .bold))

            // Kind picker.
            HStack(spacing: 12) {
                Text("Kind")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $draft.kind) {
                    ForEach(LauncherKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: draft.kind) { _, _ in
                    // Switching kind invalidates the old target.
                    draft.target = ""
                }
            }

            // Name field.
            HStack(spacing: 12) {
                Text("Name")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 80, alignment: .leading)
                TextField("e.g. Slack, Project notes, Inbox", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            // Target field — varies by kind.
            HStack(spacing: 12) {
                Text(draft.kind == .url ? "URL" : "Path")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 80, alignment: .leading)
                if draft.kind == .url {
                    TextField("https://example.com or mailto:you@example.com", text: $draft.target)
                        .textFieldStyle(.roundedBorder)
                } else {
                    HStack(spacing: 6) {
                        TextField("", text: $draft.target)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        Button("Pick…", action: pickTarget)
                    }
                }
            }

            // Shortcut binding.
            HStack(spacing: 12) {
                Text("Shortcut")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 80, alignment: .leading)
                ShortcutRecorderView(
                    currentBinding: draft.shortcut ?? Self.placeholderBinding,
                    isRecording: $isRecordingShortcut,
                    onRecord: { keyCode, modifiers in
                        draft.shortcut = ShortcutBinding(keyCode: keyCode, modifiers: modifiers)
                        isRecordingShortcut = false
                        refreshConflict()
                    },
                    onCancel: { isRecordingShortcut = false }
                )
                .frame(width: 130, height: 26)
                Button(action: { isRecordingShortcut.toggle() }) {
                    Image(systemName: isRecordingShortcut ? "xmark" : "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isRecordingShortcut ? .white : ForgeTheme.Colors.accent)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5).fill(
                                isRecordingShortcut
                                    ? ForgeTheme.Colors.accent
                                    : ForgeTheme.Colors.accent.opacity(0.12)
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(isRecordingShortcut ? "Stop recording" : "Edit shortcut")

                if draft.shortcut != nil {
                    Button(action: {
                        draft.shortcut = nil
                        refreshConflict()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
                }
                Spacer()
            }

            // Inline conflict warning — appears below the recorder
            // when the captured combo collides with a known macOS
            // shortcut, another Forge action, or another launcher.
            // Soft warning UX: the user can still save (Save shows
            // a hard confirm alert), but the visual cue is loud.
            if let reason = shortcutConflict {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shortcut already in use")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.orange)
                        Text("Conflicts with \(reason). Other apps that bind this shortcut may stop responding to it while Forge is running.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                )
            }

            Divider().opacity(0.3)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    // If there's still a known conflict, route via
                    // a confirm alert so the user explicitly
                    // acknowledges they're overriding a default.
                    if shortcutConflict != nil {
                        showConflictAlert = true
                    } else {
                        commitSave()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            draft = mode.launcher
            refreshConflict()
        }
        .alert("Shortcut conflict", isPresented: $showConflictAlert) {
            Button("Cancel", role: .cancel) { /* keep editing */ }
            Button("Bind anyway", role: .destructive) { commitSave() }
        } message: {
            Text("This combo conflicts with \(shortcutConflict ?? "another binding"). Binding it may break that action while Forge is running. Continue?")
        }
    }

    /// Re-evaluate whether `draft.shortcut` clashes with anything
    /// known. Called after every record / clear, plus once on
    /// appear so an existing assignment is checked on load too.
    private func refreshConflict() {
        guard let binding = draft.shortcut, binding.keyCode != 0 else {
            shortcutConflict = nil
            return
        }
        shortcutConflict = ShortcutConflicts.conflict(
            keyCode: binding.keyCode,
            modifiers: binding.nsModifiers,
            forgeBindings: forgeBindings,
            launchers: otherLaunchers,
            excludingLauncherId: draft.id
        )
    }

    /// Apply the default-name fallback and commit. Pulled out of
    /// the inline `Button` action so both the direct-save and
    /// alert-confirm paths share the same exit.
    private func commitSave() {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = defaultName(for: draft)
        }
        onSave(draft)
    }

    /// Default shortcut shown while none has been recorded. Bound
    /// to nothing — just a visual placeholder for `ShortcutRecorderView`.
    private static let placeholderBinding = ShortcutBinding(
        keyCode: 0, modifiers: []
    )

    /// Reasonable default label so the user gets a non-empty row
    /// if they forget to type a name.
    private func defaultName(for l: Launcher) -> String {
        switch l.kind {
        case .app, .file:
            return URL(fileURLWithPath: l.target).deletingPathExtension().lastPathComponent
        case .url:
            return l.target
        }
    }

    private func pickTarget() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        switch draft.kind {
        case .app:
            panel.allowedContentTypes = [UTType.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.title = "Pick an application"
        case .file:
            // Any file — no type restriction.
            panel.title = "Pick a document"
        case .url:
            return
        }
        if panel.runModal() == .OK, let url = panel.url {
            draft.target = url.path
            if draft.name.isEmpty {
                draft.name = url.deletingPathExtension().lastPathComponent
            }
        }
    }
}

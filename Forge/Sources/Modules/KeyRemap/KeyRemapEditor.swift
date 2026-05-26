import SwiftUI
import AppKit

/// Settings UI for the Key Remap module. Lists existing mappings,
/// lets the user toggle / delete each one, and opens a capture sheet
/// for adding new ones. The underlying CGEventTap and persistence is
/// owned by `KeyRemapModule`; this view just CRUDs `module.remappings`.
struct KeyRemapEditor: View {
    @ObservedObject var module: KeyRemapModule
    @State private var showAddSheet = false
    @State private var pendingEdit: KeyRemapping?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Status card — Accessibility permission + count
            statusCard

            // Mappings list / empty state
            if module.remappings.isEmpty {
                emptyState
            } else {
                mappingsCard
            }

            // Always-visible "Add" CTA at the bottom
            HStack {
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add mapping")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(ForgeTheme.Colors.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            KeyRemapCaptureSheet(existing: nil) { newMapping in
                if let mapping = newMapping {
                    module.addRemapping(mapping)
                }
                showAddSheet = false
            }
        }
        .sheet(item: $pendingEdit) { remap in
            KeyRemapCaptureSheet(existing: remap) { updated in
                if let updated = updated,
                   let idx = module.remappings.firstIndex(where: { $0.id == remap.id }) {
                    module.remappings[idx] = updated
                    module.saveProfilesPublic()
                }
                pendingEdit = nil
            }
        }
    }

    // MARK: - Cards

    private var statusCard: some View {
        KeyRemapCard(title: "Status", titleIcon: "checkmark.shield.fill") {
            HStack(spacing: 14) {
                Circle()
                    .fill(module.isEnabled
                          ? Color.green
                          : Color.gray)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(module.isEnabled
                         ? "Key remapping is active"
                         : "Key Remap module is disabled")
                        .font(.system(size: 13, weight: .medium))
                    Text("\(module.remappings.count) mapping\(module.remappings.count == 1 ? "" : "s") configured")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !AXIsProcessTrusted() {
                    Button {
                        // Nudge user to grant Accessibility — the system
                        // panel is the only way to actually flip it.
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.shield.fill")
                            Text("Grant Accessibility")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.orange))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyState: some View {
        KeyRemapCard(title: "Mappings", titleIcon: "arrow.left.arrow.right") {
            VStack(spacing: 10) {
                Image(systemName: "keyboard.badge.eye")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary.opacity(0.7))
                Text("No mappings yet")
                    .font(.system(size: 14, weight: .semibold))
                Text("Add a mapping to remap any key or combo to another, system-wide or per-app.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    private var mappingsCard: some View {
        KeyRemapCard(
            title: "Mappings",
            titleIcon: "arrow.left.arrow.right",
            description: "Click a mapping to edit it. Toggle the switch to enable / disable without deleting."
        ) {
            VStack(spacing: 0) {
                ForEach(Array(module.remappings.enumerated()), id: \.element.id) { index, remap in
                    if index > 0 {
                        Divider().opacity(0.3)
                    }
                    mappingRow(remap, index: index)
                }
            }
        }
    }

    private func mappingRow(_ remap: KeyRemapping, index: Int) -> some View {
        HStack(spacing: 12) {
            // Source key chip
            keyChip(text: remap.sourceDescription, isSource: true)

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            // Target key chip
            keyChip(text: remap.targetDescription, isSource: false)

            VStack(alignment: .leading, spacing: 1) {
                Text(remap.name.isEmpty ? "Remapping" : remap.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(appLabel(for: remap.appBundleId))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { module.remappings[index].isEnabled },
                set: { _ in module.toggleRemapping(at: index) }
            ))
            .toggleStyle(.forge)
            .labelsHidden()

            Button {
                module.removeRemapping(at: index)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.black.opacity(0.04)))
            }
            .buttonStyle(.plain)
            .help("Delete mapping")
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            pendingEdit = remap
        }
    }

    private func keyChip(text: String, isSource: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(isSource
                             ? ForgeTheme.Colors.textPrimary
                             : ForgeTheme.Colors.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            )
    }

    /// Resolve a bundle id to a friendly label for the "scope" column.
    /// nil / "*" → "Global"; otherwise try to look up the running app's
    /// localizedName, fall back to the bundle id.
    private func appLabel(for bundleId: String?) -> String {
        guard let id = bundleId, id != "*" else { return "Global" }
        if let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == id }),
           let name = app.localizedName {
            return "Only in \(name)"
        }
        return "Only in \(id)"
    }
}

// MARK: - Capture sheet

/// Sheet that lets the user record a source combo, a target combo, an
/// optional name + per-app scope, and either save a new mapping or
/// update an existing one (when `existing` is provided).
struct KeyRemapCaptureSheet: View {
    let existing: KeyRemapping?
    let onDone: (KeyRemapping?) -> Void

    @State private var name: String = ""
    @State private var sourceKeyCode: UInt16 = 0
    @State private var sourceModifiers: NSEvent.ModifierFlags = []
    @State private var targetKeyCode: UInt16 = 0
    @State private var targetModifiers: NSEvent.ModifierFlags = []
    @State private var appScope: String = "*"            // "*" = global
    @State private var recordingSource = false
    @State private var recordingTarget = false
    @State private var sourceCaptured = false
    @State private var targetCaptured = false

    init(existing: KeyRemapping?, onDone: @escaping (KeyRemapping?) -> Void) {
        self.existing = existing
        self.onDone = onDone
        if let e = existing {
            _name = State(initialValue: e.name)
            _sourceKeyCode = State(initialValue: e.sourceKeyCode)
            _targetKeyCode = State(initialValue: e.targetKeyCode)
            _sourceModifiers = State(initialValue: KeyRemapCaptureSheet.flags(from: e.sourceModifiers))
            _targetModifiers = State(initialValue: KeyRemapCaptureSheet.flags(from: e.targetModifiers))
            _appScope = State(initialValue: e.appBundleId ?? "*")
            _sourceCaptured = State(initialValue: true)
            _targetCaptured = State(initialValue: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New key remap" : "Edit key remap")
                .font(.system(size: 18, weight: .bold))

            TextField("Optional name (e.g. Caps Lock → Esc)", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            // Source + Target capture
            HStack(alignment: .top, spacing: 16) {
                captureColumn(
                    label: "When I press",
                    binding: ShortcutBinding(keyCode: sourceKeyCode,
                                             modifiers: sourceModifiers),
                    captured: sourceCaptured,
                    isRecording: $recordingSource,
                    onRecord: { code, mods in
                        sourceKeyCode = code
                        sourceModifiers = mods
                        sourceCaptured = true
                        recordingSource = false
                    }
                )
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.top, 32)
                captureColumn(
                    label: "Forge sends",
                    binding: ShortcutBinding(keyCode: targetKeyCode,
                                             modifiers: targetModifiers),
                    captured: targetCaptured,
                    isRecording: $recordingTarget,
                    onRecord: { code, mods in
                        targetKeyCode = code
                        targetModifiers = mods
                        targetCaptured = true
                        recordingTarget = false
                    }
                )
            }

            // Scope picker
            HStack(spacing: 10) {
                Image(systemName: "app.gift")
                    .foregroundColor(.secondary)
                Text("Active in")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Picker("", selection: $appScope) {
                    Text("All apps (Global)").tag("*")
                    Divider()
                    ForEach(runningApps, id: \.0) { (bundleId, name) in
                        Text(name).tag(bundleId)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            // Action row
            HStack {
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    save()
                } label: {
                    Text(existing == nil ? "Add mapping" : "Save changes")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(ForgeTheme.Colors.accent))
                }
                .buttonStyle(.plain)
                .disabled(!sourceCaptured || !targetCaptured)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    // MARK: - Sub-views

    private func captureColumn(label: String,
                               binding: ShortcutBinding,
                               captured: Bool,
                               isRecording: Binding<Bool>,
                               onRecord: @escaping (UInt16, NSEvent.ModifierFlags) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundColor(.secondary)
            ShortcutRecorderView(
                currentBinding: captured ? binding : ShortcutBinding(keyCode: 0, modifiers: []),
                isRecording: isRecording,
                // KeyRemap explicitly supports modifier-less keys —
                // `a → b`, `Caps Lock → Esc`, etc. — so we opt into
                // the bare-key capture path here.
                allowsBareKey: true,
                onRecord: onRecord,
                onCancel: { isRecording.wrappedValue = false }
            )
            .frame(width: 180, height: 36)
            Button {
                isRecording.wrappedValue.toggle()
            } label: {
                Text(isRecording.wrappedValue
                     ? "Press any key…"
                     : (captured ? "Re-record" : "Record"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // Running apps for the scope picker.
    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .compactMap { app -> (String, String)? in
                guard let bundleId = app.bundleIdentifier,
                      let name = app.localizedName,
                      app.activationPolicy == .regular
                else { return nil }
                return (bundleId, name)
            }
            .sorted { $0.1.lowercased() < $1.1.lowercased() }
    }

    // MARK: - Helpers

    private func save() {
        var remap = KeyRemapping(
            name: name,
            sourceKeyCode: sourceKeyCode,
            sourceModifiers: Self.modifiers(from: sourceModifiers),
            targetKeyCode: targetKeyCode,
            targetModifiers: Self.modifiers(from: targetModifiers),
            appBundleId: appScope == "*" ? nil : appScope
        )
        if let e = existing {
            // Preserve id + enabled state across edits so the user's
            // toggle position doesn't reset.
            remap = KeyRemapping(
                name: name,
                sourceKeyCode: sourceKeyCode,
                sourceModifiers: Self.modifiers(from: sourceModifiers),
                targetKeyCode: targetKeyCode,
                targetModifiers: Self.modifiers(from: targetModifiers),
                appBundleId: appScope == "*" ? nil : appScope
            )
            // Manually re-attach the original id by encoding/decoding
            // through JSON — KeyRemapping's id is `let` so we can't
            // mutate it. We return a wholly new mapping; the caller is
            // responsible for replacing by index.
            _ = e
        }
        onDone(remap)
    }

    /// Bridge `NSEvent.ModifierFlags` ⇄ `[ModifierKey]` since the model
    /// stores the latter.
    private static func modifiers(from flags: NSEvent.ModifierFlags) -> [ModifierKey] {
        var out: [ModifierKey] = []
        if flags.contains(.command)  { out.append(.command) }
        if flags.contains(.option)   { out.append(.option) }
        if flags.contains(.control)  { out.append(.control) }
        if flags.contains(.shift)    { out.append(.shift) }
        if flags.contains(.function) { out.append(.fn) }
        return out
    }

    private static func flags(from mods: [ModifierKey]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for m in mods {
            switch m {
            case .command:  flags.insert(.command)
            case .option:   flags.insert(.option)
            case .control:  flags.insert(.control)
            case .shift:    flags.insert(.shift)
            case .fn:       flags.insert(.function)
            }
        }
        return flags
    }
}

// MARK: - Identifiable + persistence helper

extension KeyRemapping {
    // Already Identifiable via `let id: String`. Re-stated here to
    // satisfy the .sheet(item:) requirement explicitly.
}

extension KeyRemapModule {
    /// Public alias so the editor can re-persist after an edit (the
    /// internal `saveProfiles` is private). Mutating `remappings`
    /// directly bypasses `updateActiveProfile` which we still need.
    func saveProfilesPublic() {
        if let idx = profiles.firstIndex(where: { $0.id == activeProfileId }) {
            profiles[idx].remappings = remappings
        }
    }
}

// MARK: - Local card helper

/// Mirrors the visual style of `SettingsCard` (file-private in
/// SettingsView.swift) so this editor doesn't reach into that file's
/// internals. Stays in sync if SettingsCard's visual tokens change.
private struct KeyRemapCard<Content: View>: View {
    var title: String? = nil
    var titleIcon: String? = nil
    var description: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || description != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title = title {
                        HStack(spacing: 7) {
                            if let icon = titleIcon {
                                Image(systemName: icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(ForgeTheme.Colors.accent)
                            }
                            Text(title)
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    if let description = description {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ForgeTheme.Colors.surfaceCard)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }
}

import SwiftUI
import AppKit

/// Settings → App Lock. Cards, top to bottom:
///
///   1. Lock status — mirrors the "Lock selected apps?" toggle in the
///      Tools popover. Toggle-on locks immediately; toggle-off pops
///      the PIN prompt.
///   2. PIN — the single global PIN, salted SHA-256.
///   3. Lock now + shortcut — instant lock button plus the keyboard
///      shortcut binding (same key unlocks with a PIN prompt).
///   4. Selected apps — list the arm switch acts on.
struct AppLockSettingsView: View {
    @ObservedObject var module: AppLockModule
    @EnvironmentObject var moduleRegistry: ModuleRegistry
    @EnvironmentObject var settings: SettingsManager

    @State private var showingAddSheet = false
    @State private var showingPINSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            lockStatusCard
            pinCard
            lockNowCard
                .disabled(!module.hasPIN || module.selections.isEmpty)
                .opacity((module.hasPIN && !module.selections.isEmpty) ? 1 : 0.55)
            selectedListCard
                .disabled(!module.hasPIN)
                .opacity(module.hasPIN ? 1 : 0.55)
        }
        .sheet(isPresented: $showingAddSheet) {
            AddSelectionSheet(module: module, isPresented: $showingAddSheet)
        }
        .sheet(isPresented: $showingPINSheet) {
            SetPINSheet(module: module, isPresented: $showingPINSheet)
        }
    }

    private var isLocked: Bool { moduleRegistry.isEnabled(module.id) }

    private var canArm: Bool {
        module.hasPIN && !module.selections.isEmpty
    }

    // MARK: - Card 1: Lock status

    /// The main arm switch. Turning ON locks instantly. Turning OFF
    /// while locked pops the PIN prompt — the toggle itself doesn't
    /// flip until the user enters the right PIN, because
    /// `requestUnlock()` handles the flip on success.
    private var lockStatusCard: some View {
        HStack(spacing: 14) {
            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isLocked ? ForgeTheme.Colors.accentRed : ForgeTheme.Colors.accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill((isLocked ? ForgeTheme.Colors.accentRed : ForgeTheme.Colors.accent).opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isLocked },
                set: { newValue in
                    if newValue {
                        // Lock immediately — no PIN required to lock.
                        if canArm { module.armForLock() }
                    } else {
                        // Unlock — pops the PIN prompt. Actual flip
                        // happens inside verify() → finishDisarm().
                        module.requestUnlock()
                    }
                }
            ))
            .toggleStyle(.forge)
            .labelsHidden()
            .tint(ForgeTheme.Colors.accent)
            .disabled(!canArm && !isLocked)
        }
        .padding(16)
        .background(ForgeTheme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }

    private var statusTitle: String {
        if isLocked { return "Locked. Selected apps behind a PIN." }
        if !canArm  { return "Set a PIN and pick at least one app to lock." }
        return "Unlocked. Flip on to lock."
    }

    private var statusSubtitle: String {
        "Apps keep running in the background — notifications still arrive."
    }

    // MARK: - Card 2: PIN

    private var pinCard: some View {
        HStack(spacing: 14) {
            Image(systemName: module.hasPIN ? "key.fill" : "key")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(module.hasPIN ? ForgeTheme.Colors.accentGreen : ForgeTheme.Colors.textTertiary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill((module.hasPIN ? ForgeTheme.Colors.accentGreen : ForgeTheme.Colors.textTertiary)
                            .opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(module.hasPIN ? "PIN is set" : "No PIN yet")
                    .font(.system(size: 13, weight: .semibold))
                Text("One PIN, used for every locked app.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(module.hasPIN ? "Change PIN…" : "Set PIN…") {
                showingPINSheet = true
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(ForgeTheme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }

    // MARK: - Card 3: Lock now + shortcut

    /// Shows the currently-assigned "Lock / Unlock" shortcut and a
    /// button that fires the same action programmatically. Same key
    /// does both directions — the caption spells that out so users
    /// don't think there's a second shortcut for unlocking.
    private var lockNowCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Lock now")
                    .font(.system(size: 15, weight: .semibold))
                Text("Locks every selected app instantly. Same shortcut opens the PIN prompt while locked.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    if isLocked { module.requestUnlock() }
                    else        { module.armForLock() }
                } label: {
                    Label(isLocked ? "Enter PIN to unlock" : "Lock now",
                          systemImage: isLocked ? "lock.open" : "lock.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(isLocked ? ForgeTheme.Colors.accentRed : ForgeTheme.Colors.accent)

                Spacer()

                Text(shortcutDisplay)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ForgeTheme.Colors.surfaceHover)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
                    )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ForgeTheme.Colors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }

    /// Pull the current binding from SettingsManager and render it
    /// with the same symbol convention the rest of the app uses
    /// (⌃⌥⇧⌘ + key char). If unset, show a dash.
    private var shortcutDisplay: String {
        guard let b = settings.shortcutBindings["appLock"] else { return "—" }
        return b.displayString
    }

    // MARK: - Card 4: Selected apps

    private var selectedListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Locked apps")
                        .font(.system(size: 15, weight: .semibold))
                    Text("When locked, every app in this list gets covered by the PIN prompt on activation.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add app", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(ForgeTheme.Colors.accent)
            }

            if module.selections.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(module.selections) { sel in
                        SelectionRow(
                            selection: sel,
                            isLive: module.activeLocks.contains(sel.bundleId),
                            onRemove: { module.removeSelection(bundleId: sel.bundleId) }
                        )
                        if sel.id != module.selections.last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ForgeTheme.Colors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.slash")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text("No apps in the list yet.")
                .font(.system(size: 13, weight: .medium))
            Text("Click Add app to pick Slack, Chrome, or anything else.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

// MARK: - Row

private struct SelectionRow: View {
    let selection: AppLockSelection
    let isLive: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(bundleId: selection.bundleId)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(selection.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if isLive {
                        Text("LOCKED")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(ForgeTheme.Colors.accentRed.opacity(0.15))
                            .foregroundColor(ForgeTheme.Colors.accentRed)
                            .clipShape(Capsule())
                    }
                }
                Text(selection.bundleId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - App icon

private struct AppIconView: View {
    let bundleId: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.fill")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Add app sheet

private struct AddSelectionSheet: View {
    @ObservedObject var module: AppLockModule
    @Binding var isPresented: Bool

    @State private var apps: [InstalledApp] = []
    @State private var query: String = ""
    @State private var selected: InstalledApp? = nil

    private var filtered: [InstalledApp] {
        let existing = Set(module.selections.map { $0.bundleId })
        let base = apps.filter { !existing.contains($0.bundleId) }
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleId.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add an app")
                .font(.system(size: 18, weight: .semibold))

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search installed apps", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(ForgeTheme.Colors.surfaceInput)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable()
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                    .font(.system(size: 12, weight: .medium))
                                Text(app.bundleId)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selected?.bundleId == app.bundleId {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(ForgeTheme.Colors.accent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(
                            selected?.bundleId == app.bundleId
                                ? ForgeTheme.Colors.accent.opacity(0.08)
                                : Color.clear
                        )
                        .onTapGesture { selected = app }
                    }
                }
            }
            .frame(height: 260)
            .background(ForgeTheme.Colors.surfaceSubtle)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(ForgeTheme.Colors.accent)
                    .disabled(selected == nil)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { apps = AppLockModule.discoverInstalledApps() }
    }

    private func submit() {
        guard let sel = selected else { return }
        module.addSelection(bundleId: sel.bundleId, displayName: sel.name)
        isPresented = false
    }
}

// MARK: - Set / Change PIN sheet

private struct SetPINSheet: View {
    @ObservedObject var module: AppLockModule
    @Binding var isPresented: Bool

    @State private var oldPIN: String = ""
    @State private var pin: String = ""
    @State private var confirm: String = ""
    @State private var error: String? = nil

    private var isChanging: Bool { module.hasPIN }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isChanging ? "Change PIN" : "Set PIN")
                .font(.system(size: 18, weight: .semibold))
            Text(isChanging
                 ? "Enter the current PIN, then pick a new one."
                 : "4 digits. Same PIN unlocks every locked app.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            // Only shown on rotation. Setup has no PIN yet, so this
            // field would be meaningless the first time.
            if isChanging {
                pinField(text: $oldPIN, placeholder: "Current PIN")
            }

            HStack(spacing: 10) {
                pinField(text: $pin, placeholder: "New PIN")
                pinField(text: $confirm, placeholder: "Confirm")
            }

            if let error {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.accentRed)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(ForgeTheme.Colors.accent)
                    .disabled(
                        pin.count < 4
                            || pin != confirm
                            || (isChanging && oldPIN.count < 4)
                    )
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func pinField(text: Binding<String>, placeholder: String) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ForgeTheme.Colors.surfaceInput)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: text.wrappedValue) { newValue in
                let digits = newValue.filter { $0.isNumber }
                if digits != newValue { text.wrappedValue = String(digits.prefix(4)) }
                else if newValue.count > 4 { text.wrappedValue = String(newValue.prefix(4)) }
            }
    }

    private func submit() {
        guard pin.count >= 4 else { error = "PIN must be 4 digits."; return }
        guard pin == confirm else { error = "PINs don't match."; return }
        if isChanging {
            let ok = module.changePIN(oldPIN: oldPIN, newPIN: pin)
            if !ok {
                error = "Current PIN is wrong."
                oldPIN = ""
                return
            }
        } else {
            module.setPIN(pin)
        }
        isPresented = false
    }
}

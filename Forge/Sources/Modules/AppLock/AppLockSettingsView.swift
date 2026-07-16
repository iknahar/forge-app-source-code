import SwiftUI
import AppKit

/// Settings → App Lock. Cards, top to bottom:
///
///   1. Lock status — mirrors the "Lock selected apps?" icon button
///      in the Tools popover. Toggle-on locks immediately;
///      toggle-off pops the biometric prompt.
///   2. Lock now + shortcut — instant lock button + keyboard
///      shortcut (⌘L by default).
///   3. Selected apps — the list the arm switch acts on.
///
/// The entire section sits behind a session-lifetime biometric gate:
/// modifying anything here (add app, remove app, arm state) needs
/// Touch ID / password once per Forge run.
struct AppLockSettingsView: View {
    @ObservedObject var module: AppLockModule
    @EnvironmentObject var moduleRegistry: ModuleRegistry
    @EnvironmentObject var settings: SettingsManager

    @State private var showingAddSheet = false

    var body: some View {
        Group {
            if !module.settingsSessionUnlocked {
                SettingsGate(module: module)
            } else {
                settingsBody
            }
        }
    }

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 24) {
            lockStatusCard
            lockNowCard
                .disabled(module.selections.isEmpty)
                .opacity(module.selections.isEmpty ? 0.55 : 1)
            selectedListCard
        }
        .sheet(isPresented: $showingAddSheet) {
            AddSelectionSheet(module: module, isPresented: $showingAddSheet)
        }
    }

    private var isLocked: Bool { moduleRegistry.isEnabled(module.id) }

    private var canArm: Bool { !module.selections.isEmpty }

    // MARK: - Card 1: Lock status

    /// Turning ON locks instantly. Turning OFF pops the biometric
    /// prompt — the toggle only flips after successful auth
    /// (handled inside `module.requestUnlock`).
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
                        if canArm { module.armForLock() }
                    } else {
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
        if isLocked { return "Locked. Selected apps behind Touch ID." }
        if !canArm  { return "Pick at least one app to lock." }
        return "Unlocked. Flip on to lock."
    }

    private var statusSubtitle: String {
        "Apps keep running in the background — notifications still arrive."
    }

    // MARK: - Card 2: Lock now + shortcut

    private var lockNowCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Lock now")
                    .font(.system(size: 15, weight: .semibold))
                Text("Locks every selected app instantly. Same shortcut prompts for Touch ID while locked.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    if isLocked { module.requestUnlock() }
                    else        { module.armForLock() }
                } label: {
                    Label(isLocked ? "Unlock with Touch ID" : "Lock now",
                          systemImage: isLocked ? "touchid" : "lock.fill")
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

    private var shortcutDisplay: String {
        guard let b = settings.shortcutBindings["appLock"] else { return "—" }
        return b.displayString
    }

    // MARK: - Card 3: Selected apps

    private var selectedListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Locked apps")
                        .font(.system(size: 15, weight: .semibold))
                    Text("When locked, every app in this list gets covered by the Touch ID prompt on activation.")
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

// MARK: - Settings gate

/// Biometric-only gate at the top of the App Lock settings page.
/// Blocks the arm toggle + selection list until the user proves
/// ownership via Touch ID (or macOS password fallback on Macs
/// without biometrics). Success flips a session-lifetime flag on
/// the module — no re-prompting for the rest of this Forge run.
private struct SettingsGate: View {
    @ObservedObject var module: AppLockModule

    @State private var lastAttemptFailed: Bool = false
    @State private var shake: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.accent)
                .padding(.top, 6)

            Text("Authenticate to modify App Lock")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.textPrimary)
            Text("Every change here — adding apps, removing apps, arming the lock — needs Touch ID first.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            fingerprintButton
                .modifier(GateShake(shake: shake))

            if lastAttemptFailed {
                Text("Tap to try again")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(ForgeTheme.Colors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
        .onAppear { runAuth() }
    }

    private var fingerprintButton: some View {
        Button(action: runAuth) {
            Image(systemName: "touchid")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.accent)
                .frame(width: 60, height: 60)
                .background(Circle().fill(ForgeTheme.Colors.accent.opacity(0.12)))
                .overlay(Circle().stroke(ForgeTheme.Colors.accent.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Tap for Touch ID")
    }

    private func runAuth() {
        module.authenticate(reason: "Modify App Lock settings") { ok in
            if ok {
                module.settingsSessionUnlocked = true
            } else {
                withAnimation(.default) { shake.toggle() }
                lastAttemptFailed = true
            }
        }
    }
}

private struct GateShake: GeometryEffect {
    var amount: CGFloat = 6
    var shakesPerUnit = CGFloat(3)
    var animatableData: CGFloat

    init(shake: Bool) { self.animatableData = shake ? 1 : 0 }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = amount * sin(animatableData * .pi * shakesPerUnit * 2)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
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

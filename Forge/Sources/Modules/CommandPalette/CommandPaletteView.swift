import SwiftUI

/// The Command Palette window — a centered, floating search bar.
/// 680px wide, vibrancy material, single 56pt input field.
/// Matches Dot's command bar aesthetic: clean, immediate, keyboard-first.
struct CommandPaletteView: View {
    @EnvironmentObject var moduleRegistry: ModuleRegistry
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    let onDismiss: () -> Void

    private var filteredCommands: [ForgeCommand] {
        let allCommands = moduleRegistry.allCommands()
        if searchText.isEmpty {
            return allCommands
        }
        return FuzzySearch.filter(commands: allCommands, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search input (56pt tall, matches Dot's command bar)
            searchField

            if !filteredCommands.isEmpty {
                Rectangle()
                    .fill(ForgeTheme.Colors.borderSubtle)
                    .frame(height: 1)

                // Results list
                resultsList

                Rectangle()
                    .fill(ForgeTheme.Colors.borderSubtle)
                    .frame(height: 1)

                // Footer with keyboard hints
                footerHints
            }
        }
        .frame(width: ForgeTheme.Layout.commandBarWidth)
        .background(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.large)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: ForgeTheme.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.large)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
        .forgeShadowPopup()
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: ForgeTheme.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(ForgeTheme.Colors.textMuted)

            TextField("Type a command, search, or calculate...", text: $searchText)
                .font(ForgeTheme.Typography.commandBarInput)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit {
                    executeSelected()
                }
                .onChange(of: searchText) { _ in
                    selectedIndex = 0
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(ForgeTheme.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Group by module
                    let grouped = Dictionary(grouping: filteredCommands) { $0.moduleId }

                    ForEach(Array(grouped.keys.sorted()), id: \.self) { moduleId in
                        if let commands = grouped[moduleId], !commands.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                // Section label (matches Dot's uppercase tracking)
                                Text(moduleName(for: moduleId).uppercased())
                                    .font(ForgeTheme.Typography.sectionLabel)
                                    .foregroundColor(ForgeTheme.Colors.textMuted)
                                    .tracking(1.5)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)

                                ForEach(commands) { command in
                                    let index = filteredCommands.firstIndex(where: { $0.id == command.id }) ?? 0
                                    commandRow(command, isSelected: index == selectedIndex)
                                        .id(command.id)
                                        .onTapGesture {
                                            command.action()
                                            onDismiss()
                                        }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, ForgeTheme.Spacing.xs)
            }
            .frame(maxHeight: 320)
            .onChange(of: selectedIndex) { newIndex in
                if newIndex < filteredCommands.count {
                    proxy.scrollTo(filteredCommands[newIndex].id, anchor: .center)
                }
            }
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredCommands.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private func commandRow(_ command: ForgeCommand, isSelected: Bool) -> some View {
        HStack(spacing: ForgeTheme.Spacing.md) {
            Image(systemName: command.iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isSelected ? ForgeTheme.Colors.accent : ForgeTheme.Colors.textTertiary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)

                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(ForgeTheme.Colors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isSelected {
                Text("↵")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(ForgeTheme.Colors.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(ForgeTheme.Colors.border)
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? ForgeTheme.Colors.surfaceHover
                : Color.clear
        )
        .cornerRadius(ForgeTheme.Radius.medium)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Footer Hints (matches Dot's command bar footer)

    private var footerHints: some View {
        HStack(spacing: ForgeTheme.Spacing.lg) {
            shortcutHint(keys: "↑↓", label: "Navigate")
            shortcutHint(keys: "↵", label: "Run")
            shortcutHint(keys: "esc", label: "Close")

            Spacer()

            Text("\(filteredCommands.count) commands")
                .font(.system(size: 11))
                .foregroundColor(ForgeTheme.Colors.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(ForgeTheme.Colors.pageBgWarm)
    }

    private func shortcutHint(keys: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(ForgeTheme.Colors.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(ForgeTheme.Colors.surfaceInput)
                .cornerRadius(ForgeTheme.Radius.xs)
                .overlay(
                    RoundedRectangle(cornerRadius: ForgeTheme.Radius.xs)
                        .stroke(ForgeTheme.Colors.border, lineWidth: 0.5)
                )

            Text(label)
                .font(.system(size: 11))
                .foregroundColor(ForgeTheme.Colors.textMuted)
        }
    }

    // MARK: - Helpers

    private func executeSelected() {
        guard selectedIndex < filteredCommands.count else { return }
        filteredCommands[selectedIndex].action()
        onDismiss()
    }

    private func moduleName(for id: String) -> String {
        moduleRegistry.module(withId: id)?.name ?? id
    }
}

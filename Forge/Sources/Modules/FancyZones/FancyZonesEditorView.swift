import SwiftUI
import AppKit

/// PowerToys-style FancyZones editor — a gallery of six template
/// cards, each clickable to make it the active layout and each
/// with a pencil to open a per-template edit sheet (zone count,
/// space around, highlight distance). Re-skinned to Forge's
/// theme so the cards / sliders / buttons match the rest of the app.
///
/// Behavior contract:
///   • Tap a card → that template becomes the active drag-snap
///     target. The active card gets the red accent border + tint.
///   • Tap the pencil on a card → opens `TemplateEditSheet` for
///     that template. Save persists; Cancel discards.
///   • "No layout" disables drag-snap (overlay refuses to show).
struct FancyZonesEditorView: View {
    @ObservedObject var module: FancyZonesModule
    let onClose: () -> Void

    @State private var editingTemplate: ZoneTemplate?
    /// Refresh stamp so the editor re-reads `module.customLayouts`
    /// after the splitter saves. `@ObservedObject` already publishes
    /// changes, but the splitter runs on a side-window so we also
    /// nudge state explicitly to be safe.
    @State private var customRevision: Int = 0
    /// Monitor selected in the top strip. Purely informational —
    /// configuration is still global with per-orientation defaults.
    @State private var selectedScreen: NSScreen? = NSScreen.main

    /// Templates in the order PowerToys uses — the user's reference.
    private let templates: [ZoneTemplate] = [
        .none, .focus, .columns, .rows, .grid, .priorityGrid
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            monitorStrip
            Divider().opacity(0.2)
            galleryScroll
            Divider().opacity(0.2)
            footer
        }
        .frame(width: 800, height: 640)
        .background(ForgeTheme.Colors.surfaceCard)
        .sheet(item: $editingTemplate) { template in
            TemplateEditSheet(
                template: template,
                initial: module.config(for: template),
                onSave: { config in
                    module.updateConfig(for: template, config)
                    // Activating the just-edited template makes the
                    // change immediately visible on the next drag-snap.
                    module.activateTemplate(template)
                    editingTemplate = nil
                },
                onCancel: { editingTemplate = nil }
            )
        }
    }

    // MARK: - Monitor strip
    //
    // Mirrors PowerToys' FancyZones top bar — even with a single
    // display we show the strip so the user has a clear visual map of
    // which monitor they're configuring layouts for. Layouts on
    // Forge are global today (with optional per-orientation defaults
    // wired through `configForScreen`), so this strip is informational
    // — picking a monitor doesn't gate anything yet.

    private var monitorStrip: some View {
        let screens = NSScreen.screens
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(screens.enumerated()), id: \.offset) { idx, screen in
                    monitorCard(index: idx + 1, screen: screen,
                                isSelected: selectedScreen == screen
                                            || (selectedScreen == nil && idx == 0))
                        .onTapGesture { selectedScreen = screen }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(ForgeTheme.Colors.surfaceSubtle)
    }

    private func monitorCard(index: Int, screen: NSScreen, isSelected: Bool) -> some View {
        let frame = screen.frame
        let isVertical = frame.height > frame.width
        return VStack(spacing: 6) {
            Text("\(index)")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(ForgeTheme.Colors.textPrimary)
            Text("\(Int(frame.width)) × \(Int(frame.height))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(ForgeTheme.Colors.textSecondary)
            Text(isVertical ? "Vertical" : "Horizontal")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(ForgeTheme.Colors.textTertiary)
        }
        .frame(width: 110, height: 78)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected
                      ? ForgeTheme.Colors.accent.opacity(0.10)
                      : ForgeTheme.Colors.surfaceHover.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? ForgeTheme.Colors.accent : ForgeTheme.Colors.borderDefault,
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .contentShape(Rectangle())
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FancyZones")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                Text("Pick a layout, then hold Shift while dragging any window to snap into a zone.")
                    .font(.system(size: 12))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(ForgeTheme.Colors.surfaceHover))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Gallery

    private var galleryScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Templates — the six PowerToys-style built-ins.
                VStack(alignment: .leading, spacing: 14) {
                    Text("TEMPLATES")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                        spacing: 14
                    ) {
                        ForEach(templates, id: \.self) { template in
                            templateCard(template)
                        }
                    }
                }

                // Custom — user-drawn layouts. The "Create new layout"
                // tile is always shown last so it's discoverable
                // whether or not the user has any custom layouts yet.
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("CUSTOM")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.7)
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                        Spacer()
                        if !module.customLayouts.isEmpty {
                            Text("\(module.customLayouts.count) layout\(module.customLayouts.count == 1 ? "" : "s")")
                                .font(.system(size: 10))
                                .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.7))
                        }
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                        spacing: 14
                    ) {
                        ForEach(module.customLayouts) { custom in
                            customCard(custom)
                        }
                        // Always-visible "+ Create new layout" tile.
                        createLayoutTile
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .id(customRevision)  // forces re-render after splitter save
        }
    }

    // MARK: - Custom layout cards

    @ViewBuilder
    private func customCard(_ layout: CustomLayout) -> some View {
        let isActive: Bool = {
            if case .custom(let id) = module.activeLayoutRef { return id == layout.id }
            return false
        }()

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(layout.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(ForgeTheme.Colors.accent))
                }
                Menu {
                    Button("Edit Layout") { editCustomLayout(layout) }
                    Button("Activate")    { module.activateCustomLayout(layout.id) }
                    Divider()
                    Button("Delete", role: .destructive) {
                        module.deleteCustomLayout(layout.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(ForgeTheme.Colors.surfaceHover))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            ZoneMiniPreview(
                zones: layout.zones,
                isActive: isActive,
                spaceAround: CGFloat(layout.spaceAroundEnabled ? layout.spaceAroundPixels : 0)
            )
            .frame(height: 88)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive
                      ? ForgeTheme.Colors.accent.opacity(0.08)
                      : ForgeTheme.Colors.surfaceHover.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isActive ? ForgeTheme.Colors.accent : ForgeTheme.Colors.borderDefault,
                    lineWidth: isActive ? 1.5 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            module.activateCustomLayout(layout.id)
        }
    }

    /// Always-present tile that launches the splitter overlay.
    private var createLayoutTile: some View {
        Button { openSplitter() } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.accent)
                Text("Create new layout")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                Text("Click + drag splits to carve up the screen")
                    .font(.system(size: 10))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ForgeTheme.Colors.surfaceHover.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        ForgeTheme.Colors.accent.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.2, dash: [5])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func openSplitter(editing existing: CustomLayout? = nil) {
        CustomLayoutBuilder.open(
            editing: existing,
            onSave: { layout in
                if existing != nil {
                    module.updateCustomLayout(layout)
                    module.activateCustomLayout(layout.id)
                } else {
                    module.addCustomLayout(layout)
                }
                customRevision &+= 1
            },
            onCancel: {}
        )
    }

    private func editCustomLayout(_ layout: CustomLayout) {
        openSplitter(editing: layout)
    }

    /// Footer label — shows whichever layout is active, template or
    /// custom. Falls back to "Columns" if state is corrupt.
    private var activeLayoutName: String {
        switch module.activeLayoutRef {
        case .template(let t):
            return t.displayName
        case .custom(let id):
            return module.customLayouts.first(where: { $0.id == id })?.name ?? "Custom"
        }
    }

    @ViewBuilder
    private func templateCard(_ template: ZoneTemplate) -> some View {
        let isActive = module.activeTemplate == template
        let config = module.config(for: template)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(template.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                Spacer()
                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(ForgeTheme.Colors.accent))
                }
                if template != .none {
                    Button {
                        editingTemplate = template
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundColor(ForgeTheme.Colors.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(ForgeTheme.Colors.surfaceHover))
                    }
                    .buttonStyle(.plain)
                    .help("Edit \(template.displayName)")
                }
            }
            ZoneMiniPreview(
                zones: config.zones,
                isActive: isActive,
                spaceAround: CGFloat(config.spaceAroundEnabled ? config.spaceAroundPixels : 0)
            )
            .frame(height: 88)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive
                      ? ForgeTheme.Colors.accent.opacity(0.08)
                      : ForgeTheme.Colors.surfaceHover.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isActive
                        ? ForgeTheme.Colors.accent
                        : ForgeTheme.Colors.borderDefault,
                    lineWidth: isActive ? 1.5 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            module.activateTemplate(template)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                Text("Active: \(activeLayoutName) · \(module.activeConfig.zones.count) zone\(module.activeConfig.zones.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Text("Done")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Capsule().fill(ForgeTheme.Colors.accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(ForgeTheme.Colors.surfaceSubtle)
    }
}

// MARK: - Mini preview

/// Renders a layout's zones as small rounded rectangles inside a
/// proxied screen frame. Used both inside template cards and in the
/// per-template edit sheet so the user can see the layout update in
/// real time as they adjust sliders.
struct ZoneMiniPreview: View {
    let zones: [ZoneDefinition]
    let isActive: Bool
    /// Padding (in screen points) between zones — drawn here as a
    /// proportional inset so the user can preview the effect of the
    /// "Space around zones" slider.
    let spaceAround: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ForgeTheme.Colors.surfaceCard.opacity(0.35))
                if zones.isEmpty {
                    Text("No layout")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(ForgeTheme.Colors.textSecondary.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(zones) { zone in
                        zoneRect(zone, in: geo.size)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func zoneRect(_ zone: ZoneDefinition, in size: CGSize) -> some View {
        // Proxy "space around" to a small visual inset so the preview
        // reads like a scaled-down screen view. We scale relative to
        // the assumed full-screen width — close enough for an inset
        // preview without computing real screen geometry.
        let pad = max(1, spaceAround * (size.width / 1440))
        let frame = CGRect(
            x: zone.rect.origin.x * size.width + pad,
            y: zone.rect.origin.y * size.height + pad,
            width: zone.rect.width * size.width - pad * 2,
            height: zone.rect.height * size.height - pad * 2
        )

        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isActive
                  ? ForgeTheme.Colors.accent.opacity(0.20)
                  : ForgeTheme.Colors.textSecondary.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? ForgeTheme.Colors.accent.opacity(0.55)
                            : ForgeTheme.Colors.borderDefault,
                        lineWidth: 1
                    )
            )
            .frame(width: max(0, frame.width), height: max(0, frame.height))
            .offset(x: frame.origin.x, y: frame.origin.y)
    }
}

// MARK: - Per-template edit sheet

/// Sliders to tune a template's zone count, padding, and highlight
/// distance. Live-previews the result so the user sees their tweaks
/// apply immediately.
struct TemplateEditSheet: View {
    let template: ZoneTemplate
    @State private var config: ZoneLayoutConfig
    let onSave: (ZoneLayoutConfig) -> Void
    let onCancel: () -> Void

    init(template: ZoneTemplate,
         initial: ZoneLayoutConfig,
         onSave: @escaping (ZoneLayoutConfig) -> Void,
         onCancel: @escaping () -> Void) {
        self.template = template
        _config = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit '\(template.displayName)'")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                Spacer()
            }

            // Live preview of the current params
            ZoneMiniPreview(
                zones: config.zones,
                isActive: true,
                spaceAround: CGFloat(config.spaceAroundEnabled ? config.spaceAroundPixels : 0)
            )
            .frame(height: 110)

            if template.supportsZoneCount {
                sliderRow(
                    icon: "rectangle.split.3x1",
                    label: "Number of zones",
                    valueLabel: "\(config.zoneCount) zones"
                ) {
                    Slider(
                        value: Binding(
                            get: { Double(config.zoneCount) },
                            set: {
                                config.zoneCount = Int($0)
                                config.regenerateZones()
                            }
                        ),
                        in: 1...8,
                        step: 1
                    )
                    .tint(ForgeTheme.Colors.accent)
                }
            }

            sliderRow(
                icon: "rectangle.inset.fill",
                label: "Space around zones",
                valueLabel: config.spaceAroundEnabled ? "\(config.spaceAroundPixels) px" : "Off",
                trailing: {
                    Toggle("", isOn: $config.spaceAroundEnabled)
                        .toggleStyle(.forge)
                        .labelsHidden()
                }
            ) {
                Slider(
                    value: Binding(
                        get: { Double(config.spaceAroundPixels) },
                        set: { config.spaceAroundPixels = Int($0) }
                    ),
                    in: 0...32,
                    step: 1
                )
                .tint(ForgeTheme.Colors.accent)
                .disabled(!config.spaceAroundEnabled)
                .opacity(config.spaceAroundEnabled ? 1 : 0.45)
            }

            sliderRow(
                icon: "scope",
                label: "Highlight distance",
                valueLabel: "\(config.highlightDistance) px"
            ) {
                Slider(
                    value: Binding(
                        get: { Double(config.highlightDistance) },
                        set: { config.highlightDistance = Int($0) }
                    ),
                    in: 0...50,
                    step: 1
                )
                .tint(ForgeTheme.Colors.accent)
            }

            // PowerToys-style "default for orientation" stars. Stored
            // for future multi-monitor work; the snap path doesn't
            // currently differentiate orientation.
            HStack(spacing: 18) {
                defaultStarButton(
                    on: $config.defaultHorizontal,
                    label: "Default for horizontal monitor"
                )
                defaultStarButton(
                    on: $config.defaultVertical,
                    label: "Default for vertical monitor"
                )
            }
            .padding(.top, 4)

            HStack {
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ForgeTheme.Colors.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    onSave(config)
                } label: {
                    Text("Save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Capsule().fill(ForgeTheme.Colors.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(ForgeTheme.Colors.surfaceCard)
    }

    @ViewBuilder
    private func sliderRow<Trailing: View>(
        icon: String,
        label: String,
        valueLabel: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                Spacer()
                Text(valueLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
                trailing()
            }
            content()
                .padding(.leading, 24)
        }
    }

    private func defaultStarButton(on: Binding<Bool>, label: String) -> some View {
        Button {
            on.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on.wrappedValue ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundColor(on.wrappedValue ? ForgeTheme.Colors.accent : ForgeTheme.Colors.textSecondary)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(ForgeTheme.Colors.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}

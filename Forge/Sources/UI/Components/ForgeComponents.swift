import SwiftUI

// MARK: - Keyboard Shortcut Tag (pixel-perfect match of Dot's .kbd)
// Dot CSS: linear-gradient(#fff, #f5f5f4), border: 1px solid #e7e5e4,
// border-radius: 8px, min-width: 28px, height: 28px, font-size: 14px,
// shadow: 0 1px #d6d3d1, 0 2px 4px rgba(0,0,0,0.04), inset 0 0 0 1px rgba(255,255,255,0.8)

struct KeyboardShortcutTag: View {
    let keys: String
    var size: KbdSize = .regular

    enum KbdSize {
        case small   // 11px font, 22px height — for footer hints
        case regular // 14px font, 28px height — standard
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(keys), id: \.self) { key in
                Text(String(key))
                    .font(size == .small
                          ? ForgeTheme.Typography.kbdSmall
                          : ForgeTheme.Typography.kbdFont)
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                    .frame(minWidth: size == .small ? 20 : ForgeTheme.Layout.kbdMinWidth,
                           minHeight: size == .small ? 22 : ForgeTheme.Layout.kbdHeight)
                    .background(ForgeTheme.Gradients.kbdKey)
                    .cornerRadius(ForgeTheme.Radius.medium)
                    .overlay(
                        RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium)
                            .stroke(ForgeTheme.Colors.border, lineWidth: 1)
                    )
                    .overlay(
                        // Inner white inset glow (Dot: inset 0 0 0 1px rgba(255,255,255,0.8))
                        RoundedRectangle(cornerRadius: ForgeTheme.Radius.medium - 1)
                            .stroke(Color.white.opacity(0.8), lineWidth: 1)
                            .padding(1)
                    )
                    // Bottom edge shadow (Dot: 0 1px #d6d3d1)
                    .shadow(color: ForgeTheme.Colors.borderHard, radius: 0, y: 1)
                    // Soft outer shadow (Dot: 0 2px 4px rgba(0,0,0,0.04))
                    .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
            }
        }
    }
}

// MARK: - Forge Button (matches Dot's CTA gradient button with layered shadows)
// Dot CSS: linear-gradient(#3D3835, #1C1917), rounded-2xl (16px),
// shadow: rgb(10,10,10) 0 1px 0, rgba(0,0,0,0.2) 0 2px 4px, inset rgba(255,255,255,0.1) 0 1px 0
// Hover: opacity 0.92, Active: scale(0.98) translateY(1px)

struct ForgeButton: View {
    let title: String
    let iconName: String?
    let style: ButtonStyle
    let action: () -> Void

    enum ButtonStyle {
        case primary    // Dark gradient with layered shadow
        case secondary  // Transparent with dark text
        case ghost      // Subtle hover bg
        case join       // Semi-transparent black (meeting join)
        case pill       // Pill toggle (active/inactive)
    }

    @State private var isHovering = false
    @State private var isPressed = false

    init(_ title: String, icon: String? = nil, style: ButtonStyle = .primary, action: @escaping () -> Void) {
        self.title = title
        self.iconName = icon
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let iconName {
                    Image(systemName: iconName)
                        .font(.system(size: style == .primary ? 13 : 12, weight: .medium))
                }
                Text(title)
                    .font(.system(size: fontSize, weight: .semibold))
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .foregroundColor(foregroundColor)
            .background(background)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            // Dot's button shadow layers
            .shadow(color: primaryShadowColor, radius: 0, y: style == .primary ? 1 : 0)
            .shadow(color: secondaryShadowColor, radius: style == .primary ? 4 : 0, y: 2)
            // Dot's press effect: scale(0.98) translateY(1px)
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .offset(y: isPressed ? 1 : 0)
            .opacity(isHovering ? 0.92 : 1.0)
            .animation(ForgeTheme.Animation.press, value: isPressed)
            .animation(ForgeTheme.Animation.press, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
    }

    private var fontSize: CGFloat {
        switch style {
        case .primary: return 15
        case .join: return 12
        default: return 13
        }
    }

    private var horizontalPadding: CGFloat {
        switch style {
        case .primary: return 24  // Dot: px-6
        case .join: return 12
        case .pill: return 12
        default: return 16
        }
    }

    private var verticalPadding: CGFloat {
        switch style {
        case .primary: return 12  // Dot: py-3
        case .join: return 6
        case .pill: return 5
        default: return 8
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary: return .white
        case .secondary: return ForgeTheme.Colors.textPrimary
        case .ghost: return ForgeTheme.Colors.textSecondary
        case .join: return ForgeTheme.Colors.textPrimary
        case .pill: return ForgeTheme.Colors.textPrimary
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            ForgeTheme.Gradients.darkButton
        case .secondary:
            Color.clear
        case .ghost:
            ForgeTheme.Colors.hoverBg
        case .join:
            ForgeTheme.Colors.joinButtonBg
        case .pill:
            ForgeTheme.Colors.surfaceSubtle
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary: return .clear
        case .join: return ForgeTheme.Colors.borderStrong
        case .pill: return ForgeTheme.Colors.border
        default: return .clear
        }
    }

    private var borderWidth: CGFloat {
        switch style {
        case .join, .pill: return 1
        default: return 0
        }
    }

    private var cornerRadius: CGFloat {
        switch style {
        case .primary: return ForgeTheme.Radius.xl    // Dot: rounded-2xl (16px)
        case .join: return ForgeTheme.Radius.small
        case .pill: return ForgeTheme.Radius.full
        default: return ForgeTheme.Radius.medium
        }
    }

    // Dot: rgb(10,10,10) 0 1px 0
    private var primaryShadowColor: Color {
        style == .primary ? Color(hex: "#0A0A0A") : .clear
    }

    // Dot: rgba(0,0,0,0.2) 0 2px 4px
    private var secondaryShadowColor: Color {
        style == .primary ? Color.black.opacity(0.2) : .clear
    }
}

// MARK: - Toggle Pill (Dot's tab/feature toggle)
// Active: bg-[#1C1917] text-white border-[#1C1917]
// Inactive: bg-[#F5F3EE] text-[#A8A29E] border-[#E7E5E4] hover:border-[#A8A29E]

struct ForgeTogglePill: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ForgeTheme.Typography.pillFont)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(isActive ? .white : ForgeTheme.Colors.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isActive ? ForgeTheme.Colors.surfaceDark : ForgeTheme.Colors.surfaceSubtle)
                .cornerRadius(ForgeTheme.Radius.full)
                .overlay(
                    RoundedRectangle(cornerRadius: ForgeTheme.Radius.full)
                        .stroke(
                            isActive
                                ? ForgeTheme.Colors.surfaceDark
                                : (isHovering ? ForgeTheme.Colors.textMuted : ForgeTheme.Colors.border),
                            lineWidth: 1
                        )
                )
                .animation(ForgeTheme.Animation.smooth, value: isActive)
                .animation(ForgeTheme.Animation.smooth, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
    }
}

// MARK: - Forge Card (Dot's card: --surface bg, --border, card shadow)

struct ForgeCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(ForgeTheme.Colors.surfaceCard)
            .cornerRadius(ForgeTheme.Radius.xl)
            .overlay(
                RoundedRectangle(cornerRadius: ForgeTheme.Radius.xl)
                    .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
            )
            .forgeShadowCard()
    }
}

// MARK: - Section Header (Dot's uppercase tracking-wide labels)

struct ForgeSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(ForgeTheme.Typography.sectionLabel)
            .foregroundColor(ForgeTheme.Colors.textMuted)
            .tracking(1.5) // Dot: tracking-wide (0.025em ≈ 1.5pt at 10px)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Progress Bar (Dot's day/year progress)

struct ForgeProgressBar: View {
    let value: Double // 0.0 to 1.0
    let height: CGFloat
    let trackColor: Color
    let fillColor: Color

    init(value: Double, height: CGFloat = 3, track: Color = ForgeTheme.Colors.border, fill: Color = ForgeTheme.Colors.textPrimary) {
        self.value = min(max(value, 0), 1)
        self.height = height
        self.trackColor = track
        self.fillColor = fill
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(trackColor)
                    .frame(height: height)

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(fillColor)
                    .frame(width: geo.size.width * value, height: height)
                    .animation(ForgeTheme.Animation.panel, value: value)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Toggle (tinted with brand)

struct ForgeToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .font(ForgeTheme.Typography.bodyFont)
                .foregroundColor(ForgeTheme.Colors.textPrimary)
        }
        .toggleStyle(.forge)
        .tint(ForgeTheme.Colors.accent)
    }
}

// MARK: - Status Indicator (Dot's green online dot with glow)
// Dot: w-1.5 h-1.5 rounded-full bg-[#22C55E] shadow-[0_0_4px_rgba(34,197,94,0.4)]

struct StatusIndicator: View {
    var isOnline: Bool = true
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(isOnline ? ForgeTheme.Colors.statusOnline : ForgeTheme.Colors.textMuted)
            .frame(width: size, height: size)
            .shadow(
                color: isOnline ? ForgeTheme.Colors.statusOnline.opacity(0.4) : .clear,
                radius: 4, y: 0
            )
    }
}

// MARK: - Feature Pill Badge (Dot's pill with icon + label)
// Dot: bg var(--surface), border 1px solid var(--border), rounded-full, gap 6px, p 6px 12px, font-size 13px

struct FeaturePill: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ForgeTheme.Colors.textTertiary)
            Text(label)
                .font(ForgeTheme.Typography.badgeFont)
                .foregroundColor(ForgeTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ForgeTheme.Colors.surfaceCard)
        .cornerRadius(ForgeTheme.Radius.full)
        .overlay(
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.full)
                .stroke(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
    }
}

// MARK: - Meeting Service Icon (Zoom/Meet/Teams/Webex)

struct MeetingServiceIcon: View {
    let service: MeetingService

    enum MeetingService: String, CaseIterable {
        case zoom = "Zoom"
        case meet = "Meet"
        case teams = "Teams"
        case webex = "Webex"

        var iconColor: Color {
            switch self {
            case .zoom: return Color(hex: "#2D8CFF")
            case .meet: return Color(hex: "#00897B")
            case .teams: return Color(hex: "#6264A7")
            case .webex: return Color(hex: "#07C160")
            }
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ForgeTheme.Radius.small)
                .fill(ForgeTheme.Colors.surfaceSubtle)
                .frame(width: 32, height: 32)

            Text(String(service.rawValue.prefix(1)))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(service.iconColor)
        }
    }
}

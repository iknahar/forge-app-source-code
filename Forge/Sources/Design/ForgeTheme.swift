import SwiftUI

/// Forge Design System — pixel-perfect extraction from trydot.app's CSS.
/// Every token maps to Dot's actual CSS custom properties and computed values.
/// Warm Stone palette, DM Sans/Instrument Serif typography (system equivalents on macOS),
/// subtle layered shadows, spring animations.
enum ForgeTheme {

    // MARK: - Colors (from Dot's CSS custom properties)

    enum Colors {
        // Adaptive helper — pairs a light value with a dark counterpart.
        // The NSColor dynamic provider is called whenever the appearance changes,
        // so SwiftUI views using these tokens auto-flip in dark mode.
        private static func dyn(_ light: Color, _ dark: Color) -> Color {
            Color(NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(dark)
                    : NSColor(light)
            }))
        }

        // Backgrounds (--bg, --bg-warm, --surface) — dark variants chosen to keep contrast
        static let pageBg         = dyn(Color(hex: "#FDFBF7"), Color(hex: "#1A1A1B"))
        static let pageBgWarm     = dyn(Color(hex: "#FAF8F3"), Color(hex: "#1F1F20"))
        static let surfaceLight   = dyn(Color(hex: "#FAFAF9"), Color(hex: "#1C1C1D"))
        static let surfaceCard    = dyn(Color.white,           Color(hex: "#242425"))
        static let surfaceHover   = dyn(Color(hex: "#F5F5F4"), Color(hex: "#2A2A2B"))
        static let surfaceSubtle  = dyn(Color(hex: "#F5F3EE"), Color(hex: "#1E1E1F"))
        static let surfaceInput   = dyn(Color(hex: "#F0EDE8"), Color(hex: "#2A2A2B"))
        // "Dark" surface (active toggle pills, today circle, dark sections).
        // Stays DARK in both modes — but bumps lighter in dark mode so it shows
        // against the dark page background. White text reads on both variants.
        static let surfaceDark    = dyn(Color(hex: "#1C1917"), Color(hex: "#3A3A3B"))
        static let surfaceDarkMid = dyn(Color(hex: "#44403C"), Color(hex: "#5A5A5C"))
        static let surfaceElevated = dyn(Color(hex: "#FFFEF9"), Color(hex: "#28282A"))

        // Text — dark variants need higher luminance to actually be READABLE
        // on a #1A1A1B background (which dy was producing). All bumped up.
        static let textPrimary    = dyn(Color(hex: "#1C1917"), Color(hex: "#FAFAF9"))
        static let textSecondary  = dyn(Color(hex: "#57534E"), Color(hex: "#D6D3D1"))
        static let textTertiary   = dyn(Color(hex: "#78716C"), Color(hex: "#B5AFA9"))
        static let textMuted      = dyn(Color(hex: "#A8A29E"), Color(hex: "#9A938E"))
        static let textFaint      = dyn(Color(hex: "#C8C3BD"), Color(hex: "#7B7470"))
        static let textOnDark     = Color.white

        // Brand — Dot's vermillion (#E72903), Forge uses its own orange
        static let brand = Color(hex: "#E72903")               // --brand: Dot's red CTA
        static let brandGlow = Color(hex: "#E72903").opacity(0.15) // --brand-glow
        static let accent = Color(hex: "#E72903")              // Primary accent (matches Dot)
        static let accentBlue = Color(hex: "#3B82F6")          // Calendar events, active tabs
        static let accentGreen = Color(hex: "#22C55E")         // Success, online status
        static let accentGreenDark = Color(hex: "#16A34A")     // Hover green
        static let accentPurple = Color(hex: "#8B5CF6")        // Calendar events
        static let accentRed = Color(hex: "#DC2626")           // Today pulse, error

        // Calendar event colors (from Dot's CSS)
        static let eventBlue = Color(hex: "#3B82F6")
        static let eventBlueDark = Color(hex: "#2563EB")
        static let eventGreen = Color(hex: "#059669")
        static let eventPurple = Color(hex: "#7C3AED")
        static let eventPurpleLight = Color(hex: "#A78BFA")
        static let eventOrange = Color(hex: "#F59E0B")

        // NLP token colors (command bar)
        static let nlpRecurrence = Color(hex: "#7C3AED")
        static let nlpTime = Color(hex: "#2563EB")
        static let nlpDuration = Color(hex: "#059669")

        // Borders & Dividers — inverted opacity values in dark mode so they read
        static let border         = dyn(Color(hex: "#E7E5E4"), Color(hex: "#3A3A3B"))
        static let borderSubtle   = dyn(Color.black.opacity(0.04), Color.white.opacity(0.08))
        static let borderDefault  = dyn(Color.black.opacity(0.08), Color.white.opacity(0.12))
        static let borderStrong   = dyn(Color.black.opacity(0.12), Color.white.opacity(0.18))
        static let borderHard     = dyn(Color(hex: "#D6D3D1"), Color(hex: "#4A4A4B"))

        // Interactive states — same inversion
        static let hoverBg        = dyn(Color.black.opacity(0.05), Color.white.opacity(0.08))
        static let activeBg       = dyn(Color.black.opacity(0.08), Color.white.opacity(0.12))
        static let joinButtonBg   = dyn(Color.black.opacity(0.10), Color.white.opacity(0.12))
        static let joinButtonHover = dyn(Color.black.opacity(0.18), Color.white.opacity(0.18))

        // Meeting
        static let meetingActive = Color(hex: "#00AC47")       // Google Calendar green
        static let meetingZoom = Color(hex: "#2D8CFF")         // Zoom blue

        // macOS traffic lights
        static let trafficClose = Color(hex: "#FF5F57")
        static let trafficMinimize = Color(hex: "#FEBC2E")
        static let trafficMaximize = Color(hex: "#28C840")

        // Status
        static let statusOnline = Color(hex: "#22C55E")
        static let warning = Color(hex: "#F59E0B")

        // Selection
        static let selectionBg = Color(hex: "#E72903")
    }

    // MARK: - Typography (system equivalents of Dot's web fonts)
    // Web: DM Sans (body), Instrument Serif (display), Monsieur La Doulaise (sig)
    // macOS: SF Pro (body), system serif (display), system rounded (badges)

    enum Typography {
        // Display — Instrument Serif equivalent (serif for hero headings)
        static let displayFont: Font = .system(size: 32, weight: .regular, design: .serif)
        static let displayLarge: Font = .system(size: 48, weight: .regular, design: .serif)

        // Headings — DM Sans equivalent (semibold system)
        static let titleFont: Font = .system(size: 24, weight: .semibold)
        static let headingFont: Font = .system(size: 18, weight: .semibold)
        static let subheadingFont: Font = .system(size: 16, weight: .semibold)

        // Body — DM Sans equivalent
        static let bodyFont: Font = .system(size: 14, weight: .regular)
        static let bodyMedium: Font = .system(size: 14, weight: .medium)
        static let captionFont: Font = .system(size: 12, weight: .regular)
        static let captionMedium: Font = .system(size: 12, weight: .medium)
        static let microFont: Font = .system(size: 10, weight: .medium)

        // Mono — Dot uses ui-monospace
        static let monoFont: Font = .system(size: 13, weight: .regular, design: .monospaced)
        static let monoSmall: Font = .system(size: 12, weight: .regular, design: .monospaced)

        // Specific UI sizes (from Dot's CSS)
        static let menuBarTitle: Font = .system(size: 13, weight: .medium)
        static let eventTitle: Font = .system(size: 13, weight: .medium)
        static let eventTime: Font = .system(size: 11, weight: .regular)
        static let calendarDay: Font = .system(size: 13, weight: .semibold)    // Dot: text-[13px] font-semibold
        static let calendarDayHeader: Font = .system(size: 10, weight: .medium)
        static let sectionLabel: Font = .system(size: 10, weight: .semibold)
        static let commandBarInput: Font = .system(size: 18, weight: .regular)

        // Kbd / Shortcut tag (from Dot: font-size 14px, weight 500)
        static let kbdFont: Font = .system(size: 14, weight: .medium)
        static let kbdSmall: Font = .system(size: 11, weight: .medium)
        static let shortcutKey: Font = .system(size: 10, weight: .medium, design: .rounded)

        // Toggle pills (from Dot: font-medium)
        static let pillFont: Font = .system(size: 11, weight: .medium)

        // Feature pill badge (from Dot: 13px)
        static let badgeFont: Font = .system(size: 13, weight: .regular)
    }

    // MARK: - Spacing (4px base unit — Dot's --spacing: 0.25rem)

    enum Spacing {
        static let xxs: CGFloat = 2       // py-0.5
        static let xs: CGFloat = 4        // p-1, gap-1
        static let sm: CGFloat = 8        // p-2, gap-2
        static let smd: CGFloat = 10      // p-2.5
        static let md: CGFloat = 12       // p-3, gap-3
        static let lg: CGFloat = 16       // p-4, gap-4
        static let xl: CGFloat = 24       // p-6, gap-6
        static let xxl: CGFloat = 32      // p-8, gap-8
        static let xxxl: CGFloat = 48     // py-12
    }

    // MARK: - Radius (from Dot's Tailwind classes)

    enum Radius {
        static let xs: CGFloat = 4        // rounded-sm (0.25rem)
        static let small: CGFloat = 6     // rounded-md (0.375rem)
        static let medium: CGFloat = 8    // rounded-lg (0.5rem) — kbd keys
        static let large: CGFloat = 12    // rounded-xl (0.75rem) — cards
        static let xl: CGFloat = 16       // rounded-2xl (1rem) — feature cards, CTA buttons
        static let xxl: CGFloat = 24      // rounded-3xl (1.5rem)
        static let full: CGFloat = 9999   // rounded-full — pills, circles
    }

    // MARK: - Shadows (from Dot's exact CSS box-shadow values)

    enum Shadows {
        // Card: rgba(0,0,0,0.04) 0px 1px 2px, rgba(0,0,0,0.02) 0px 4px 8px
        static let card = ShadowStyle(color: .black.opacity(0.04), radius: 2, y: 1)

        // App window: 0 0 0 1px rgba(0,0,0,0.05), 0 4px 16px rgba(0,0,0,0.1), 0 12px 40px rgba(0,0,0,0.12)
        static let window = ShadowStyle(color: .black.opacity(0.12), radius: 40, y: 12)

        // Floating panel: rgba(0,0,0,0.1) 0px 8px 32px
        static let popup = ShadowStyle(color: .black.opacity(0.1), radius: 32, y: 8)

        // Subtle: shadow-sm equivalent
        static let subtle = ShadowStyle(color: .black.opacity(0.1), radius: 3, y: 1)

        // Kbd key: 0 1px #d6d3d1, 0 2px 4px rgba(0,0,0,0.04)
        static let kbd = ShadowStyle(color: Color(hex: "#D6D3D1"), radius: 0, y: 1)

        // macOS window shadow: 0 24px 48px rgba(0,0,0,0.08)
        static let macosWindow = ShadowStyle(color: .black.opacity(0.08), radius: 48, y: 24)

        // Green glow: 0 0 4px rgba(34,197,94,0.4)
        static let statusGlow = ShadowStyle(color: Color(hex: "#22C55E").opacity(0.4), radius: 4, y: 0)
    }

    struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        let y: CGFloat
    }

    // MARK: - Gradients (from Dot's CSS)

    enum Gradients {
        // Dark button: linear-gradient(rgb(61,56,53) 0%, rgb(28,25,23) 100%)
        static let darkButton = LinearGradient(
            colors: [Color(hex: "#3D3835"), Color(hex: "#1C1917")],
            startPoint: .top,
            endPoint: .bottom
        )

        // Kbd key: linear-gradient(#fff 0%, #f5f5f4 100%)
        static let kbdKey = LinearGradient(
            colors: [.white, Color(hex: "#F5F5F4")],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Animation (from Dot's CSS transitions)

    enum Animation {
        // Default: 0.15s ease
        static let micro: SwiftUI.Animation = .easeOut(duration: 0.15)

        // Colors/opacity: 0.2s-0.3s
        static let smooth: SwiftUI.Animation = .easeInOut(duration: 0.2)
        static let medium: SwiftUI.Animation = .easeInOut(duration: 0.3)

        // Panel spring (Forge custom — snappy)
        static let panel: SwiftUI.Animation = .spring(response: 0.32, dampingFraction: 0.85)

        // Popover spring (slightly softer)
        static let popover: SwiftUI.Animation = .spring(response: 0.42, dampingFraction: 0.85)

        // Page transitions
        static let page: SwiftUI.Animation = .easeInOut(duration: 0.4)

        // Button press: 0.15s
        static let press: SwiftUI.Animation = .easeOut(duration: 0.15)
    }

    // MARK: - Button Shadows (Dot's multi-layer button shadows)

    enum ButtonShadows {
        // Default: rgb(10,10,10) 0px 1px 0px, rgba(0,0,0,0.2) 0px 2px 4px, inset rgba(255,255,255,0.1) 0px 1px 0px
        static let defaultColor = Color(hex: "#0A0A0A")
        static let defaultRadius: CGFloat = 4
        static let defaultY: CGFloat = 2
    }

    // MARK: - Layout (from Dot's CSS max-widths and fixed sizes)

    enum Layout {
        // Popover — compact tight-hug width per latest design pass.
        static let popoverWidth: CGFloat = 295
        static let popoverMinHeight: CGFloat = 400

        // Command bar
        static let commandBarWidth: CGFloat = 680
        static let commandBarMaxHeight: CGFloat = 420

        // Settings
        static let settingsWidth: CGFloat = 880
        static let settingsHeight: CGFloat = 620
        static let settingsSidebarWidth: CGFloat = 220

        // Calendar (from Dot: w-[28px] h-[33px])
        static let calendarCellWidth: CGFloat = 28
        static let calendarCellHeight: CGFloat = 33
        static let calendarCellSize: CGFloat = 28     // Dot: w-[28px]
        static let calendarDayHeaderHeight: CGFloat = 20
        static let eventIndicatorSize: CGFloat = 3    // Dot: w-[3px] h-[3px]
        static let todayCircleSize: CGFloat = 28      // Dark bg circle for today

        // Kbd keys (from Dot: min-width 28px, height 28px)
        static let kbdMinWidth: CGFloat = 28
        static let kbdHeight: CGFloat = 28

        // Module icon
        static let moduleIconSize: CGFloat = 28
    }
}

// MARK: - Color Extension for Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - View Modifiers

extension View {
    /// Apply Dot's card shadow (dual-layer: 0 1px 2px 4%, 0 4px 8px 2%)
    func forgeShadowCard() -> some View {
        self
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.02), radius: 8, y: 4)
    }

    /// Apply Dot's app window shadow (triple-layer)
    func forgeShadowWindow() -> some View {
        self
            .shadow(color: .black.opacity(0.05), radius: 0.5, y: 0)
            .shadow(color: .black.opacity(0.10), radius: 16, y: 4)
            .shadow(color: .black.opacity(0.12), radius: 40, y: 12)
    }

    /// Apply Dot's floating panel shadow
    func forgeShadowPopup() -> some View {
        self.shadow(color: .black.opacity(0.1), radius: 32, y: 8)
    }

    /// Apply Dot's pricing card shadow (triple-layer)
    func forgeShadowElevated() -> some View {
        self
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
            .shadow(color: .black.opacity(0.06), radius: 40, y: 16)
    }
}

import SwiftUI

/// Claude-inspired palette: warm paper neutrals with a clay accent.
///
/// Colors are defined in code rather than an asset catalog so the whole theme
/// is reviewable in one place and can be unit-tested. Every color resolves
/// against the active `ColorScheme`.
enum Palette {

    // MARK: Surfaces

    /// Page background. Warm off-white in light, near-black warm gray in dark.
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1F1E1D) : Color(hex: 0xFAF9F5)
    }

    /// Raised surface: cards, sheets, list rows.
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x262624) : Color(hex: 0xFFFFFF)
    }

    /// Recessed surface: code blocks, quoted source excerpts, inset wells.
    static func well(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x191817) : Color(hex: 0xF0EEE6)
    }

    // MARK: Ink

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF5F4EF) : Color(hex: 0x1F1E1D)
    }

    static func inkSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xA8A59C) : Color(hex: 0x6C6A64)
    }

    static func inkTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x76736C) : Color(hex: 0x9A968C)
    }

    // MARK: Accent

    /// The Claude clay/coral. Primary actions, active states, focus rings.
    static let accent = Color(hex: 0xD97757)
    static let accentPressed = Color(hex: 0xC2634A)

    /// Low-emphasis accent wash for badges and selected rows.
    static func accentWash(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xD97757).opacity(0.16) : Color(hex: 0xD97757).opacity(0.10)
    }

    // MARK: Semantic

    static let success = Color(hex: 0x5B8C5A)
    static let warning = Color(hex: 0xC9922E)
    static let danger = Color(hex: 0xB4483C)
    /// Used for "you were confident but wrong" calibration feedback.
    static let overconfident = Color(hex: 0x9C5FB5)

    // MARK: Lines

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x3A3937) : Color(hex: 0xE3E1D9)
    }

    // MARK: Track colors
    //
    // Each curriculum track gets a stable hue so the mastery map is readable
    // at a glance. Chosen to stay distinguishable in both schemes and under
    // the most common forms of color vision deficiency; every place they are
    // used also carries a text label, never color alone.

    static func track(_ id: String) -> Color {
        switch id {
        case "prompting":   return Color(hex: 0xD97757)
        case "api":         return Color(hex: 0x4A7FA5)
        case "tools":       return Color(hex: 0x6B8E5A)
        case "claude-code": return Color(hex: 0xA5734A)
        case "evals":       return Color(hex: 0x8B6BA8)
        case "aws":         return Color(hex: 0xC9922E)
        case "production":  return Color(hex: 0x4F8C86)
        default:            return Color(hex: 0x8A8781)
        }
    }
}

// MARK: - Typography

enum Typeface {
    /// Body copy. SF Pro via `.system` — Claude's Styrene/Tiempos are not
    /// licensed for redistribution, so we lean on the system stack and match
    /// the *rhythm* (generous line height, restrained weights) instead.
    static func body(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .regular, design: .default) }
    static func medium(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .medium, design: .default) }
    static func semibold(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .semibold, design: .default) }

    /// Serif display for lesson titles — echoes Claude's editorial feel.
    static func display(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .semibold, design: .serif) }

    /// Code, token counts, model IDs.
    static func mono(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .regular, design: .monospaced) }
}

enum Metrics {
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 10
    static let rowSpacing: CGFloat = 12
    /// Line spacing added on top of the font's natural leading for long-form
    /// lesson prose. Reading research favors looser leading for dense text.
    static let proseLineSpacing: CGFloat = 6
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

import Foundation
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

    /// The Claude clay/coral, as a raw hex value.
    ///
    /// Single source of truth for the accent. `AccentColor` in the asset
    /// catalog must carry the same value — `ThemeTests` enforces that, because
    /// the two are read by different consumers (this one by our own views, the
    /// asset by system chrome) and nothing else would catch them drifting.
    static let accentHex: UInt32 = 0xD97757

    /// Primary actions, active states, focus rings.
    static let accent = Color(hex: accentHex)
    static let accentPressed = Color(hex: 0xC2634A)

    /// Foreground for content sitting on top of `accent`.
    ///
    /// Derived from the accent's luminance rather than hardcoded to white, so
    /// swapping in a pale accent can't leave white-on-white text.
    ///
    /// The 0.5 threshold is a design-preserving heuristic, not a contrast
    /// maximiser. Maximising would put dark ink on the clay accent (5.33:1
    /// against 3.12:1 for white), which is not the intended look. White on the
    /// current clay is 3.12:1 — enough for WCAG AA at large or bold sizes,
    /// which is the only place it is used, but not enough for body text. If you
    /// change the accent, check that whatever this returns still clears the bar
    /// for the sizes you use it at.
    static var onAccent: Color {
        relativeLuminance(of: accentHex) > 0.5 ? Color(hex: 0x1F1E1D) : .white
    }

    /// Low-emphasis accent wash for badges and selected rows.
    static func accentWash(_ scheme: ColorScheme) -> Color {
        accent.opacity(scheme == .dark ? 0.16 : 0.10)
    }

    /// WCAG relative luminance of a packed RGB value, 0 (black) to 1 (white).
    static func relativeLuminance(of hex: UInt32) -> Double {
        func channel(_ raw: UInt32) -> Double {
            let value = Double(raw) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
             + 0.7152 * channel((hex >> 8) & 0xFF)
             + 0.0722 * channel(hex & 0xFF)
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

    // Small roles. These sizes were previously repeated as literals at call
    // sites; naming them changed nothing visually, it just stopped the type
    // scale living in twenty files.

    /// Supporting text: dates, footnotes, secondary detail.
    static func caption(_ weight: Font.Weight = .regular) -> Font {
        .system(size: 12, weight: weight, design: .default)
    }

    /// Micro labels: stat captions, chart axis labels, prerequisite hints.
    static func micro(_ weight: Font.Weight = .regular) -> Font {
        .system(size: 11, weight: weight, design: .default)
    }

    /// The smallest label in the app: uppercase chips and unit suffixes only.
    /// This sits below Apple's 11pt legibility guidance, so it must never carry
    /// prose or anything a learner has to read carefully.
    static func nano(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: 10, weight: weight, design: .default)
    }

    /// Monospaced micro label — code-fence language tags.
    static func monoNano(_ weight: Font.Weight = .semibold) -> Font {
        .system(size: 10, weight: weight, design: .monospaced)
    }
}

/// Sizing for SF Symbols and emoji.
///
/// Deliberately separate from `Typeface`: these size a picture, not text. They
/// should not inherit the type scale, and they should not be swept up by a
/// future Dynamic Type mapping that scales body copy.
enum Glyph {
    static func icon(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func emoji(_ size: CGFloat) -> Font {
        .system(size: size)
    }
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

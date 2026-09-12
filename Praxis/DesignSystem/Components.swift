import SwiftUI

// MARK: - Card

/// The standard raised container. Everything on a dashboard sits in one.
struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface(scheme))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .stroke(Palette.hairline(scheme), lineWidth: 1)
            )
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.semibold(16))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(configuration.isPressed ? Palette.accentPressed : Palette.accent)
            .opacity(isEnabled ? 1 : 0.45)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.medium(16))
            .foregroundStyle(Palette.ink(scheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(configuration.isPressed ? Palette.well(scheme) : Palette.surface(scheme))
            .opacity(isEnabled ? 1 : 0.45)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .stroke(Palette.hairline(scheme), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Badges

struct TrackBadge: View {
    let trackID: String
    let label: String

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Palette.track(trackID))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Palette.track(trackID).opacity(0.14))
            .clipShape(Capsule())
    }
}

/// Difficulty tier, 1–5. Rendered as filled pips plus a text label so the
/// meaning never depends on counting shapes alone.
struct TierPips: View {
    @Environment(\.colorScheme) private var scheme
    let tier: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { index in
                Circle()
                    .fill(index <= tier ? Palette.accent : Palette.hairline(scheme))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Difficulty tier \(tier) of 5")
    }
}

// MARK: - Mastery bar

/// Horizontal mastery meter, 0...1. Reads as a progress bar but is labeled
/// with a percentage for screen readers and for anyone who can't judge fill.
struct MasteryBar: View {
    @Environment(\.colorScheme) private var scheme
    let value: Double
    var tint: Color = Palette.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline(scheme))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Mastery")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

// MARK: - Section header

struct SectionHeader: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Typeface.semibold(13))
                .tracking(0.4)
                .foregroundStyle(Palette.inkSecondary(scheme))
                .textCase(.uppercase)
            if let subtitle {
                Text(subtitle)
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Code block

/// Monospaced, horizontally scrollable. Lesson content is full of API request
/// bodies, so this needs to not wrap and not squeeze the page.
struct CodeBlock: View {
    @Environment(\.colorScheme) private var scheme
    let code: String
    var language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Typeface.mono(13))
                    .foregroundStyle(Palette.ink(scheme))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.well(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous))
    }
}

// MARK: - Empty / error states

struct StatusMessage: View {
    @Environment(\.colorScheme) private var scheme
    let symbol: String
    let title: String
    let message: String
    var tint: Color = Palette.accent

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(tint)
            Text(title)
                .font(Typeface.semibold(17))
                .foregroundStyle(Palette.ink(scheme))
            Text(message)
                .font(Typeface.body(14))
                .foregroundStyle(Palette.inkSecondary(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Screen background

struct CanvasBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background(Palette.canvas(scheme).ignoresSafeArea())
    }
}

extension View {
    func canvasBackground() -> some View { modifier(CanvasBackground()) }
}

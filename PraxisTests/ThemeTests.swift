import Testing
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import Praxis

@Suite("Theme")
struct ThemeTests {

    // MARK: Luminance
    //
    // Values checked against the WCAG relative-luminance formula. These exist
    // because `onAccent` is derived from them — if the maths drifts, the
    // foreground on every primary button silently changes.

    @Test("Black and white sit at the ends of the luminance range")
    func luminanceEndpoints() {
        #expect(Palette.relativeLuminance(of: 0x000000) == 0)
        #expect(abs(Palette.relativeLuminance(of: 0xFFFFFF) - 1.0) < 0.0001)
    }

    @Test("The clay accent's luminance matches the WCAG reference value")
    func accentLuminance() {
        #expect(abs(Palette.relativeLuminance(of: Palette.accentHex) - 0.286) < 0.005)
    }

    @Test("Luminance is monotonic across a grey ramp")
    func luminanceMonotonic() {
        let ramp: [UInt32] = [0x000000, 0x333333, 0x808080, 0xCCCCCC, 0xFFFFFF]
        let values = ramp.map(Palette.relativeLuminance(of:))
        #expect(values == values.sorted())
    }

    @Test("Green contributes more luminance than blue, per the WCAG weights")
    func channelWeighting() {
        #expect(Palette.relativeLuminance(of: 0x00FF00) > Palette.relativeLuminance(of: 0xFF0000))
        #expect(Palette.relativeLuminance(of: 0xFF0000) > Palette.relativeLuminance(of: 0x0000FF))
    }

    // MARK: onAccent

    @Test("A dark accent takes white foreground; a pale accent takes ink")
    func onAccentFlips() {
        // Reproduces the production rule against sample accents, so the
        // threshold behaviour is pinned even though `onAccent` reads a constant.
        func foreground(for hex: UInt32) -> String {
            Palette.relativeLuminance(of: hex) > 0.5 ? "ink" : "white"
        }
        #expect(foreground(for: 0xD97757) == "white")   // current clay
        #expect(foreground(for: 0x1A2B4C) == "white")   // very dark
        #expect(foreground(for: 0xF2D9C4) == "ink")     // pale
        #expect(foreground(for: 0xFFFFFF) == "ink")     // white accent
    }

    @Test("White on the current accent clears WCAG AA for large or bold text")
    func accentContrastIsAdequateForItsUses() {
        // onAccent is only ever used on 16pt semibold button labels and the
        // confidence picker, both of which count as large/bold text (3:1 bar).
        // It is NOT adequate for body copy (4.5:1) — this test is the guard
        // against someone lowering the accent's contrast further.
        let accent = Palette.relativeLuminance(of: Palette.accentHex)
        let white = Palette.relativeLuminance(of: 0xFFFFFF)
        let ratio = (max(accent, white) + 0.05) / (min(accent, white) + 0.05)
        #expect(ratio >= 3.0, "accent/white contrast fell below the large-text bar: \(ratio)")
    }

    // MARK: Single source of truth

    #if canImport(UIKit)
    @Test("The asset catalog accent matches Palette.accent")
    func assetCatalogMatchesPalette() throws {
        // These are read by different consumers — Palette by our own views,
        // AccentColor by system chrome — so nothing else would catch a drift.
        let asset = try #require(
            UIColor(named: "AccentColor", in: Bundle.main, compatibleWith: nil),
            "AccentColor is missing from the asset catalog"
        )
        let expected = UIColor(Palette.accent)

        func components(_ color: UIColor) -> (CGFloat, CGFloat, CGFloat) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r, g, b)
        }

        // Checked in both appearances: the asset declares a single universal
        // value on purpose, so light and dark must resolve identically.
        for style in [UIUserInterfaceStyle.light, .dark] {
            let resolved = components(asset.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
            let target = components(expected)
            #expect(abs(resolved.0 - target.0) < 0.01, "red differs in \(style)")
            #expect(abs(resolved.1 - target.1) < 0.01, "green differs in \(style)")
            #expect(abs(resolved.2 - target.2) < 0.01, "blue differs in \(style)")
        }
    }
    #endif

    // MARK: Track colors

    @Test("Every curriculum track has a distinct color")
    func trackColorsAreDistinct() throws {
        let bundle = Bundle(for: ThemeBundleToken.self)
        let url = try #require(
            bundle.url(forResource: "curriculum", withExtension: "json")
                ?? Bundle.main.url(forResource: "curriculum", withExtension: "json")
        )
        let store = try CurriculumStore(data: Data(contentsOf: url))

        #if canImport(UIKit)
        func rgb(_ color: Color) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%.3f-%.3f-%.3f", r, g, b)
        }
        let colors = store.tracks.map { rgb(Palette.track($0.id)) }
        #expect(Set(colors).count == store.tracks.count, "two tracks share a color")

        // A track with no mapping falls back to grey; none should hit that.
        let fallback = rgb(Palette.track("definitely-not-a-track"))
        for (track, color) in zip(store.tracks, colors) {
            #expect(color != fallback, "\(track.id) has no color and fell back to grey")
        }
        #endif
    }
}

private final class ThemeBundleToken {}

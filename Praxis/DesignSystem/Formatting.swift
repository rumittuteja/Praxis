import Foundation

/// Locale-aware formatting for every number the UI shows.
///
/// Hand-built strings like `"\(Int(value * 100))%"` and
/// `String(format: "$%.3f", cost)` render the same everywhere, which is wrong:
/// decimal separators, grouping separators, percent placement and currency
/// symbol position all vary by locale. Routing through `FormatStyle` fixes all
/// of that in one place.
///
/// Deliberately *not* used for the day-key in `DailyPlan` or for anything sent
/// to the model — those must stay byte-stable regardless of the device locale.
enum Format {

    /// A 0...1 fraction as a whole-number percentage. "75%", "%75", "75 %"
    /// depending on locale.
    ///
    /// Every function here takes an explicit `locale` defaulting to the
    /// device's, so tests can pin a locale instead of asserting against
    /// whatever the simulator happens to be set to.
    static func percent(_ fraction: Double, locale: Locale = .autoupdatingCurrent) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// An integer count with locale grouping separators: 1,234 / 1.234 / 1 234.
    static func count(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.locale(locale))
    }

    /// A duration in seconds, one decimal place.
    static func seconds(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let number = value.formatted(.number.precision(.fractionLength(1)).locale(locale))
        return String(
            localized: "\(number)s",
            comment: "Duration in seconds, e.g. 2.4s. Placeholder is the already-formatted number."
        )
    }

    /// A US-dollar amount. The currency stays USD because that is what both
    /// providers bill in; only the formatting follows the locale.
    static func usd(_ value: Double, fractionDigits: Int = 3,
                    locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(
            .currency(code: "USD").precision(.fractionLength(fractionDigits)).locale(locale)
        )
    }

    /// A file size: "2.4 MB", "2,4 MB", per locale.
    static func fileSize(_ bytes: Int, locale: Locale = .autoupdatingCurrent) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    /// An approximate cost, marked as such.
    static func approximateUSD(_ value: Double, fractionDigits: Int = 4,
                               locale: Locale = .autoupdatingCurrent) -> String {
        let amount = usd(value, fractionDigits: fractionDigits, locale: locale)
        return String(
            localized: "~\(amount)",
            comment: "Approximate cost. The tilde marks it as an estimate."
        )
    }
}

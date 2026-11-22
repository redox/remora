import Foundation

/// Canonical form of application names. Some apps embed invisible format characters in their
/// localized name (WhatsApp: U+200E LEFT-TO-RIGHT MARK), which would make exact comparisons
/// such as `app:WhatsApp` fail open.
public enum AppName {
    /// Removes every Unicode format scalar (general category Cf: bidi marks and isolates,
    /// ZWJ/ZWNJ, BOM), applies NFC and trims whitespace.
    public static func normalize(_ raw: String) -> String {
        stripFormatting(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cf removal and NFC only (no trimming): for matching affixes where spaces matter.
    static func stripFormatting(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where scalar.properties.generalCategory != .format {
            scalars.append(scalar)
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    /// Locale-independent case folding for comparisons.
    static func fold(_ s: String) -> String {
        s.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// Format characters removed, NFC, locale-independent case folding.
    static func foldForMatching(_ s: String) -> String { fold(stripFormatting(s)) }
}

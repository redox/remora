import Foundation

/// US SSN, French NIR (with key check, including Corsican 2A/2B departments) and French
/// numéro fiscal (labeled).
struct NationalIDDetector: Detector {
    private static let ssn = Pattern(#"(?<!\d)(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}(?!\d)"#)
    /// sex(1) year(2) month(2) department(2: digits, or 2A/2B for Corsica) commune(3) order(3) key(2).
    private static let nir = Pattern(
        #"(?<!\d)[12](?:[ \x{00A0}\x{202F}]?\d){4}(?:[ \x{00A0}\x{202F}]?\d[ \x{00A0}\x{202F}]?\d|[ \x{00A0}\x{202F}]?2[ \x{00A0}\x{202F}]?[ABab])(?:[ \x{00A0}\x{202F}]?\d){8}(?!\d)"#)
    private static let fiscal = Pattern(
        #"(?:num[ée]ro fiscal|n° ?fiscal|\bSPI\b)[^\d\n]{0,30}(\d(?:[ \x{00A0}\x{202F}]?\d){12})(?!\d)"#,
        group: 1, options: [.caseInsensitive])

    func ranges(in text: String) -> [Range<String.Index>] {
        var out = Self.ssn.ranges(in: text) + Self.fiscal.ranges(in: text)
        Self.nir.forEachMatch(in: text) { range, match in
            if Self.nirKeyValid(Self.nirDigits(match)) { out.append(range) }
        }
        return out
    }

    /// Digits of a NIR candidate, with a Corsican department replaced per INSEE for the key
    /// computation: 2A → 19, 2B → 18.
    static func nirDigits(_ match: Substring) -> String {
        let compact = match.filter { $0.isASCII && ($0.isNumber || $0.isLetter) }.uppercased()
        return compact.replacingOccurrences(of: "2A", with: "19").replacingOccurrences(of: "2B", with: "18")
    }

    /// 13 digits followed by a 2-digit key where key == 97 - (n mod 97).
    static func nirKeyValid(_ digits: String) -> Bool {
        guard digits.count == 15, let n = Int(digits.prefix(13)), let key = Int(digits.suffix(2)) else { return false }
        return key == 97 - (n % 97)
    }
}

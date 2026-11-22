import Foundation

/// IBANs validated with the ISO 13616 mod-97 check (spaces allowed).
struct IBANDetector: Detector {
    private static let candidate = Pattern(
        #"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?:[ \x{00A0}\x{202F}]?[A-Z0-9]{4}){2,7}(?:[ \x{00A0}\x{202F}]?[A-Z0-9]{1,3})?(?![A-Za-z0-9])"#)

    func ranges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        Self.candidate.forEachMatch(in: text) { range, candidate in
            if let valid = Self.longestValidPrefix(of: candidate, base: range) { out.append(valid) }
        }
        return out
    }

    /// The greedy match may swallow a trailing uppercase word, so retry on shorter prefixes
    /// (cut at group boundaries) until the mod-97 check passes.
    private static func longestValidPrefix(of candidate: Substring, base: Range<String.Index>) -> Range<String.Index>? {
        var end = candidate.endIndex
        while true {
            let slice = candidate[candidate.startIndex..<end]
            let compact = slice.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            if compact.count < 15 { return nil }
            if compact.count <= 34, isValid(compact) { return candidate.startIndex..<end }
            guard let space = slice.lastIndex(where: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }) else { return nil }
            end = space
        }
    }

    static func isValid(_ iban: String) -> Bool {
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for ch in rearranged.utf8 {
            switch ch {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                remainder = (remainder * 10 + Int(ch - UInt8(ascii: "0"))) % 97
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                remainder = (remainder * 100 + Int(ch - UInt8(ascii: "A")) + 10) % 97
            default:
                return false
            }
        }
        return remainder == 1
    }
}

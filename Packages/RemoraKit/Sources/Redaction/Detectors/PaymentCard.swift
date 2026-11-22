import Foundation

/// Luhn-valid 13-19 digit card numbers (spaces/dashes allowed) and labeled CVV/CVC codes.
struct PaymentCardDetector: Detector {
    private static let candidate = Pattern(#"(?<!\d)\d(?:[ \x{00A0}\x{202F}-]?\d){12,22}(?!\d)"#)
    private static let cvv = Pattern(
        #"\b(?:CVV2?|CVC2?|cryptogramme)\b[ :=\-]{0,6}(\d{3,4})(?!\d)"#,
        group: 1, options: [.caseInsensitive])

    func ranges(in text: String) -> [Range<String.Index>] {
        var out = Self.cvv.ranges(in: text)
        Self.candidate.forEachMatch(in: text) { range, candidate in
            out.append(contentsOf: Self.cardRanges(in: candidate, base: range))
        }
        return out
    }

    /// Finds Luhn-valid card numbers inside a run of digit groups, so a card preceded by an
    /// unrelated number ("12 4111 1111 1111 1111") is still caught.
    private static func cardRanges(in candidate: Substring, base: Range<String.Index>) -> [Range<String.Index>] {
        var groups: [Range<String.Index>] = []
        var start: String.Index?
        var i = candidate.startIndex
        while i < candidate.endIndex {
            let isDigit = candidate[i].isASCII && candidate[i].isNumber
            if isDigit, start == nil { start = i }
            if !isDigit, let s = start { groups.append(s..<i); start = nil }
            i = candidate.index(after: i)
        }
        if let s = start { groups.append(s..<candidate.endIndex) }

        func digits(_ r: Range<String.Index>) -> [Character] {
            candidate[r].filter { $0.isASCII && $0.isNumber }
        }
        // The whole candidate, validated as a unit.
        let all = digits(groups[0].lowerBound..<groups[groups.count - 1].upperBound)
        if (13...19).contains(all.count), luhnValid(all) { return [base] }

        // Sub-windows only for standard card layouts starting with a plausible issuer digit,
        // so a card preceded by an unrelated number is still caught.
        var out: [Range<String.Index>] = []
        for from in 0..<groups.count {
            for layout in layouts where from + layout.count <= groups.count {
                let window = groups[from..<(from + layout.count)]
                let sizes = window.map { candidate.distance(from: $0.lowerBound, to: $0.upperBound) }
                guard sizes == layout, "3456".contains(candidate[window.first!.lowerBound]) else { continue }
                let range = window.first!.lowerBound..<window.last!.upperBound
                if luhnValid(digits(range)) { out.append(range) }
            }
        }
        return out
    }

    private static let layouts: [[Int]] = [[4, 4, 4, 4], [4, 4, 4, 4, 3], [4, 6, 5], [4, 6, 4]]

    static func luhnValid(_ digits: some Sequence<Character>) -> Bool {
        var sum = 0
        var double = false
        for ch in digits.reversed() {
            guard var d = ch.wholeNumberValue else { return false }
            if double { d *= 2; if d > 9 { d -= 9 } }
            sum += d
            double.toggle()
        }
        return sum % 10 == 0
    }
}

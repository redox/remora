import CoreGraphics

/// Decides where the text caret is from the bounds an app reports for nearby characters.
/// Pure: the AX reader only fetches rects and characters. Apps such as Mail return a newline's
/// bounds stretched to the end of the line, so a newline rect (or any rect much wider than it is
/// tall) is never trusted for its `maxX`.
enum CaretGeometry {
    static let caretWidth: CGFloat = 1.5
    private static let newlines: Set<Character> = ["\n", "\r", "\u{2028}", "\u{2029}"]

    static func isNewline(_ c: Character) -> Bool { newlines.contains(c) || c.isNewline }

    /// A thin caret rect at the insertion point, or nil when nothing usable is known.
    /// - beforeRect/beforeChar: bounds and character just before the caret (nil at location 0).
    /// - atRect/atChar: bounds and character at the caret (nil at the end of the text).
    /// - zeroRect: bounds of a zero-length range at the caret, where the app supports it.
    /// - lineRect: bounds of the caret's line, as a last resort for x.
    static func caret(beforeRect: CGRect?, beforeChar: Character?, atRect: CGRect?, atChar: Character?,
                      zeroRect: CGRect? = nil, lineRect: CGRect? = nil) -> CGRect? {
        if let c = beforeChar, !isNewline(c), let r = glyph(beforeRect) {
            return thin(x: r.maxX, line: r)
        }
        if let c = atChar, !isNewline(c), let r = glyph(atRect) {
            return thin(x: r.minX, line: r)
        }
        if let r = zeroRect, r.height > 0, r.width <= r.height * 3 { return thin(x: r.minX, line: r) }
        // A newline at the insertion point can span the rest of a blank line in Mail. Its
        // leading edge is useful; the trailing edge would put the badge across the whole field.
        if let c = atChar, isNewline(c), let r = atRect, r.height > 0 {
            return thin(x: r.minX, line: r)
        }
        if let r = lineRect, r.height > 0 { return thin(x: r.minX, line: r) }
        return nil
    }

    /// A rect that plausibly bounds one glyph: non-empty and not line-wide.
    private static func glyph(_ r: CGRect?) -> CGRect? {
        guard let r, r.height > 0, r.width > 0, r.width <= r.height * 3 else { return nil }
        return r
    }

    private static func thin(x: CGFloat, line: CGRect) -> CGRect {
        CGRect(x: x, y: line.minY, width: caretWidth, height: line.height)
    }
}

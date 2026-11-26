import CoreGraphics
import Foundation

/// Decides where the text caret is from the bounds an app reports for nearby characters.
/// Pure: the AX reader only fetches rects and characters. Apps such as Mail return a newline's
/// bounds stretched to the end of the line, so a newline rect (or any rect much wider than it is
/// tall) is never trusted for its `maxX`.
enum CaretGeometry {
    static let caretWidth: CGFloat = 1.5
    private static let newlines: Set<Character> = ["\n", "\r", "\u{2028}", "\u{2029}"]

    static func isNewline(_ c: Character) -> Bool { newlines.contains(c) || c.isNewline }

    /// Google Docs positions its input frame at the caret when screen magnifier support is on.
    /// Chrome can clip an off-screen frame to the viewport edge, so require an interior origin.
    static func caret(inMagnifierFrame frame: CGRect, viewport: CGRect) -> CGRect? {
        guard !frame.isEmpty, !frame.isInfinite, !viewport.isEmpty, !viewport.isInfinite,
              viewport.contains(frame.origin), frame.minY > viewport.minY, frame.minX > viewport.minX else { return nil }
        // Only one pixel of the input frame may be visible. Leave room for a line below its top.
        return CGRect(x: frame.minX, y: frame.minY, width: caretWidth, height: max(16, frame.height))
    }

    /// Chromium can expose an unclipped text range inside a clipped Docs input proxy.
    /// Verify the whole insertion line against the enclosing document in AX screen coordinates.
    static func documentInsertionBounds(_ range: CGRect?, in viewport: CGRect) -> CGRect? {
        guard let range, range.width >= 0, range.width <= caretWidth, range.height > 0,
              !viewport.isEmpty, !viewport.isInfinite, range.minX > viewport.minX, range.minY > viewport.minY,
              range.maxX < viewport.maxX, range.maxY <= viewport.maxY else { return nil }
        return thin(x: range.minX, line: range)
    }

    /// Read only the ranges needed to locate the caret. Ghostty reports an empty selection
    /// at offset zero anywhere in its pane, so adjacent glyphs cannot locate its terminal cursor.
    static func read(selection: NSRange?, value: String?, isGhosttySurface: Bool, fieldFrame: CGRect?,
                     bounds: (NSRange) -> CGRect?, lineBounds: (Int) -> CGRect?) -> CGRect? {
        let loc = selection?.location ?? 0
        guard loc >= 0, loc < NSNotFound else { return nil }
        let insertion = NSRange(location: loc, length: 0)
        if isGhosttySurface, selection?.length ?? 0 == 0 {
            guard let rect = bounds(insertion), rect.width <= rect.height,
                  fieldFrame.map({ rect.height < $0.height }) ?? true else { return nil }
            return collapsedCaret(rect)
        }
        guard selection != nil else { return nil }
        let text = value as NSString?
        func character(at index: Int) -> (character: Character, rect: CGRect?)? {
            guard let text, index >= 0, index < text.length else { return nil }
            let range = text.rangeOfComposedCharacterSequence(at: index)
            guard let character = text.substring(with: range).first else { return nil }
            return (character, bounds(range))
        }
        let before = character(at: loc - 1)
        let at = character(at: loc)
        return caret(beforeRect: before?.rect, beforeChar: before?.character, atRect: at?.rect, atChar: at?.character,
                     zeroRect: bounds(insertion), lineRect: lineBounds(loc))
    }

    /// A thin caret rect at the insertion point, or nil when nothing usable is known.
    /// - beforeRect/beforeChar: bounds and character just before the caret (nil at location 0).
    /// - atRect/atChar: bounds and character at the caret (nil at the end of the text).
    /// - zeroRect: bounds of a zero-length range at the caret, where the app supports it.
    /// - lineRect: bounds of the caret's line, as a last resort for x.
    static func caret(beforeRect: CGRect?, beforeChar: Character?, atRect: CGRect?, atChar: Character?,
                      zeroRect: @autoclosure () -> CGRect? = nil, lineRect: @autoclosure () -> CGRect? = nil) -> CGRect? {
        if let c = beforeChar, !isNewline(c), let r = glyph(beforeRect) {
            return thin(x: r.maxX, line: r)
        }
        if let c = atChar, !isNewline(c), let r = glyph(atRect) {
            return thin(x: r.minX, line: r)
        }
        // A newline at the insertion point can span the rest of a blank line in Mail. Its
        // leading edge is useful; the trailing edge would put the badge across the whole field.
        if let c = atChar, isNewline(c), let r = atRect, r.height > 0 {
            return thin(x: r.minX, line: r)
        }
        if let caret = collapsedCaret(zeroRect()) { return caret }
        if let r = lineRect(), r.height > 0 { return thin(x: r.minX, line: r) }
        return nil
    }

    private static func collapsedCaret(_ rect: CGRect?) -> CGRect? {
        guard let rect, rect.height.isFinite, rect.height > 0, rect.width >= 0, rect.width <= rect.height * 3 else { return nil }
        return thin(x: rect.minX, line: rect)
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

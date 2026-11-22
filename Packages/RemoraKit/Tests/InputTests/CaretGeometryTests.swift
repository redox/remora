import CoreGraphics
import Testing
@testable import Input

private let glyph = CGRect(x: 100, y: 50, width: 8, height: 16)
private let wide = CGRect(x: 100, y: 30, width: 600, height: 16)

private func expectThin(_ r: CGRect?, x: CGFloat, y: CGFloat? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let r else { Issue.record("expected a caret rect", sourceLocation: sourceLocation); return }
    #expect(r.minX == x, sourceLocation: sourceLocation)
    #expect(r.width <= 2 && r.width > 0, sourceLocation: sourceLocation)
    #expect(r.height > 0, sourceLocation: sourceLocation)
    if let y { #expect(r.minY == y, sourceLocation: sourceLocation) }
}

@Test func caretMidLineIsAfterPreviousLetter() {
    expectThin(CaretGeometry.caret(beforeRect: glyph, beforeChar: "a", atRect: CGRect(x: 108, y: 50, width: 8, height: 16), atChar: "b"),
               x: glyph.maxX, y: 50)
}

@Test func caretAtStartOfTextIsBeforeFirstCharacter() {
    let first = CGRect(x: 40, y: 50, width: 8, height: 16)
    // At location 0 the "before" query returns the character after the caret; it must be ignored.
    expectThin(CaretGeometry.caret(beforeRect: first, beforeChar: nil, atRect: first, atChar: "H"), x: 40)
}

@Test func caretBeforeAnEmptyFirstLineUsesTheNewlinesLeadingEdge() {
    // Mail can expose the initial blank line as a rectangle spanning the compose body.
    let newline = CGRect(x: 40, y: 70, width: 1_800, height: 16)
    expectThin(CaretGeometry.caret(beforeRect: nil, beforeChar: nil, atRect: newline, atChar: "\n"), x: 40, y: 70)
}

@Test func rejectedZeroLengthBoundsStillAllowTheLineFallback() {
    let zero = CGRect(x: 40, y: 70, width: 1_800, height: 16)
    #expect(CaretGeometry.caret(beforeRect: nil, beforeChar: nil, atRect: nil, atChar: nil, zeroRect: zero) == nil)
    expectThin(CaretGeometry.caret(beforeRect: nil, beforeChar: nil, atRect: nil, atChar: nil,
                                  zeroRect: zero, lineRect: zero), x: 40, y: 70)
}

@Test func caretOnEmptyLineAfterNewlineIgnoresNewlineRect() {
    let zero = CGRect(x: 40, y: 70, width: 0, height: 16)
    expectThin(CaretGeometry.caret(beforeRect: wide, beforeChar: "\n", atRect: nil, atChar: nil, zeroRect: zero), x: 40, y: 70)
}

@Test func caretAfterNewlineUsesNextCharacter() {
    let next = CGRect(x: 40, y: 70, width: 8, height: 16)
    expectThin(CaretGeometry.caret(beforeRect: wide, beforeChar: "\n", atRect: next, atChar: "x"), x: 40, y: 70)
}

@Test func wideRectIsNeverUsedForMaxX() {
    // A wide rect for a non-newline character is a line-terminal rect, not a glyph.
    let r = CaretGeometry.caret(beforeRect: wide, beforeChar: "a", atRect: nil, atChar: nil)
    #expect(r == nil)
    let line = CGRect(x: 40, y: 70, width: 600, height: 16)
    expectThin(CaretGeometry.caret(beforeRect: wide, beforeChar: "\r", atRect: nil, atChar: nil, lineRect: line), x: 40, y: 70)
}

@Test func caretAtEndOfTextAfterLetter() {
    expectThin(CaretGeometry.caret(beforeRect: glyph, beforeChar: "z", atRect: nil, atChar: nil), x: glyph.maxX)
}

@Test func nilRectsGiveNil() {
    #expect(CaretGeometry.caret(beforeRect: nil, beforeChar: "a", atRect: nil, atChar: "b") == nil)
    #expect(CaretGeometry.caret(beforeRect: nil, beforeChar: nil, atRect: nil, atChar: nil) == nil)
}

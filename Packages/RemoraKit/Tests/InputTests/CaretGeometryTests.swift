import CoreGraphics
import Foundation
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

@Test func googleDocsMagnifierFrameLocatesTheCaretAtItsLeadingEdge() {
    let frame = CGRect(x: 925, y: 345, width: 625, height: 1)
    let viewport = CGRect(x: 100, y: 120, width: 1_200, height: 700)
    let caret = CaretGeometry.caret(inMagnifierFrame: frame, viewport: viewport)
    #expect(caret == CGRect(x: 925, y: 345, width: CaretGeometry.caretWidth, height: 16))
}

@Test(arguments: [-10_000.0, 120.0]) func googleDocsOffscreenInputDoesNotAnchorThePopover(y: CGFloat) {
    let frame = CGRect(x: 300, y: y, width: 625, height: 1)
    let viewport = CGRect(x: 100, y: 120, width: 1_200, height: 700)
    #expect(CaretGeometry.caret(inMagnifierFrame: frame, viewport: viewport) == nil)
}

@Test func ghosttyEmptySelectionReadsOnlyTheCursorBounds() {
    let pane = CGRect(x: 10, y: 40, width: 520, height: 800)
    let cursor = CGRect(x: 150, y: 700, width: 0, height: 16)
    for reported in [cursor, pane, nil] {
        var queries = [NSRange]()
        let result = CaretGeometry.read(
            selection: NSRange(location: 0, length: 0), value: "Old output\nPrompt", isGhosttySurface: true,
            fieldFrame: pane, bounds: { range in
                queries.append(range)
                return range.length == 0 ? reported : glyph
            }, lineBounds: { _ in Issue.record("A terminal selection offset cannot identify the cursor line"); return nil })
        #expect(queries == [NSRange(location: 0, length: 0)])
        if reported == cursor {
            expectThin(result, x: 150, y: 700)
        } else {
            #expect(result == nil)
        }
    }
}

@Test func invalidInsertionOffsetsNeverQueryAX() {
    for offset in [-1, NSNotFound] {
        let rect = CaretGeometry.read(selection: NSRange(location: offset, length: 0), value: "a",
                                      isGhosttySurface: false, fieldFrame: nil,
                                      bounds: { _ in Issue.record("Invalid range"); return nil },
                                      lineBounds: { _ in Issue.record("Invalid index"); return nil })
        #expect(rect == nil)
    }
}

@Test func docsCanUseAnUnclippedInsertionRangeInsideTheVerifiedDocument() {
    let viewport = CGRect(x: 100, y: 250, width: 1250, height: 700)
    let range = CGRect(x: 320, y: 420, width: 0, height: 17)
    expectThin(CaretGeometry.documentInsertionBounds(range, in: viewport), x: 320, y: 420)
    for invalid in [CGRect(x: 100, y: 250, width: 0, height: 17),
                    CGRect(x: 320, y: 320, width: 500, height: 1),
                    CGRect(x: 320, y: 960, width: 0, height: 17),
                    CGRect(x: 320, y: 940, width: 0, height: 17)] {
        #expect(CaretGeometry.documentInsertionBounds(invalid, in: viewport) == nil)
    }
}

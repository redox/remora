import Foundation
import Testing
@testable import Rewrite

@Test func editSessionTracksRangeAcrossRounds() throws {
    var s = try EditSession(value: "A B C", selection: NSRange(location: 2, length: 1))
    #expect(s.targetText(in: "A B C") == "B")
    let v1 = s.didWrite(result: "bee", into: "A B C")
    #expect(v1 == "A bee C" && s.target == NSRange(location: 2, length: 3) && s.lastWritten == v1)
    try s.resync(currentValue: v1, selection: nil)
    #expect(s.targetText(in: v1) == "bee")
    let v2 = s.didWrite(result: "x", into: v1)
    #expect(v2 == "A x C")
    #expect(s.undo() == v1)
    #expect(s.undo() == "A B C")
    #expect(s.undo() == nil)
    #expect(s.target == NSRange(location: 2, length: 1))
}

@Test func editSessionResyncsAfterUserEdit() throws {
    var s = try EditSession(value: "A B C", selection: NSRange(location: 2, length: 1))
    let v = s.didWrite(result: "bee", into: "A B C")
    try s.resync(currentValue: v + "!", selection: nil)
    #expect(s.target == NSRange(location: 0, length: v.utf16.count + 1))
    #expect(s.undo() == nil)
}

@Test func editSessionWholeValueAndEmoji() throws {
    var s = try EditSession(value: "a😀b", selection: nil)
    #expect(s.target == NSRange(location: 0, length: 4))
    let v = s.didWrite(result: "😀😀", into: "a😀b")
    #expect(v == "😀😀" && s.target == NSRange(location: 0, length: 4))
}

@Test func editSessionClampsOutOfBoundsSelection() throws {
    // Past the end: clamped to what exists, not widened to the whole field.
    let s = try EditSession(value: "Hello world", selection: NSRange(location: 6, length: 50))
    #expect(s.target == NSRange(location: 6, length: 5))
    // Negative start: the intersection with the field.
    let n = try EditSession(value: "Hello world", selection: NSRange(location: -3, length: 5))
    #expect(n.target == NSRange(location: 0, length: 2))
}

@Test func editSessionRefusesSelectionThatClampsToEmpty() {
    #expect(throws: RewriteError.selectionOutOfBounds) {
        try EditSession(value: "Hello", selection: NSRange(location: 40, length: 3))
    }
    #expect(throws: RewriteError.selectionOutOfBounds) {
        try EditSession(value: "Hello", selection: NSRange(location: NSNotFound, length: 2))
    }
}

@Test func editSessionEmptySelectionMeansWholeField() throws {
    #expect(try EditSession(value: "Hello", selection: NSRange(location: 2, length: 0)).target == NSRange(location: 0, length: 5))
    #expect(try EditSession(value: "Hello", selection: NSRange(location: NSNotFound, length: 0)).target == NSRange(location: 0, length: 5))
}

@Test func editSessionResyncIgnoresLineEndingAndTrailingSpaceNormalization() throws {
    var s = try EditSession(value: "A\nB C\nD", selection: NSRange(location: 4, length: 1))
    let v = s.didWrite(result: "see", into: "A\nB C\nD")
    #expect(v == "A\nB see\nD")
    // The app stored CRLF line endings and trailing spaces: same text, different code units.
    let appSide = "A  \r\nB see\r\nD "
    try s.resync(currentValue: appSide, selection: nil)
    #expect(s.canUndo)
    #expect(s.targetText(in: appSide) == "see")
    #expect(s.lastWritten == appSide)
    // A lone CR is a line ending too.
    var c = try EditSession(value: "x\ny", selection: NSRange(location: 2, length: 1))
    _ = c.didWrite(result: "z", into: "x\ny")
    try c.resync(currentValue: "x\rz", selection: nil)
    #expect(c.targetText(in: "x\rz") == "z" && c.canUndo)
    // A real edit still resets the scope.
    try s.resync(currentValue: appSide + "!", selection: nil)
    #expect(!s.canUndo && s.target == NSRange(location: 0, length: (appSide + "!").utf16.count))
}

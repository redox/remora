import Foundation
import Storage
import Testing
@testable import Rewrite

@Test(arguments: [
    ("/q what's next?", nil, RewriteMode.question("what's next?")),
    ("  /q\nwho", nil, .question("who")),
    ("/q", nil, .question("")),
    ("/q why", NSRange(location: 0, length: 2), .question("why")),
    ("/query ideas", nil, .draftAtCaret(12)),
    ("/g old", nil, .draftAtCaret(6)),
    ("hello", NSRange(location: 0, length: 5), .selection(NSRange(location: 0, length: 5))),
    ("", nil, .draft),
    ("   \n", nil, .draft),
    ("Write a reply", nil, .draft),
    ("hi", NSRange(location: 1, length: 0), .draftAtCaret(1))
] as [(String, NSRange?, RewriteMode)])
func decidesMode(value: String, sel: NSRange?, expected: RewriteMode) {
    #expect(RewriteMode.decide(value: value, selection: sel, placeholder: "Write a reply") == expected)
}

@Test func mapsToInlineMode() {
    #expect(InlineMode(.selection(NSRange(location: 0, length: 1))) == .selection)
    #expect(InlineMode(.full) == .full && InlineMode(.draft) == .draft && InlineMode(.draftAtCaret(1)) == .draft && InlineMode(.question("x")) == .question)
}

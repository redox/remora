import Foundation
import Testing
@testable import Memory

@Test func styleMergeReplacesNearDuplicates() {
    let merged = StyleNotesMerge.merge(existing: ["Never use exclamation marks anywhere in messages to colleagues"],
                                       new: ["Never use exclamation marks anywhere in message to colleagues"])
    #expect(merged == ["Never use exclamation marks anywhere in message to colleagues"])
}

@Test func styleMergeKeepsDistinctBulletsAndFoldsCase() {
    let merged = StyleNotesMerge.merge(existing: ["Keep it short", "Greet by first name"],
                                       new: ["KEEP IT SHORT!", "Sign off with Cheers"])
    #expect(merged == ["Greet by first name", "KEEP IT SHORT!", "Sign off with Cheers"])
}

@Test func styleMergeCapsAt12DroppingTheOldest() {
    let existing = (1...12).map { "Rule number \($0) alpha\($0)" }
    let merged = StyleNotesMerge.merge(existing: existing, new: ["Totally different bullet"])
    #expect(merged.count == 12 && merged.last == "Totally different bullet" && merged.first == "Rule number 2 alpha2")
}

@Test func styleMergeCutsBulletsTo120Characters() {
    let merged = StyleNotesMerge.merge(existing: [], new: [String(repeating: "word ", count: 60)])
    #expect(merged.count == 1 && merged[0].count <= 120)
}

@Test func appendKeepsTheUsersRawTextByteForByteAndAddsNewBullets() throws {
    let long = "- " + String(repeating: "very long user bullet ", count: 12)
    let raw = "\(long)\nSome prose the user typed.\n* star bullet\n• dot bullet"
    let out = try #require(StyleNotesMerge.append(toRaw: raw, new: ["A brand new rule", "Another unrelated tip"]))
    #expect(out == raw + "\n- A brand new rule\n- Another unrelated tip\n")
    #expect(out.hasPrefix(raw))
}

@Test func appendSkipsNearDuplicatesAndReturnsNilWhenNothingIsAdded() {
    let raw = "- Casual, first names only please\nProse line\n"
    #expect(StyleNotesMerge.append(toRaw: raw, new: ["Casual, first names only", "Prose line!"]) == nil)
}

@Test func appendRespectsTheCapAndTheNewlineAtTheEnd() throws {
    let full = (1...12).map { "- Rule number \($0) alpha\($0)" }.joined(separator: "\n") + "\n"
    #expect(StyleNotesMerge.append(toRaw: full, new: ["Totally different bullet"]) == nil)
    let out = try #require(StyleNotesMerge.append(toRaw: "- Mine", new: ["Extra", "Extra again please"]))
    #expect(out == "- Mine\n- Extra\n- Extra again please\n")
    #expect(StyleNotesMerge.append(toRaw: "", new: ["First"]) == "- First\n")
}

@Test func bulletsParseAndRenderRoundTrip() {
    #expect(StyleNotesMerge.bullets("- a\n* b\n\n• c\nplain\n") == ["a", "b", "c", "plain"])
    #expect(StyleNotesMerge.render(["a", "b"]) == "- a\n- b\n")
    #expect(StyleNotesMerge.render([]) == "")
}

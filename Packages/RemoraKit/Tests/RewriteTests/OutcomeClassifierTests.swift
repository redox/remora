import Foundation
import Storage
import Testing
@testable import Rewrite

@Test(arguments: [("Merci, à demain", "Merci, à demain\n\nMarc", InlineOutcome.kept), ("Merci pour tout, à demain", "Merci pour tout et à bientôt demain", .edited),
                  ("Merci, à demain", "Totally different text here", .discarded), ("Merci,  à\ndemain", "x Merci, à demain y", .kept)])
func classifiesOutcome(inserted: String, now: String, expected: InlineOutcome) {
    #expect(OutcomeClassifier.classify(inserted: inserted, fieldNow: now) == expected)
}

@Test func unreadableFieldIsNil() {
    #expect(OutcomeClassifier.classify(inserted: "abc", fieldNow: nil) == nil)
}

@Test(arguments: ["", "   ", "\n\t "])
func emptyFieldIsUnknownNotDiscarded(now: String) {
    // A sent message clears its field: that says nothing about whether the text was kept.
    #expect(OutcomeClassifier.classify(inserted: "abc", fieldNow: now) == nil)
}

@Test func insertedWordsAreCappedForLCS() {
    #expect(OutcomeClassifier.maxInsertedWords == 2_000)
    // 5,000 inserted words, the first 2,000 kept in order with a change after them: still edited,
    // and the comparison stays bounded.
    let inserted = (0..<5_000).map { "w\($0)" }.joined(separator: " ")
    let edited = (0..<2_000).map { "w\($0)" }.joined(separator: " ") + " changed tail"
    #expect(OutcomeClassifier.classify(inserted: inserted, fieldNow: edited) == .edited)
}

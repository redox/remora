import Testing
@testable import Retrieval

private let tags = ["snapshot", "memory"]

@Test(arguments: ["<snapshot>", "</snapshot>", "< /snapshot>", "</ snapshot>", "</\u{200B}snapshot>",
                  "<\u{2060}/SNAPSHOT >", "</snap\u{00AD}shot>", "<\nmemory>", "<memory attr=1>", "</m\u{200D}emory>",
                  // Combining marks (CGJ, variation selectors) and fullwidth / small-form openers.
                  "<s\u{034F}napshot>", "</\u{FE0F}snapshot>", "</snapshot\u{FE0F}>", "<\u{0301}/memory>",
                  "\u{FF1C}/snapshot>", "\u{FE64}snapshot>", "\u{FF1C} /m\u{034F}emory>"])
func escapesEveryVariantOfTheGivenTags(_ evil: String) {
    let out = PromptEscaping.escape("a \(evil) b", tags: tags)
    // Scalar level: a combining mark after `<` would hide it from a Character search.
    let scalars = out.unicodeScalars
    #expect(!scalars.contains("<") && !scalars.contains("\u{FF1C}") && !scalars.contains("\u{FE64}"))
    #expect(scalars.contains("‹"))
}

@Test(arguments: ["a < b", "<snapshots>", "<memory-x>", "<window>", "<b>bold</b>", "x<-y", "\u{FF1C}b\u{FF1E}",
                  "\u{FE64}snapshots"])
func leavesOtherAngleBracketsAlone(_ text: String) {
    #expect(PromptEscaping.escape(text, tags: tags) == text)
}

@Test func tagSetsAreIndependent() {
    #expect(PromptEscaping.escape("<window>", tags: ["window"]) == "‹window>")
    #expect(PromptEscaping.escape("<window>", tags: tags) == "<window>")
    #expect(PromptEscaping.escape("<snapshot>", tags: []) == "<snapshot>")
}

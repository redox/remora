import Testing
@testable import Storage

@Test func ftsQueryQuotesTokensAndPrefixesLast() {
    #expect(FTSQuery.make(from: "hello world") == "\"hello\" \"world\"*")
}
@Test func ftsQuerySplitsOnPunctuation() {
    #expect(FTSQuery.make(from: "say \"hi") == "\"say\" \"hi\"*")
}
@Test func ftsQueryNilWhenNoTokens() {
    #expect(FTSQuery.make(from: "   ") == nil)
    #expect(FTSQuery.make(from: "-- &&") == nil)
    #expect(FTSQuery.make(from: "") == nil)
}

@Test func makeAnyJoinsWithOR() {
    #expect(FTSQuery.makeAny(terms: ["réunion", "Oslo"]) == "\"réunion\"* OR \"Oslo\"*")
    #expect(FTSQuery.makeAny(terms: ["", "  ", "-"]) == nil)
    #expect(FTSQuery.makeAny(terms: ["a b", "x\"y"]) == "\"a\" \"b\"* OR \"x\" \"y\"*")
}

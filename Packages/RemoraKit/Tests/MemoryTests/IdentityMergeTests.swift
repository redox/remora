import Foundation
import Storage
import Testing
@testable import Memory

private func rev(_ body: String, _ source: IdentitySource, _ n: Int) -> IdentityRevision {
    IdentityRevision(id: Int64(n), body: body, source: source, createdAt: date(2026, 11, n))
}

@Test func userAddedAndRemovedLines() {
    let llm = "A\nB\nC", user = "A\nC\nMy name is Kévin"
    #expect(IdentityMerge.userAdded(previousLLM: llm, user: user) == ["My name is Kévin"])
    #expect(IdentityMerge.userRemoved(previousLLM: llm, user: user) == ["B"])
}

@Test func comparisonIgnoresCaseAccentsAndWhitespace() {
    #expect(IdentityMerge.userAdded(previousLLM: "Lives in  Zürich", user: "lives in zurich") == [])
    #expect(IdentityMerge.lines("  a \n\n b\n") == ["a", "b"])
}

@Test func enforceRestoresKeptAndDropsRemoved() {
    let out = IdentityMerge.enforce(output: "A\nB\nD", mustKeep: ["My name is Kévin"], mustNotReintroduce: ["B"])
    #expect(out == "A\nD\n\n### Notes from you\nMy name is Kévin")
}

@Test func enforceCreatesTheNotesHeadingOnce() {
    let first = IdentityMerge.enforce(output: "A", mustKeep: ["X", "Y"], mustNotReintroduce: [])
    #expect(first == "A\n\n### Notes from you\nX\nY")
    // A model that echoes the heading and one line gets the missing one under the same heading.
    let second = IdentityMerge.enforce(output: "A\n\n### Notes from you\nX", mustKeep: ["X", "Y"], mustNotReintroduce: [])
    #expect(second.components(separatedBy: "### Notes from you").count == 2)
    #expect(second.contains("Y") && second.components(separatedBy: "X").count == 2)
}

@Test func laterUserRevisionWinsWhenALineIsAddedThenRemoved() {
    let history = [rev("A\nB", .llm, 1), rev("A\nB\nMine", .user, 2), rev("A\nB", .user, 3)]
    let c = IdentityMerge.constraints(history)
    #expect(!c.mustKeep.contains("Mine"))
    #expect(c.mustNotReintroduce == ["Mine"])
}

@Test func laterUserRevisionWinsWhenALineIsRemovedThenReAdded() {
    let history = [rev("A\nB", .llm, 1), rev("A", .user, 2), rev("A\nb", .user, 3)]
    let c = IdentityMerge.constraints(history)
    #expect(c.mustKeep == ["b"])
    #expect(c.mustNotReintroduce.isEmpty)
}

@Test func constraintsAccumulateOverAllUserRevisionsAcrossLLMRounds() {
    let history = [rev("A\nB", .llm, 1), rev("A\nB\nMine", .user, 2), rev("A\nB\nMine\nNew", .llm, 3),
                   rev("A\nMine\nNew", .user, 4)]
    let c = IdentityMerge.constraints(history)
    #expect(c.mustKeep == ["Mine"])
    #expect(c.mustNotReintroduce == ["B"])
}

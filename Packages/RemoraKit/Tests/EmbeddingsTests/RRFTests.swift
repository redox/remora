import Testing
@testable import Embeddings

@Test func rrfFusesRanks() {
    let f = RRF.fuse([["a", "b", "c"], ["c", "a"]])
    #expect(f.map(\.0) == ["a", "c", "b"])
    #expect(abs(f[0].1 - (1.0 / 61 + 1.0 / 62)) < 1e-12)
    #expect(abs(f[1].1 - (1.0 / 63 + 1.0 / 61)) < 1e-12)
}

@Test func rrfTiesKeepFirstAppearance() {
    #expect(RRF.fuse([["x", "y"], ["y", "x"]]).map(\.0) == ["x", "y"])
    #expect(RRF.k == 60)
}

@Test func rrfOfNothingIsEmpty() {
    #expect(RRF.fuse([[String]]()).isEmpty)
}

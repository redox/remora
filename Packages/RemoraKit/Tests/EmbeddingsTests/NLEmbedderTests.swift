import Foundation
import NaturalLanguage
import Testing
@testable import Embeddings

private func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

@Test(.enabled(if: NLContextualEmbedding(script: .latin)?.hasAvailableAssets == true))
func nlEmbedderProducesUnitVectors() async throws {
    let e = NLEmbedder(requestAssetsIfMissing: false)
    let id = try #require(await e.identity())
    #expect(id.dimension == 512)
    let fr = try await e.embed("Réunion budget à Oslo demain")
    let en = try await e.embed("Budget meeting in Oslo tomorrow")
    let x = try await e.embed("Recette de crêpes au sucre")
    #expect(fr.count == 512)
    #expect(abs(dot(fr, fr) - 1) < 1e-3)
    #expect(abs(dot(en, en) - 1) < 1e-3)
    // Record ranking quality for inspection because Apple's model revisions can change it.
    print("RANKING dot(fr,en)=\(dot(fr, en)) dot(fr,x)=\(dot(fr, x)) model=\(id.modelID) rev=\(id.revision)")
}

@Test func emptyTextThrowsEmptyInput() async throws {
    await #expect(throws: EmbeddingError.emptyInput) { _ = try await HashingEmbedder().embed("   ") }
}

@Test func hashingEmbedderIsDeterministicFoldedAndUnit() async throws {
    let h = HashingEmbedder()
    let a = try await h.embed("Réunion BUDGET")
    #expect(a == (try await h.embed("reunion budget")))
    #expect(abs(a.reduce(0) { $0 + $1 * $1 } - 1) < 1e-5)
    #expect(a.count == 64)
}

@Test func textCapCutsAtAWordBoundary() {
    let long = String(repeating: "abcd ", count: 400)
    let cut = NLEmbedder.capped(long)
    #expect(cut.count <= 1_000)
    #expect(long.hasPrefix(cut))
    #expect(NLEmbedder.capped("short") == "short")
}

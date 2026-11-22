import Testing
@testable import LLM

let spikeSlugs = ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol",
                  "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]

func catalog(_ slugs: [String]) -> [ModelInfo] { slugs.map { ModelInfo(slug: $0, displayName: $0) } }

private let spike = catalog(spikeSlugs)

@Test(arguments: [
    ("gpt-6.1-terra", "terra", [6, 1]), ("gpt-6-luna", "luna", [6]), ("gpt-5.6-sol", "sol", [5, 6]),
    ("gpt-6.2-astra", "astra", [6, 2]),
])
func modelInfoDerivesFamilyAndVersion(slug: String, family: String, version: [Int]) {
    let m = ModelInfo(slug: slug, displayName: "x")
    #expect(m.family == family && m.version == version)
}

@Test func slugWithoutFamilyOrVersion() {
    #expect(ModelInfo(slug: "gpt-reserve", displayName: "x").version == [])
    #expect(ModelInfo(slug: "plain", displayName: "x").family == nil)
    #expect(ModelInfo(slug: "gpt-6", displayName: "x").family == nil)
}

@Test func resolvesDefaultsOnSpikeCatalog() {
    #expect(ModelResolver.resolve(tier: .small, preferred: nil, catalog: spike)?.slug == "gpt-6-luna")
    #expect(ModelResolver.resolve(tier: .large, preferred: nil, catalog: spike)?.slug == "gpt-6.1-terra")
    #expect(ModelResolver.resolve(tier: .small, preferred: nil, catalog: spike)?.note == nil)
}

@Test func onDeviceResolvesToNil() {
    #expect(ModelResolver.resolve(tier: .onDevice, preferred: "gpt-6-luna", catalog: spike) == nil)
}

@Test func newerLunaWinsAutomatically() {
    let c = catalog(spikeSlugs + ["gpt-6.1-luna"])
    #expect(ModelResolver.resolve(tier: .small, preferred: nil, catalog: c)?.slug == "gpt-6.1-luna")
    // Listing order does not matter, only the version.
    let reversed = catalog(["gpt-6.1-luna"] + spikeSlugs)
    #expect(ModelResolver.resolve(tier: .small, preferred: nil, catalog: reversed)?.slug == "gpt-6.1-luna")
}

@Test func largeAutomaticFallsBackToHighestTerra() {
    let c = catalog(spikeSlugs.filter { $0 != "gpt-6.1-terra" } + ["gpt-6.3-terra"])
    #expect(ModelResolver.resolve(tier: .large, preferred: nil, catalog: c)?.slug == "gpt-6.3-terra")
}

@Test func listedPreferredIsUsedAsIs() {
    let r = ModelResolver.resolve(tier: .small, preferred: "gpt-6.2-sol", catalog: spike)
    #expect(r == ResolvedModel(slug: "gpt-6.2-sol", note: nil))
}

@Test func missingPreferredFallsBackWithinFamily() {
    let c = catalog(spikeSlugs.filter { $0 != "gpt-6.1-terra" })
    let r = ModelResolver.resolve(tier: .large, preferred: "gpt-6.1-terra", catalog: c)
    #expect(r?.slug == "gpt-5.6-terra")
    #expect(r?.note == "gpt-6.1-terra is no longer available; using gpt-5.6-terra.")
}

@Test func missingPreferredWithoutFamilyMatchUsesTheFirstListedModel() {
    let r = ModelResolver.resolve(tier: .large, preferred: "gpt-9-nova", catalog: spike)
    #expect(r?.slug == "gpt-6.2-sol")
    #expect(r?.note?.contains("gpt-9-nova is no longer available") == true)
}

@Test func emptyCatalogReturnsPreferredOrDefaultWithoutNote() {
    #expect(ModelResolver.resolve(tier: .large, preferred: "x-y", catalog: []) == ResolvedModel(slug: "x-y", note: nil))
    #expect(ModelResolver.resolve(tier: .large, preferred: nil, catalog: []) == ResolvedModel(slug: "gpt-6.1-terra", note: nil))
    #expect(ModelResolver.resolve(tier: .small, preferred: nil, catalog: []) == ResolvedModel(slug: "gpt-6-luna", note: nil))
}

@Test func smallAutomaticWithoutAnyLunaUsesFirstListedWithNote() {
    let r = ModelResolver.resolve(tier: .small, preferred: nil, catalog: catalog(["gpt-6-sol", "gpt-6-astra"]))
    #expect(r?.slug == "gpt-6-sol" && r?.note != nil)
}

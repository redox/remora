import Foundation
import Testing
@testable import LLM

private let table = PriceTable(models: ["m": ModelPrice(inputPer1M: 2, cachedInputPer1M: 0.5, outputPer1M: 8)])

@Test func costFormula() {
    let u = LLMUsage(inputTokens: 1_000_000, cachedInputTokens: 400_000, outputTokens: 100_000, reasoningTokens: 50_000)
    let c = table.cost(model: "m", usage: u, backend: .siwc)!
    #expect(abs(c - 2.2) < 1e-9)
}

@Test func missingCachedPriceFallsBackToInputPrice() {
    let t = PriceTable(models: ["m": ModelPrice(inputPer1M: 2, outputPer1M: 8)])
    let u = LLMUsage(inputTokens: 1_000_000, cachedInputTokens: 500_000, outputTokens: 0, reasoningTokens: 0)
    #expect(abs(t.cost(model: "m", usage: u, backend: .siwc)! - 2.0) < 1e-9)
}

@Test func noEntryMeansNilAndOnDeviceIsZero() {
    let u = LLMUsage(inputTokens: 10, cachedInputTokens: 0, outputTokens: 10, reasoningTokens: 0)
    #expect(PriceTable.empty.cost(model: "m", usage: u, backend: .siwc) == nil)
    #expect(PriceTable(models: ["m": ModelPrice(inputPer1M: 1)]).cost(model: "m", usage: u, backend: .siwc) == nil)
    #expect(PriceTable.empty.cost(model: "x", usage: u, backend: .onDevice) == 0)
}

@Test func templatePrefillsBuiltInPricesAndNullsUnknownModels() throws {
    let data = PriceTable.template(slugs: ["gpt-6.1-terra", "some-new-model"])
    let t = try JSONDecoder().decode(PriceTable.self, from: data)
    #expect(t.models["gpt-6.1-terra"] == PriceTable.builtIn.models["gpt-6.1-terra"])
    #expect(t.models["some-new-model"] == ModelPrice())
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("_comment") && text.contains("models.dev") && text.contains("long_context") && text.contains("null"))
}

@Test func builtInPricesMatchModelsDev() {
    let b = PriceTable.builtIn.models
    #expect(b["gpt-6-luna"] == ModelPrice(inputPer1M: 0.1, cachedInputPer1M: 0.01, outputPer1M: 0.5,
        longContext: LongContextPrice(aboveInputTokens: 272_000, inputPer1M: 0.2, cachedInputPer1M: 0.02, outputPer1M: 0.75)))
    #expect(b["gpt-6.1-terra"]?.inputPer1M == 1 && b["gpt-6.1-terra"]?.cachedInputPer1M == 0.05 && b["gpt-6.1-terra"]?.outputPer1M == 5)
    // Every model of the account catalog has a price.
    for slug in ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-astra",
                 "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
        #expect(b[slug]?.inputPer1M != nil && b[slug]?.outputPer1M != nil && b[slug]?.longContext != nil, "\(slug)")
    }
}

@Test func typicalRewriteCostsOnLunaAndTerra() {
    // 2,000 input tokens (500 cached) and 300 output tokens.
    let u = LLMUsage(inputTokens: 2_000, cachedInputTokens: 500, outputTokens: 300, reasoningTokens: 0)
    let luna = PriceTable.builtIn.cost(model: "gpt-6-luna", usage: u, backend: .siwc)!
    let terra = PriceTable.builtIn.cost(model: "gpt-6.1-terra", usage: u, backend: .siwc)!
    #expect(abs(luna - (1_500 * 0.1 + 500 * 0.01 + 300 * 0.5) / 1e6) < 1e-12)
    #expect(abs(terra - (1_500 * 1 + 500 * 0.05 + 300 * 5) / 1e6) < 1e-12)
}

@Test func longContextPricesTheWholeRequestAboveTheThreshold() {
    let t = PriceTable(models: ["m": ModelPrice(inputPer1M: 1, cachedInputPer1M: 0.1, outputPer1M: 5,
        longContext: LongContextPrice(aboveInputTokens: 272_000, inputPer1M: 2, cachedInputPer1M: 0.2, outputPer1M: 7.5))])
    let at = LLMUsage(inputTokens: 272_000, cachedInputTokens: 0, outputTokens: 1_000_000, reasoningTokens: 0)
    #expect(abs(t.cost(model: "m", usage: at, backend: .siwc)! - (0.272 + 5)) < 1e-9)
    let above = LLMUsage(inputTokens: 300_000, cachedInputTokens: 100_000, outputTokens: 1_000_000, reasoningTokens: 0)
    #expect(abs(t.cost(model: "m", usage: above, backend: .siwc)! - (0.2 * 2 + 0.1 * 0.2 + 7.5)) < 1e-9)
}

@Test func overlayIsPerFieldAndKeepsUnlistedModels() {
    let user = PriceTable(models: [
        "gpt-6-luna": ModelPrice(inputPer1M: 0.3),      // override one field
        "custom": ModelPrice(inputPer1M: 1, outputPer1M: 2),
    ])
    let m = PriceTable.builtIn.overlaid(by: user).models
    #expect(m["gpt-6-luna"]?.inputPer1M == 0.3)
    #expect(m["gpt-6-luna"]?.outputPer1M == 0.5)
    #expect(m["gpt-6-luna"]?.longContext == PriceTable.builtIn.models["gpt-6-luna"]?.longContext)
    #expect(m["custom"] == ModelPrice(inputPer1M: 1, outputPer1M: 2))
    #expect(m["gpt-6.1-terra"] == PriceTable.builtIn.models["gpt-6.1-terra"])
}

@Test func anOldAllNullTemplateKeepsBuiltInPrices() throws {
    let old = #"{"models":{"gpt-6-luna":{"input_per_1m":null,"cached_input_per_1m":null,"output_per_1m":null}}}"#
    let t = try JSONDecoder().decode(PriceTable.self, from: Data(old.utf8))
    #expect(PriceTable.builtIn.overlaid(by: t) == .builtIn)
}

@Test func fileDefaultsToBuiltInAndOverlaysTheUserFile() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "prices-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "p.json")
    let file = PriceTableFile(url: url)
    #expect(file.table() == .builtIn)
    try Data(#"{"models":{"gpt-6-luna":{"output_per_1m":9}}}"#.utf8).write(to: url)
    #expect(file.table().models["gpt-6-luna"]?.outputPer1M == 9)
    #expect(file.table().models["gpt-6-luna"]?.inputPer1M == 0.1)
}

@Test func aBrokenFileOnFirstLoadUsesBuiltIn() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "prices-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "p.json")
    try Data("{ broken".utf8).write(to: url)
    #expect(PriceTableFile(url: url).table() == .builtIn)
}

@Test func loadsFromFileAndFallsBackToEmpty() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "prices-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "model-prices.json")
    #expect(PriceTable.load(from: url) == .empty)
    try Data("not json".utf8).write(to: url)
    #expect(PriceTable.load(from: url) == .empty)
    try Data(#"{"models":{"m":{"input_per_1m":1,"output_per_1m":2}}}"#.utf8).write(to: url)
    #expect(PriceTable.load(from: url).models["m"] == ModelPrice(inputPer1M: 1, outputPer1M: 2))
}

@Test func fileReloadsWhenModificationDateChanges() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "prices-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "p.json")
    let file = PriceTableFile(url: url, defaults: .empty)
    #expect(file.table() == .empty)
    try Data(#"{"models":{"a":{"input_per_1m":1,"output_per_1m":1}}}"#.utf8).write(to: url)
    #expect(file.table().models.keys.sorted() == ["a"])
    try Data(#"{"models":{"b":{"input_per_1m":1,"output_per_1m":1}}}"#.utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
    #expect(file.table().models.keys.sorted() == ["b"])
}

@Test func fileKeepsLastGoodTableWhenDecodeFails() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "prices-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "p.json")
    let file = PriceTableFile(url: url, defaults: .empty)
    try Data(#"{"models":{"a":{"input_per_1m":1,"output_per_1m":1}}}"#.utf8).write(to: url)
    #expect(file.table().models.keys.sorted() == ["a"])
    try Data("{ broken".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
    #expect(file.table().models.keys.sorted() == ["a"])
    try FileManager.default.removeItem(at: url)
    #expect(file.table() == .empty)
}

import Foundation
import LLMTestSupport
import Testing
@testable import LLM

private func req(_ prompt: String = "hi", format: TextFormat = .text, tools: [FunctionTool] = []) -> LLMRequest {
    LLMRequest(model: FoundationModelsClient.modelID, instructions: "inst", input: [.user(prompt)], reasoning: nil, format: format, tools: tools)
}

@Test func foundationClientConvertsSnapshotsToDeltas() async throws {
    let model = FakeOnDeviceModel(snapshots: ["Bon", "Bonjour"])
    let r = await collect(FoundationModelsClient(model: model).stream(req()))
    #expect(r.error == nil)
    #expect(Array(r.events.prefix(2)) == [.textDelta("Bon"), .textDelta("jour")])
    guard case .completed(let u)? = r.events.last else { Issue.record("no completion"); return }
    #expect(u.cachedInputTokens == 0 && u.reasoningTokens == 0)
    #expect(u.outputTokens == TokenEstimate.count("Bonjour") && u.inputTokens > 0)
    #expect(model.calls.first?.prompt == "user: hi")
}

@Test func foundationClientRejectsOversizedInput() async {
    let model = FakeOnDeviceModel(snapshots: ["x"])
    let r = await collect(FoundationModelsClient(model: model).stream(req(String(repeating: "a", count: 20_000))))
    guard case .onDeviceUnavailable? = r.error else { Issue.record("got \(String(describing: r.error))"); return }
    #expect(r.events.isEmpty && model.calls.isEmpty)
}

@Test func foundationClientRefusesWhenUnavailable() async {
    let model = FakeOnDeviceModel(availability: .unavailable("Apple Intelligence is turned off."))
    let r = await collect(FoundationModelsClient(model: model).stream(req()))
    #expect(r.error == .onDeviceUnavailable(reason: "Apple Intelligence is turned off.") && model.calls.isEmpty)
}

@Test func foundationClientRejectsTools() async {
    let tool = FunctionTool(name: "t", description: "d", parameters: .object([:]))
    let model = FakeOnDeviceModel()
    let r = await collect(FoundationModelsClient(model: model).stream(req(tools: [tool])))
    #expect(r.error == .unsupported(param: "tools") && model.calls.isEmpty)
}

@Test func foundationClientAppendsSchemaToInstructions() async {
    let model = FakeOnDeviceModel(snapshots: ["{}"])
    let format = TextFormat.jsonSchema(name: "n", schema: .object(["type": .string("object")]), strict: true)
    _ = await collect(FoundationModelsClient(model: model).stream(req(format: format)))
    let i = model.calls.first?.instructions ?? ""
    #expect(i.hasPrefix("inst") && i.contains("Respond with only a JSON object matching this JSON Schema:") && i.contains(#""type":"object""#))
}

@Test func foundationClientMapsSystemErrorsToUnavailable() async {
    struct Boom: Error {}
    let model = FakeOnDeviceModel(snapshots: [], error: Boom())
    let r = await collect(FoundationModelsClient(model: model).stream(req()))
    guard case .onDeviceUnavailable? = r.error else { Issue.record("got \(String(describing: r.error))"); return }
}

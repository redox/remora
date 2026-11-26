import Foundation
import Testing
@testable import LLM

private let spike = spikeSlugs.map { ModelInfo(slug: $0, displayName: $0) }
private let onDeviceJob = RoutingConfig(jobTiers: [.queryExpansion: .onDevice])

@Test func onDeviceJobFallsBackToSmallWhenUnavailable() {
    let r = LLMRouter.routes(job: .queryExpansion, config: onDeviceJob, catalog: spike, onDevice: .unavailable("off"))
    #expect(r.map(\.model) == ["gpt-6-luna"])
}

@Test func onDeviceJobTriesOnDeviceFirstWithNoEffort() {
    let r = LLMRouter.routes(job: .queryExpansion, config: onDeviceJob, catalog: spike, onDevice: .available)
    #expect(r.map(\.backend) == [.onDevice, .siwc] && r[0].model == FoundationModelsClient.modelID)
    #expect(r[0].effort == nil && r[1].effort == .low && r[1].tier == .small)
}

@Test func onDeviceDisabledSkipsIt() {
    let r = LLMRouter.routes(job: .queryExpansion, config: RoutingConfig(jobTiers: [.queryExpansion: .onDevice], onDeviceEnabled: false), catalog: spike, onDevice: .available)
    #expect(r.map(\.backend) == [.siwc])
}

@Test func largeTierNeverDowngrades() {
    let r = LLMRouter.routes(job: .rewrite, config: .init(), catalog: spike, onDevice: .available)
    #expect(r.map(\.model) == ["gpt-6.1-terra"] && r[0].effort == .low)
    // Even without a large model in the catalog, no small model is substituted by tier.
    let r2 = LLMRouter.routes(job: .rewrite, config: .init(), catalog: [ModelInfo(slug: "gpt-6-luna", displayName: "l")], onDevice: .available)
    #expect(r2.count == 1 && r2[0].tier == .large)
}

@Test func smallTierGivesOnlySmall() {
    let r = LLMRouter.routes(job: .salientFlags, config: .init(), catalog: spike, onDevice: .available)
    #expect(r.map(\.tier) == [.small])
}

@Test func overridesAndPickerApply() {
    let cfg = RoutingConfig(tierModels: [.small: "gpt-5.6-luna"], jobTiers: [.rewrite: .small])
    let catalog = spike + [ModelInfo(slug: "gpt-5.6-luna", displayName: "x")]
    #expect(LLMRouter.routes(job: .rewrite, config: cfg, catalog: catalog, onDevice: .available).map(\.model) == ["gpt-5.6-luna"])
}

@Test func chatOmitsReasoning() {
    #expect(LLMRouter.routes(job: .chat, config: .init(), catalog: spike, onDevice: .available).first?.effort == nil)
}

@Test func routingConfigRoundTripsAndToleratesUnknownKeys() throws {
    let cfg = RoutingConfig(tierModels: [.large: "gpt-6.1-terra"], jobTiers: [.chat: .small], onDeviceEnabled: false)
    #expect(try JSONDecoder().decode(RoutingConfig.self, from: JSONEncoder().encode(cfg)) == cfg)
    let odd = #"{"tierModels":{"huge":"x","small":"s"},"jobTiers":{"nope":"small","chat":"mega"}}"#
    let d = try JSONDecoder().decode(RoutingConfig.self, from: Data(odd.utf8))
    #expect(d.tierModels == [.small: "s"] && d.jobTiers.isEmpty && d.onDeviceEnabled)
}

@Test func onlyLocalMeetingNotesDefaultToOnDevice() {
    #expect(JobType.allCases.filter { $0.defaultTier == .onDevice } == [.meetingNotes])
    let config = RoutingConfig(jobTiers: [.meetingNotes: .large])
    #expect(LLMRouter.routes(job: .meetingNotes, config: config, catalog: spike, onDevice: .available).map(\.backend) == [.onDevice])
    #expect(LLMRouter.routes(job: .meetingNotes, config: config, catalog: spike, onDevice: .unavailable("off")).isEmpty)
    let r = LLMRouter.routes(job: .queryExpansion, config: .init(), catalog: spike, onDevice: .available)
    #expect(r.map(\.backend) == [.siwc] && r[0].model == "gpt-6-luna")
}

@Test func cloudNotAllowedRoutesOnlyOnDeviceAndFailsClosed() {
    for job in [JobType.rewrite, .queryExpansion, .chat] {
        let r = LLMRouter.routes(job: job, config: .init(), catalog: spike, onDevice: .available, cloudAllowed: false)
        #expect(r.map(\.backend) == [.onDevice])
        #expect(LLMRouter.routes(job: job, config: .init(), catalog: spike, onDevice: .unavailable("off"), cloudAllowed: false).isEmpty)
    }
    #expect(LLMRouter.routes(job: .rewrite, config: .init(onDeviceEnabled: false), catalog: spike, onDevice: .available, cloudAllowed: false).isEmpty)
}

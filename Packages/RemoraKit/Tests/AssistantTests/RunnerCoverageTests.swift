import Embeddings
import Foundation
import LLM
import LLMTestSupport
import Memory
import Testing
@testable import Assistant
import Storage

/// The app's runner map is `MemoryRunners.make` merged with `ProactiveRunners.make`: every job kind
/// must have exactly one runner, or its rows stay pending forever (Task 11 fix: `digest_rebuild`).
@Test func everyJobKindHasExactlyOneRunner() throws {
    let db = try AppDatabase.inMemory()
    let llm = service(FakeLLMClient(backend: .siwc, script: []), db: db)
    let memory = MemoryRunners.make(db: db, llm: llm, embedder: HashingEmbedder(), backgroundEmbedder: HashingEmbedder(),
                                    dbURL: nil, calendar: PeriodKey.localCalendar)
    let proactive = ProactiveRunners.make(db: db, llm: llm, inbox: ProactiveInbox(db: db, onDelivered: { _ in }),
                                          policy: { .denyAll }, canInterrupt: { false })
    #expect(Set(memory.keys).isDisjoint(with: proactive.keys))
    #expect(Set(memory.keys).union(proactive.keys) == Set(JobKind.allCases))
    #expect(memory[.digestRebuild] is DigestRebuildRunner)
}

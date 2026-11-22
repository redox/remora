import Capture
import Embeddings
import Foundation
import Storage
import Testing
@testable import Retrieval

private func request(field: String = "", title: String? = "Draft", live: String? = nil, app: String = "Mail",
                     surface: String = "mail", memory: Bool = true, cloud: Bool = true) -> ContextRequest {
    ContextRequest(fieldText: field, windowTitle: title, liveWindowText: live, app: app, bundleID: nil,
                   surface: surface, memoryAllowed: memory, now: memNow, cloudAllowed: cloud)
}

private func assembler(_ db: AppDatabase, expander: any QueryExpander = NoExpansion(),
                       budget: ContextBudget = .init()) -> ContextAssembler {
    ContextAssembler(db: db, budget: budget,
                     search: HybridSearch(db: db, embedder: nil, index: nil, policy: { SnapshotPolicy.current(db) }),
                     expander: expander)
}

@Test func baseMemoryCombinesStarAndSurfaceStyle() throws {
    let db = try AppDatabase.inMemory()
    try StyleNoteStore(db).upsert(surface: "*", notes: "- No exclamation marks", llmCallID: nil, at: memNow)
    try StyleNoteStore(db).upsert(surface: "mail", notes: "- Tutoiement with Marc", llmCallID: nil, at: memNow)
    try StyleNoteStore(db).upsert(surface: "slack", notes: "- Lowercase", llmCallID: nil, at: memNow)
    let mail = try MemoryContext.base(db: db, surface: "mail", now: memNow)
    #expect(mail.style == "- No exclamation marks\n- Tutoiement with Marc")
    let other = try MemoryContext.base(db: db, surface: "notes", now: memNow)
    #expect(other.style == "- No exclamation marks")
    let star = try MemoryContext.base(db: db, surface: "*", now: memNow)
    #expect(star.style == "- No exclamation marks")
    #expect(try MemoryContext.base(db: try AppDatabase.inMemory(), surface: "mail", now: memNow) == .empty)
}

@Test func baseMemoryDropsWorkingMemoryWhoseSnapshotsAreAllExcludedOrGone() throws {
    let db = try AppDatabase.inMemory()
    let slack = try seedSnapshot(db, "x", app: "Slack", bundleID: "com.tinyspeck.slackmacgap")
    let mail = try seedSnapshot(db, "y", app: "Mail")
    try seedWorkingMemory(db, [("Slack thread item", [try #require(slack.id)]),
                               ("Mixed item", [try #require(slack.id), try #require(mail.id)]),
                               ("Deleted evidence item", [999]),
                               ("No evidence item", [])])
    try ExclusionStore(db).add("app:Slack")
    let base = try MemoryContext.base(db: db, surface: "mail", now: memNow)
    #expect(base.workingMemory == ["Mixed item", "No evidence item"])
    // Unloadable exclusions fail closed (final review #5): no item at all, not even one citing nothing.
    let denied = try MemoryContext.base(db: db, surface: "mail", now: memNow, policy: .denyAll)
    #expect(denied.workingMemory.isEmpty)
}

@Test func contextIncludesDigestIdentityWorkingMemoryAndHits() async throws {
    let db = try AppDatabase.inMemory()
    try seedDigest(db, "Working on the Oslo offsite this week.")
    try IdentityStore(db).saveUserEdit("Product manager at Acme.", at: memNow)
    try seedWorkingMemory(db, [("Send Marc the Oslo deck", [])])
    try StyleNoteStore(db).upsert(surface: "mail", notes: "Short.", llmCallID: nil, at: memNow)
    let chronicle = try seedChronicle(db, key: "2027-01-15T10+0100", summary: "Planned the Oslo offsite budget")
    try seedPage(db, slug: "oslo-offsite", title: "Oslo offsite", summary: "Team offsite in Oslo, March")
    try seedFlag(db, .commitment, "Send the Oslo deck", person: "Marc", due: memNow.addingTimeInterval(2 * 86_400))

    let c = try await assembler(db).context(for: request(field: "About the Oslo offsite", live: "window"))
    #expect(c.windowText == "window")
    #expect(c.memory.digest == "Working on the Oslo offsite this week.")
    #expect(c.memory.identity == "Product manager at Acme.")
    #expect(c.memory.workingMemory == ["Send Marc the Oslo deck"])
    #expect(c.memory.style == "Short." && c.styleNote == "Short.")
    #expect(c.hits.contains { $0.scope == .chronicle && $0.id == chronicle.id })
    #expect(c.hits.contains { $0.scope == .wikiPage && $0.slug == "oslo-offsite" })
    #expect(c.pages == [WikiPageBrief(slug: "oslo-offsite", title: "Oslo offsite", type: .project,
                                      summary: "Team offsite in Oslo, March")])
    #expect(c.openItems.count == 1 && c.openItems[0].hasPrefix("commitment: Send the Oslo deck (Marc, due "))
}

@Test func openItemsMatchTermsOrAreDueSoon() async throws {
    let db = try AppDatabase.inMemory()
    try seedFlag(db, .todo, "Book the venue", project: "Oslo offsite")
    try seedFlag(db, .event, "Dentist", due: memNow.addingTimeInterval(3 * 86_400))
    try seedFlag(db, .todo, "Renew passport", due: memNow.addingTimeInterval(30 * 86_400))
    try seedFlag(db, .commitment, "Unrelated promise")
    let c = try await assembler(db).context(for: request(field: "Oslo offsite plans"))
    #expect(c.openItems.contains("todo: Book the venue"))
    #expect(c.openItems.contains { $0.hasPrefix("event: Dentist (due ") })
    #expect(!c.openItems.contains { $0.contains("passport") || $0.contains("Unrelated") })
}

@Test func frenchQueryFindsEnglishChronicleViaExpansion() async throws {
    let db = try AppDatabase.inMemory()
    let english = try seedChronicle(db, key: "h1", summary: "Weekly team meeting about hiring")
    let expander = RecordingExpander(added: ["réunion": ["meeting"]])
    let none = try await assembler(db).context(for: request(field: "Compte rendu de la réunion"))
    #expect(!none.hits.contains { $0.id == english.id })
    let c = try await assembler(db, expander: expander).context(for: request(field: "Compte rendu de la réunion"))
    #expect(c.hits.contains { $0.scope == .chronicle && $0.id == english.id })
    #expect(expander.calls.count == 1 && expander.calls[0].terms.contains("réunion"))
}

@Test func expansionUsesTheRewritesOwnCloudPermission() async throws {
    let db = try AppDatabase.inMemory()
    let expander = RecordingExpander()
    _ = try await assembler(db, expander: expander).context(for: request(field: "Oslo offsite", cloud: true))
    _ = try await assembler(db, expander: expander).context(for: request(field: "Oslo offsite", cloud: false))
    #expect(expander.calls.map(\.cloudAllowed) == [true, false])
    // Fails closed: a request that does not say gets on-device-only expansion.
    let unstated = ContextRequest(fieldText: "Oslo offsite", windowTitle: nil, liveWindowText: nil, app: "Mail", bundleID: nil,
                                  surface: "mail", memoryAllowed: true, now: memNow)
    #expect(!unstated.cloudAllowed)
    _ = try await assembler(db, expander: expander).context(for: unstated)
    #expect(expander.calls.map(\.cloudAllowed) == [true, false, false])
}

@Test func queryTextIsRedactedBeforeExpansionAndSearch() async throws {
    let db = try AppDatabase.inMemory()
    let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    let expander = RecordingExpander()
    // Field text present: field and title are the query.
    _ = try await assembler(db, expander: expander)
        .context(for: request(field: "Rotate \(token) for the roadmap", title: "Deploy \(token)"))
    // Empty field: title and window are the query.
    _ = try await assembler(db, expander: expander)
        .context(for: request(field: "", title: "Deploy \(token) roadmap", live: "Window about the roadmap"))
    #expect(expander.calls.count == 2)
    for call in expander.calls {
        #expect(!call.terms.contains { $0.contains("abcdefghijklmnopqrstuvwxyz") || $0 == "ghp" })
        #expect(call.terms.contains("roadmap"))
    }
}

@Test func onePolicyLoadPerRewrite() async throws {
    let db = try AppDatabase.inMemory()
    try seedSnapshot(db, "Roadmap review", app: "Notes", ago: 7_200)
    try seedChronicle(db, key: "h", summary: "Roadmap review")
    let loads = Counter(), searchLoads = Counter()
    let a = ContextAssembler(db: db, search: HybridSearch(db: db, embedder: nil, index: nil,
                                                          policy: { searchLoads.increment(); return openPolicy() }),
                             policy: { loads.increment(); return openPolicy() })
    let c = try await a.context(for: request(field: "roadmap"))
    #expect(!c.hits.isEmpty && !c.related.isEmpty)
    #expect(loads.value == 1 && searchLoads.value == 0)
}

@Test func excludedSnapshotsNotInContext() async throws {
    let db = try AppDatabase.inMemory()
    // Captured before the exclusion existed.
    let secret = try seedSnapshot(db, "Roadmap secret plans in the private channel", app: "Slack",
                                  bundleID: "com.tinyspeck.slackmacgap", title: "Private", ago: 7_200)
    let fresh = try seedSnapshot(db, "Fresh roadmap chatter", app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                 title: "General", ago: 120)
    let site = try seedSnapshot(db, "Roadmap on the bank site", app: "Safari", bundleID: "com.apple.Safari",
                                title: "Bank", domain: "bank.example", url: "https://bank.example/x", ago: 300)
    let notes = try seedSnapshot(db, "Roadmap review on Thursday", app: "Notes", title: "Roadmap", ago: 7_200)
    try seedSnapshot(db, "Recent note about lunch", app: "Notes", title: "Lunch", ago: 200)
    let ids = [secret.id, fresh.id, site.id].compactMap { $0 }
    let notesID = try #require(notes.id)
    try seedChronicle(db, key: "h-secret", summary: "Roadmap secret discussed", snapshotIDs: [ids[0]])
    try seedWorkingMemory(db, [("Roadmap secret item", [ids[1]]), ("Roadmap notes item", [notesID])])
    try seedFlag(db, .todo, "Roadmap secret follow-up", snapshotIDs: [ids[0]])
    try seedFlag(db, .todo, "Roadmap notes follow-up", snapshotIDs: [notesID])
    try ExclusionStore(db).add("app:Slack")
    try ExclusionStore(db).add("bank.example")

    let c = try await assembler(db).context(for: request(field: "roadmap"))
    let shown = (c.related + c.recent).map(\.app)
    #expect(!shown.contains("Slack") && !shown.contains("Safari"))
    #expect(c.related.contains { $0.app == "Notes" } && c.recent.contains { $0.text.contains("lunch") })
    #expect(!c.hits.contains { $0.snippet.contains("secret") })
    #expect(c.memory.workingMemory == ["Roadmap notes item"])
    #expect(c.openItems == ["todo: Roadmap notes follow-up"])

    // Exclusions that cannot be loaded: nothing captured or cited reaches the context.
    let denied = try await ContextAssembler(db: db, search: HybridSearch(db: db, embedder: nil, index: nil, policy: { .denyAll }),
                                            policy: { .denyAll })
        .context(for: request(field: "roadmap"))
    #expect(denied.related.isEmpty && denied.recent.isEmpty && denied.hits.isEmpty)
    #expect(denied.memory.workingMemory.isEmpty && denied.openItems.isEmpty)
}

@Test func memoryNotAllowedStillReturnsWindowOnly() async throws {
    let db = try AppDatabase.inMemory()
    try seedSnapshot(db, "roadmap review notes", ago: 60)
    try seedDigest(db, "Digest")
    try IdentityStore(db).saveUserEdit("Identity", at: memNow)
    try seedWorkingMemory(db, [("Roadmap item", [])])
    try seedChronicle(db, key: "h", summary: "Roadmap review")
    try seedFlag(db, .todo, "Roadmap follow-up", due: memNow.addingTimeInterval(86_400))
    try StyleNoteStore(db).upsert(surface: "*", notes: "style", llmCallID: nil, at: memNow)
    let expander = RecordingExpander()
    let a = assembler(db, expander: expander)
    let c = try await a.context(for: request(field: "roadmap review", live: "window", memory: false))
    #expect(c == RewriteContext(windowText: "window", related: [], recent: [], styleNote: nil))
    #expect(c.memory == .empty && c.hits.isEmpty && c.pages.isEmpty && c.openItems.isEmpty)
    #expect(expander.calls.isEmpty)
    let none = try await a.context(for: request(field: "roadmap review", live: nil, memory: false))
    #expect(none == .empty)
}

@Test func contextRespectsNewBudgets() async throws {
    let db = try AppDatabase.inMemory()
    try seedDigest(db, String(repeating: "digest ", count: 3_000))
    try IdentityStore(db).saveUserEdit(String(repeating: "identity ", count: 2_000), at: memNow)
    try seedWorkingMemory(db, (0..<12).map { ("Working item number \($0)", []) })
    for i in 0..<10 {
        try seedChronicle(db, key: "h\(i)", summary: "Roadmap " + String(repeating: "details ", count: 200),
                          start: memNow.addingTimeInterval(-Double(i + 2) * 3_600))
        try seedPage(db, slug: "roadmap-\(i)", title: "Roadmap \(i)", summary: "Roadmap page \(i)")
        try seedFlag(db, .todo, "Roadmap task \(i)")
    }
    let c = try await assembler(db).context(for: request(field: "roadmap"))
    let b = ContextBudget()
    #expect(b.digestChars == 6_000 && b.identityChars == 4_000 && b.workingMemoryMax == 8 && b.hitsMax == 6
            && b.hitsChars == 4_000 && b.pagesMax == 3 && b.openItemsMax == 5)
    #expect((c.memory.digest?.count ?? 0) > 0 && (c.memory.digest?.count ?? .max) <= 6_000)
    #expect((c.memory.identity?.count ?? 0) > 0 && (c.memory.identity?.count ?? .max) <= 4_000)
    #expect(c.memory.workingMemory.count == 8)
    #expect(!c.hits.isEmpty && c.hits.count <= 6 && c.hits.map(\.snippet.count).reduce(0, +) <= 4_000)
    #expect(c.pages.count == 3)
    #expect(c.openItems.count == 5)
}

@Test func memoryAssemblyIsTimeBounded() async throws {
    // The base memory never finishes (its policy load is held until the end of the test): past the
    // memory budget the context is the window only. No wall-clock assertion: the budget is tiny.
    let db = try AppDatabase.inMemory()
    try seedDigest(db, "Digest")
    var budget = ContextBudget()
    budget.memoryTimeout = .milliseconds(20)
    let held = DispatchSemaphore(value: 0)
    let a = ContextAssembler(db: db, budget: budget, policy: { held.wait(); return openPolicy() })
    let c = try await a.context(for: request(field: "roadmap review", live: "window"))
    held.signal()
    #expect(c == RewriteContext(windowText: "window", related: [], recent: [], styleNote: nil))
    #expect(ContextBudget().memoryTimeout == .milliseconds(1_500) && ContextBudget().expansionTimeout == .milliseconds(1_200))
}

@Test func timeoutKeepsTheLoadedBaseMemory() async throws {
    // The base loads at once; expansion never returns (ignoring cancellation). On the time-out the
    // style, digest, identity and working memory stay; hits, related, recent and open items go.
    let db = try AppDatabase.inMemory()
    try seedDigest(db, "Digest text")
    try IdentityStore(db).saveUserEdit("Identity text", at: memNow)
    try seedWorkingMemory(db, [("Roadmap item", [])])
    try StyleNoteStore(db).upsert(surface: "mail", notes: "Short.", llmCallID: nil, at: memNow)
    try seedSnapshot(db, "Roadmap review", app: "Notes", ago: 120)
    try seedChronicle(db, key: "h", summary: "Roadmap review")
    try seedFlag(db, .todo, "Roadmap follow-up", due: memNow.addingTimeInterval(86_400))
    var budget = ContextBudget()
    // 1 s (final review #16): enough for the base to load on a loaded CI machine.
    budget.memoryTimeout = .seconds(1)
    let c = try await assembler(db, expander: RecordingExpander(hang: true), budget: budget)
        .context(for: request(field: "roadmap review", live: "window"))
    #expect(c == RewriteContext(windowText: "window",
                                memory: BaseMemory(digest: "Digest text", identity: "Identity text",
                                                   workingMemory: ["Roadmap item"], style: "Short.")))
}

@Test func timeBoundReturnsNilPastTheDeadlineAndTheValueOtherwise() async {
    let slow = await TimeBound.run(within: .milliseconds(10)) { () async -> Int in
        await Task.detached { try? await Task.sleep(for: .seconds(3_600)) }.value
        return 1
    }
    #expect(slow == nil)
    let fast = await TimeBound.run(within: .seconds(60)) { 42 }
    #expect(fast == 42)
}

@Test func forgetWithholdsTheDigestUntilARebuildClearsTheMark() throws {
    let db = try AppDatabase.inMemory()
    try seedDigest(db, "Working on the Oslo offsite this week.")
    let snap = try seedSnapshot(db, "x", app: "Mail")
    try SnapshotStore(db).delete(ids: [try #require(snap.id)], now: memNow)
    // No rebuild ran: the stale digest must not reach a prompt.
    #expect(try MemoryContext.base(db: db, surface: "mail", now: memNow).digest == nil)
    try SettingsStore(db).setValue(Date?.none, forKey: ForgetMarks.digestDirtyKey)
    #expect(try MemoryContext.base(db: db, surface: "mail", now: memNow).digest == "Working on the Oslo offsite this week.")
}

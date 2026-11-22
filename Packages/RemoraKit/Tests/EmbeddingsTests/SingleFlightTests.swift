import Testing
@testable import Embeddings

/// Final review #14 (`SharedEmbedder`): concurrent callers share one request, and a late waiter of
/// an old request never clears a newer one.
@Test func lateWaiterNeverClearsANewerRequest() {
    var slot = SingleFlight<String>()
    var made = 0
    let first = slot.join { made += 1; return "r1" }
    let joined = slot.join { made += 1; return "unused" }
    #expect(first.request == "r1" && joined.request == "r1" && joined.token == first.token && made == 1)

    // r1 finishes: its first waiter clears the slot and a new request starts.
    slot.finish(first.token)
    let second = slot.join { made += 1; return "r2" }
    #expect(second.request == "r2" && made == 2)

    // The other waiter of r1 resumes late: r2 stays in flight and is shared.
    slot.finish(joined.token)
    #expect(slot.current == "r2")
    #expect(slot.join { made += 1; return "r3" }.request == "r2" && made == 2)

    slot.finish(second.token)
    #expect(slot.current == nil)
}

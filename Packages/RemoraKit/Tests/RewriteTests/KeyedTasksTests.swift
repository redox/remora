import Testing
@testable import Rewrite

@MainActor @Test func rescheduledKeyKeepsTheNewTask() async {
    let tasks = KeyedTasks<Int64>()
    let first = tasks.run(1) { try? await Task.sleep(for: .seconds(60)) }
    tasks.run(1) { try? await Task.sleep(for: .seconds(60)) }
    // The replaced task ends (cancelled); its cleanup must not drop the task that replaced it.
    await first.value
    #expect(tasks.isPending(1))
    tasks.cancelAll()
    #expect(!tasks.isPending(1))
}

@MainActor @Test func finishedTaskIsForgotten() async {
    let tasks = KeyedTasks<Int64>()
    await tasks.run(7) {}.value
    #expect(!tasks.isPending(7))
    let pending = tasks.run(8) { try? await Task.sleep(for: .seconds(60)) }
    tasks.cancel(8)
    await pending.value
    #expect(!tasks.isPending(8))
}

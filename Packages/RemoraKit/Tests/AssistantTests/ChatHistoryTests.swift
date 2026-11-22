import Foundation
import LLM
import Storage
import Testing
@testable import Assistant

private func turn(_ id: Int64, _ role: ChatRole, _ text: String, _ status: ChatTurnStatus = .complete,
                  inbox: Int64? = nil, tools: [ToolTrace] = []) -> ChatTurn {
    ChatTurn(id: id, createdAt: Date(timeIntervalSince1970: TimeInterval(id)), role: role, text: text, status: status,
             tools: tools, inboxID: inbox)
}

@Suite struct ChatHistoryTests {
    @Test func historyTrimsOldestToBudgetAndSkipsEmptyFailures() {
        let long = String(repeating: "a", count: 300) // 100 tokens each
        let turns = [
            turn(1, .user, "oldest " + long), turn(2, .assistant, "old answer " + long),
            turn(3, .user, "q2"), turn(4, .assistant, "", .failed),
            turn(5, .user, "q3"), turn(6, .assistant, "partial", .cancelled),
            turn(7, .user, "q4"), turn(8, .assistant, "", .pending),
            turn(9, .user, "q5"), turn(10, .assistant, "a5"),
        ]
        let (items, earlier) = ChatHistory.input(turns: turns, summary: nil, budgetTokens: 150)
        #expect(earlier == nil)
        // Turns 1 and 2 cost ~104 tokens each: turn 2 still fits (8 + 104), turn 1 does not.
        #expect(items == [.assistant("old answer " + long), .user("q2"), .user("q3"), .assistant("partial"), .user("q4"),
                          .user("q5"), .assistant("a5")])
        #expect(!items.contains(.user("oldest " + long)))
        #expect(!items.contains(.assistant("")))
        let total = items.reduce(0) { n, item in
            switch item { case .user(let s), .assistant(let s): n + TokenEstimate.count(s); default: n }
        }
        #expect(total <= 150)
    }

    @Test func budgetKeepsNewestFirstInChronologicalOrder() {
        let turns = (1...6).map { turn(Int64($0), $0 % 2 == 1 ? .user : .assistant, "msg \($0)") }
        let (items, _) = ChatHistory.input(turns: turns, summary: nil, budgetTokens: TokenEstimate.count("msg 6") * 3)
        #expect(items == [.assistant("msg 4"), .user("msg 5"), .assistant("msg 6")])
    }

    @Test func historyNeverReplaysToolOutputs() {
        let turns = [turn(1, .user, "find Oslo"),
                     turn(2, .assistant, "Found it", tools: [ToolTrace(name: "search_memory", ok: true)])]
        let (items, _) = ChatHistory.input(turns: turns, summary: nil, budgetTokens: 10_000)
        #expect(items == [.user("find Oslo"), .assistant("Found it")])
        for item in items {
            switch item {
            case .user, .assistant: break
            default: Issue.record("tool item replayed")
            }
        }
    }

    @Test func inboxTurnsArePrefixedWithTheirKind() {
        let turns = [turn(1, .assistant, "Good morning", inbox: 7), turn(2, .user, "thanks")]
        let (items, _) = ChatHistory.input(turns: turns, summary: nil, budgetTokens: 10_000,
                                           inboxKinds: [7: .morningBrief])
        #expect(items == [.assistant("[Morning brief] Good morning"), .user("thanks")])
    }

    @Test func summaryBecomesEarlierAndFoldedTurnsAreLeftOut() {
        var folded = turn(1, .user, "old")
        folded.folded = true
        let summary = ChatSummary(throughTurnID: 1, body: "They planned Oslo.", createdAt: Date())
        let (items, earlier) = ChatHistory.input(turns: [folded, turn(2, .user, "new")], summary: summary,
                                                 budgetTokens: 10_000)
        #expect(earlier == "They planned Oslo.")
        #expect(items == [.user("new")])
    }
}

import LLM
import Redaction
import Storage

struct UpdateRoutineTool: ActionTool {
    let deps: ActionDeps
    var risk: ActionRisk { .confirm }

    var definition: FunctionTool {
        FunctionTool(
            name: "update_routine",
            description: "Rename or dismiss a detected routine at the user's request. Every change requires confirmation.",
            parameters: JSONOut.schema([
                "id": JSONOut.string("A routine id returned by find_routines"),
                "operation": JSONOut.string("rename or dismiss", enum: ["rename", "dismiss"]),
                "label": JSONOut.string("The user's corrected name for rename, or an empty string for dismiss"),
            ]))
    }

    func plan(_ args: Args, context: ToolContext) async throws -> ActionPlan {
        let id = try args.string("id")
        guard id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ToolFailure("Use a routine id from find_routines.")
        }
        let operation = try args.string("operation")
        let label = Redactor().redact(try args.string("label").split(whereSeparator: \.isWhitespace).joined(separator: " "))
        let feedback: RoutineFeedback
        switch operation {
        case "rename" where !label.isEmpty && label.count <= maxTitleChars: feedback = .label(label)
        case "rename": throw ToolFailure("Give a corrected name of 1 to \(maxTitleChars) characters.")
        case "dismiss" where label.isEmpty: feedback = .dismissed
        default: throw ToolFailure("Use rename with a name or dismiss with an empty label.")
        }

        let db = deps.db
        let (candidate, result, before) = try await db.reader.read { d in
            let result = try RoutineSuggestions.find(db: db, now: context.now, calendar: context.calendar, in: d)
            guard let candidate = result.candidates.first(where: { $0.id == id }) else {
                throw ToolFailure("That routine is no longer available. Search for routines again.")
            }
            return (candidate, result, try RoutineSuggestions.storedFeedback(db, in: d)[id])
        }
        let pair = candidate.latest.first.description + " followed by " + candidate.latest.second.description
        let date = LocalTime.day(candidate.latest.day, context.calendar)
        let summary: String
        let receipt: String
        switch feedback {
        case .label(let label):
            summary = "Rename the routine \(pair), last seen \(date), to \(quoted(label))"
            receipt = "Routine renamed to \(quoted(label))"
        case .dismissed:
            summary = "Dismiss the routine \(pair), last seen \(date)"
            receipt = "Routine dismissed"
        }
        return ActionPlan(summary: summary, risk: risk) { p in
            try DataGeneration.write(db, expected: p.generation) { d in
                guard try result.stillValid([candidate], in: d) else {
                    throw ToolFailure("The routine evidence changed while waiting. Search for routines again.")
                }
                var entries = try RoutineSuggestions.storedFeedback(db, in: d)
                guard entries[id] == before else {
                    throw ToolFailure("The routine changed while waiting. Search for routines again.")
                }
                entries[id] = feedback
                try SettingsStore(db).setValue(entries, forKey: RoutineFeedback.settingsKey, in: d)
            }
            return ActionOutcome(fields: [:], receipt: receipt, undo: nil, change: .routines)
        }
    }
}

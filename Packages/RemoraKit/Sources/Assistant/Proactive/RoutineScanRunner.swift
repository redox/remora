import Capture
import Foundation
import GRDB
import Memory
import Storage

/// The automatic counterpart to `find_routines`. It runs the same local search and posts only
/// previously unseen patterns to the inbox, without calling a model or posting a system banner.
struct RoutineScanRunner: JobRunner {
    static let historyDays = 7
    static let retryableSkips: Set<String> = ["disabled", "evidence changed", "inbox unavailable"]
    private static let maxFindings = 3

    let db: AppDatabase
    let inbox: ProactiveInbox

    /// The seven-day gate measures elapsed history, with local calendar days across DST. The
    /// scan itself applies current exclusions and requires evidence on three separate days.
    static func hasHistory(_ db: AppDatabase, at now: Date, calendar: Calendar) throws -> Bool {
        guard let cutoff = calendar.date(byAdding: .day, value: -historyDays, to: now) else { return false }
        return try db.reader.read { d in
            try Bool.fetchOne(d, sql: "SELECT 1 FROM activity_events WHERE started_at <= ? AND window_title IS NOT NULL LIMIT 1",
                              arguments: [cutoff]) ?? false
        }
    }

    func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        let now = context.now, calendar = context.calendar
        guard job.kind == .routineScan, job.periodKey == PeriodKey.key(.week, for: now, calendar: calendar) else {
            return .skipped("window passed")
        }
        guard try Self.hasHistory(db, at: now, calendar: calendar) else { return .done }
        let key = RoutineFindings.inboxKeyPrefix + job.periodKey
        guard try !inbox.delivered(dedupeKey: key) else { return .skipped("duplicate") }
        let dayStart = calendar.startOfDay(for: now)
        let recentFrom = calendar.date(byAdding: .day, value: 1 - Self.historyDays, to: dayStart) ?? dayStart
        let selection = try await db.reader.read { d -> Selection? in
            guard try allowed(at: now, in: d) else { return nil }
            let result = try RoutineSuggestions.find(db: db, now: now, calendar: calendar, in: d)
            let seen = try recentFindings(at: now, in: d)
            let candidates = result.candidates.lazy.filter { $0.latest.day >= recentFrom && seen[$0.id] == nil }
            return Selection(result: result, candidates: Array(candidates.prefix(Self.maxFindings)),
                             feedback: try RoutineSuggestions.storedFeedback(db, in: d))
        }
        guard let selection else { return .skipped("disabled") }
        guard !selection.candidates.isEmpty else { return .done }
        try Task.checkCancellation()
        let (outcome, stored) = try DataGeneration.write(db, expected: context.generation) { d in
            try store(selection, key: key, dayStart: dayStart, context: context, in: d)
        }
        if let stored { await inbox.delivered(stored) }
        return outcome
    }

    private struct Selection: Sendable {
        let result: RoutineSuggestions.Result
        let candidates: [RoutineSuggestions.Candidate]
        let feedback: [String: RoutineFeedback]
    }

    private func store(_ selection: Selection, key: String, dayStart: Date, context: JobContext, in d: Database)
        throws -> (JobOutcome, InboxMessage?) {
        try Task.checkCancellation()
        guard try allowed(at: context.now, in: d) else { return (.skipped("disabled"), nil) }
        let feedback = try RoutineSuggestions.storedFeedback(db, in: d)
        var seen = try recentFindings(at: context.now, in: d)
        let candidates = selection.candidates.filter { seen[$0.id] == nil }
        guard !candidates.isEmpty else { return (.done, nil) }
        guard candidates.allSatisfy({ feedback[$0.id] == selection.feedback[$0.id] }),
              try selection.result.stillValid(candidates, in: d) else { return (.skipped("evidence changed"), nil) }

        let policy = CapturePolicy(userRules: selection.result.exclusions.compactMap(ExclusionRule.init(pattern:)))
        let french = context.language == .fr
        let title = french ? "Routines repérées" : "Routines noticed"
        let body = Self.body(candidates, title: title, french: french, calendar: context.calendar)
        let cap = (ProactivePlanner.dailyNudgeCap, ProactivePlanner.nudgeGap, dayStart)
        guard let message = try inbox.insert(kind: .nudge, title: title, body: body, dedupeKey: key, callIDs: [],
                                             nudgeCap: cap, policy: policy, at: context.now, in: d) else {
            return (.skipped("inbox unavailable"), nil)
        }
        for candidate in candidates { seen[candidate.id] = context.now }
        try SettingsStore(db).setValue(seen, forKey: RoutineFindings.seenKey, in: d)
        return (.done, message)
    }

    private func allowed(at now: Date, in d: Database) throws -> Bool {
        let settings = SettingsStore(db)
        guard try settings.value(Bool.self, forKey: SettingRegistry.proactiveEnabledKey, in: d) ?? true,
              ProactiveInbox.memoryEnabled(db, in: d) else { return false }
        return try settings.pausedUntil(in: d).map { $0 <= now } ?? true
    }

    private func recentFindings(at now: Date, in d: Database) throws -> [String: Date] {
        let cutoff = now.addingTimeInterval(-Double(ChatRetention.days) * 86_400)
        let seen = try SettingsStore(db).value([String: Date].self, forKey: RoutineFindings.seenKey, in: d) ?? [:]
        return seen.filter { $0.value >= cutoff }
    }

    private static func body(_ candidates: [RoutineSuggestions.Candidate], title: String, french: Bool,
                             calendar: Calendar) -> String {
        let lines = candidates.map { candidate in
            let first = candidate.latest.first, second = candidate.latest.second
            let pair = Self.literal(first.description) + " → " + Self.literal(second.description)
            let name = candidate.label.map { Self.literal($0) + " — " } ?? ""
            let dates = candidate.observations.prefix(3).map { LocalTime.day($0.day, calendar) }.joined(separator: ", ")
            return "- \(name)\(pair) (\(dates))"
        }
        let prompt = french ? "Nommez une routine de la liste pour demander un brouillon ou un rappel."
            : "Name a routine from this list to ask for a draft or reminder."
        return "**\(title)**\n\n" + lines.joined(separator: "\n") + "\n\n" + prompt
    }

    /// Window titles are untrusted. Normalize line breaks and quote Markdown syntax so a title
    /// can be read but cannot become a link, image, or control in an automatic finding.
    private static func literal(_ text: String) -> String {
        let punctuation = CharacterSet(charactersIn: #"\`*_{}[]<>()#+-.!|&"#)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ").unicodeScalars.reduce(into: "") { out, scalar in
            guard scalar.properties.generalCategory != .format, !CharacterSet.controlCharacters.contains(scalar) else { return }
            if punctuation.contains(scalar) { out.append("\\") }
            out.unicodeScalars.append(scalar)
        }
    }
}

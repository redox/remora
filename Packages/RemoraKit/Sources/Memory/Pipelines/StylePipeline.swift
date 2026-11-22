import Capture
import Foundation
import GRDB
import LLM
import Redaction
import Storage
import os

/// Runs a `style_notes` job (large tier, job type `styleConsolidation`): learns how the user
/// writes on each surface from what they kept, edited or discarded of Remora's rewrites.
///
/// - Reads the last 30 days of inline outputs. A surface needs at least `minOutputs` since its
///   note was last updated (30 days back when it has none); one call per surface (at most
///   `maxSurfaces`, the busiest first). Surfaces over the cap, or whose output did not decode,
///   stay eligible next run; a decoded answer consumes the surface's outputs even when it adds
///   nothing (`memory.style.consumed`). `memory.lastStyleRunAt` only gates scheduling. `this_surface` rules merge into that surface's notes, `all` rules into
///   `"*"`. The watermark then moves to the newest output read, allowed or not.
/// - Outputs of apps or sites excluded now never reach the prompt (`SnapshotPolicy`, `.denyAll`
///   when the exclusions cannot load). Cloud denied: skipped, no call.
/// - Bullets are redacted, cut to 120 characters and capped at 12 per surface
///   (`StyleNotesMerge`). Notes with no `llm_call_id` are the user's: a model bullet is only
///   appended to them, never replaces or drops one, and the note stays the user's. The merge is
///   computed inside the generation-checked write from the note as it is then, so an edit made
///   while the call ran is kept (F-12).
/// - Style learns from inline outputs only; captured user-authored text as a source is a
///   follow-up (F-63).
public struct StylePipeline: JobRunner {
    public static let minOutputs = 3
    public static let maxSurfaces = 6
    public static let window = 2_000
    /// Outputs older than this are not read; also the window of a surface with no note.
    public static let lookback: TimeInterval = 30 * 86_400
    public static let maxSamplesPerSurface = 30
    public static let maxSampleChars = 300
    public static let allSurfaces = "*"
    /// Per surface, the newest output already sent to the model (`[surface: date]`): a run that
    /// adds nothing for a surface still consumes its outputs, so they are not re-sent daily, and
    /// a user's note is never touched for it (final review #17).
    public static let consumedKey = "memory.style.consumed"

    private let db: AppDatabase
    private let llm: LLMService
    private let calendar: Calendar
    private let redactor: Redactor
    private static let log = Logger(subsystem: "dev.remora", category: "memory")

    public init(db: AppDatabase, llm: LLMService, calendar: Calendar, redactor: Redactor = .init()) {
        self.db = db; self.llm = llm; self.calendar = calendar; self.redactor = redactor
    }

    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        guard job.kind == .styleNotes else { return .skipped("wrong_kind") }
        guard context.cloudAllowed else { return .skipped("cloud_denied") }
        let now = context.now
        let settings = SettingsStore(db)
        let outputs = try InlineOutputStore(db).since(now.addingTimeInterval(-Self.lookback), limit: Self.window)
        guard let newest = outputs.last?.createdAt else { return .skipped("no_evidence") }
        let policy = SnapshotPolicy.current(db)
        let notes = StyleNoteStore(db), calls = LLMCallStore(db)
        // Each surface is judged from its own window: the outputs since its note was last
        // updated (the last 30 days when it has none), so a quiet surface accumulates over runs.
        var windows: [(surface: String, rows: [InlineOutput])] = []
        let consumed = (try? settings.value([String: Date].self, forKey: Self.consumedKey)) ?? [:]
        for (surface, all) in Dictionary(grouping: outputs.filter { SnapshotPolicy.allows($0, policy: policy) }, by: \.surface) {
            let cutoff = max(try notes.row(for: surface)?.updatedAt ?? now.addingTimeInterval(-Self.lookback),
                             consumed[surface] ?? .distantPast)
            let rows = all.filter { $0.createdAt > cutoff }
            if rows.count >= Self.minOutputs { windows.append((surface, rows)) }
        }
        let groups = windows.sorted { ($0.rows.count, $1.surface) > ($1.rows.count, $0.surface) }.prefix(Self.maxSurfaces)
        guard !groups.isEmpty else { return .skipped("not_enough_outputs") }

        var failed = 0
        for (surface, rows) in groups {
            let samples = rows.suffix(Self.maxSamplesPerSurface)
            let block = PipelinePrompt.styleBlock(surface: surface, samples: Array(samples),
                                                  surfaceNotes: try notes.note(for: surface),
                                                  allNotes: try notes.note(for: Self.allSurfaces))
            let result = try await llm.complete(.styleConsolidation, instructions: PipelinePrompt.instructions(
                .curator, language: context.language, now: now, calendar: calendar),
                                                input: [.user(block), .user(PipelinePrompt.styleTask)],
                                                format: StyleRulesOutput.format, cloudAllowed: context.cloudAllowed)
            let output: StyleRulesOutput
            do { output = try StyleRulesOutput.decode(result.text) } catch {
                failed += 1
                Self.log.info("style notes: output for one surface did not decode")
                continue
            }
            let own = bullets(output, scope: .thisSurface), shared = bullets(output, scope: .all)
            let call = result.callID > 0 ? result.callID : nil
            try DataGeneration.write(db, expected: context.generation) { d in
                for (key, new) in [(surface, own), (Self.allSurfaces, shared)] where !new.isEmpty {
                    let row = try notes.row(for: key, in: d)
                    let existing = StyleNotesMerge.bullets(row?.notes ?? "")
                    if let row, row.llmCallID == nil {
                        // A note without a call id is the user's: append to the raw text only.
                        guard let text = StyleNotesMerge.append(toRaw: row.notes, new: new) else { continue }
                        try notes.upsert(surface: key, notes: text, llmCallID: nil, at: now, in: d)
                        continue
                    }
                    let merged = StyleNotesMerge.merge(existing: existing, new: new)
                    guard merged != existing else { continue }
                    try notes.upsert(surface: key, notes: StyleNotesMerge.render(merged), llmCallID: call, at: now, in: d)
                }
                if let call { try calls.setArtifact(callID: call, table: "style_notes", id: nil, in: d) }
                // These outputs are consumed even when nothing was written for the surface.
                if let last = rows.last?.createdAt {
                    var marks = (try? settings.value([String: Date].self, forKey: Self.consumedKey, in: d)) ?? [:]
                    if marks[surface].map({ $0 < last }) ?? true {
                        marks[surface] = last
                        try settings.setValue(marks, forKey: Self.consumedKey, in: d)
                    }
                }
            }
            Self.log.info("style notes: \(rows.count, privacy: .public) outputs, \(own.count, privacy: .public) own, \(shared.count, privacy: .public) shared bullets")
        }
        if failed == groups.count { throw MemoryError.invalidOutput(schema: StyleRulesOutput.schemaName) }
        try DataGeneration.write(db, expected: context.generation) { d in
            // Only gates scheduling; moves forward only.
            if let stored = try? settings.value(Date.self, forKey: JobPlanner.lastStyleRunKey, in: d), stored >= newest { return }
            try settings.setValue(newest, forKey: JobPlanner.lastStyleRunKey, in: d)
        }
        return .done
    }

    /// The scope's bullets, redacted and cut (`StyleNotesMerge.clean`), without empty ones.
    private func bullets(_ o: StyleRulesOutput, scope: StyleScopeOutput) -> [String] {
        o.rules.filter { $0.scope == scope }.map { StyleNotesMerge.clean(redactor.redact($0.bullet)) }.filter { !$0.isEmpty }
    }
}

extension PipelinePrompt {
    /// The style input: `<samples>` (one line per output: outcome, mode, what the user wrote,
    /// what Remora produced, what the user changed it to) and `<existing>` (the current notes).
    public static func styleBlock(surface: String, samples: [InlineOutput], surfaceNotes: String?, allNotes: String?) -> String {
        let cap = StylePipeline.maxSampleChars
        var out = "Surface: \(oneLine(surface, max: maxNameChars))\n<samples>\n"
        for o in samples {
            var line = "- [\(o.outcome?.rawValue ?? "pending")] \(o.mode.rawValue)"
            if let instruction = o.instruction, !instruction.isEmpty { line += " | instruction: \(oneLine(instruction, max: cap))" }
            line += " | the user wrote: \(oneLine(o.original, max: cap)) | Remora produced: \(oneLine(o.result, max: cap))"
            if o.outcome == .edited, let final = o.finalText { line += " | the user changed it to: \(oneLine(final, max: cap))" }
            out += line + "\n"
        }
        out += "</samples>\n<existing>\n"
        for (label, notes) in [("Notes for this surface", surfaceNotes), ("Notes for all surfaces", allNotes)] {
            guard let notes, !notes.isEmpty else { continue }
            out += "\(label):\n\(escape(notes))\n"
        }
        return out + "</existing>"
    }

    public static let styleTask = """
        Task: from <samples>, learn how the user writes on this surface. Look at what they kept, what they edited (and how) and what they discarded.
        - rules: short imperative bullets of at most 120 characters, at most 12 for this surface. kind is format, lexical or tone. scope is this_surface for what holds only here, all for what holds everywhere.
        - Add a rule only when the samples show it repeatedly. Do not repeat a rule already in <existing>. Never quote the samples. Return no rules when nothing is clear.
        """
}

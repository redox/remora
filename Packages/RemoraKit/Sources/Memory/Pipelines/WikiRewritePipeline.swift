import Capture
import Foundation
import GRDB
import LLM
import Redaction
import Retrieval
import Storage
import os

/// Runs a `wiki_rewrite` job (large tier, job type `wikiWriteup`): for each dirty page with at
/// least `minMentions` mentions (most mentioned first, at most `maxPages`), one call writes its
/// summary and body from its valid facts, the facts invalidated in the last 30 days and the hour
/// and day chronicles that mention it.
///
/// - `<existing>` holds the page and the 150 most recently seen known pages (`slug | type |
///   title`, F-15): `[[slug]]` links to anything else are dropped from the body and from `links`.
/// - Facts and chronicles citing snapshots now excluded never reach the prompt. Everything stored
///   that the prompt shows is escaped (F-28). Cloud denied: skipped, nothing is sent.
/// - Output is redacted and capped before storage. The write is one generation-checked
///   transaction that re-reads the page and its facts: when they changed meanwhile (a new or
///   invalidated fact, a new mention) nothing is written and the page stays dirty; a page deleted
///   meanwhile is not recreated.
/// - A page whose output does not decode (or is empty) stays dirty and the run goes on; the job
///   fails (`invalid_output`) only when every page failed.
public struct WikiRewritePipeline: JobRunner {
    public static let minMentions = WikiStore.minRewriteMentions
    public static let maxPages = 8
    /// Dirty candidates fetched (most mentioned first) before the policy filter and `maxPages`.
    public static let candidateWindow = 64
    public static let knownPages = 150
    public static let maxValidFacts = 40
    public static let maxInvalidFacts = 20
    public static let maxChronicles = 8
    public static let invalidatedWindow: TimeInterval = 30 * 86_400

    private let db: AppDatabase
    private let llm: LLMService
    private let calendar: Calendar
    private let redactor: Redactor
    private static let log = Logger(subsystem: "dev.remora", category: "memory")

    public init(db: AppDatabase, llm: LLMService, calendar: Calendar, redactor: Redactor = .init()) {
        self.db = db; self.llm = llm; self.calendar = calendar; self.redactor = redactor
    }

    public func run(_ job: Job, context: JobContext) async throws -> JobOutcome {
        guard job.kind == .wikiRewrite else { return .skipped("wrong_kind") }
        guard context.cloudAllowed else { return .skipped("cloud_denied") }
        // A bounded window of candidates is policy-filtered before the limit, so pages backed only
        // by excluded sources (they stay dirty, unsent) never use up the run's pages.
        let candidates = try WikiStore(db).dirtyPages(minMentions: Self.minMentions, limit: Self.candidateWindow)
        let policy = SnapshotPolicy.current(db)
        let pages = try await db.reader.read { d in
            Array(try DerivedPolicy.filter(candidates, ids: \.snapshotIDs, policy: policy, in: d).prefix(Self.maxPages))
        }
        guard !pages.isEmpty else { return .skipped("no_pages") }
        var failed = 0, written = 0
        for p in pages {
            do { if try await rewrite(slug: p.slug, context: context) { written += 1 } } catch is MemoryError { failed += 1 }
        }
        Self.log.info("wiki rewrite \(job.periodKey, privacy: .public): \(pages.count, privacy: .public) pages, \(written, privacy: .public) written, \(failed, privacy: .public) failed")
        if failed == pages.count { throw MemoryError.invalidOutput(schema: WikiPageOutput.schemaName) }
        return .done
    }

    /// What the write-up is built from; the in-transaction re-check compares it.
    private struct Source: Equatable {
        struct Fact: Equatable { var id: Int64?; var text: String; var invalidAt: Date? }
        var title: String, aliases: [String], summary: String, body: String, mentions: Int, facts: [Fact]
        init(_ p: WikiPage, _ facts: [WikiFact]) {
            title = p.title; aliases = p.aliases; summary = p.summary; body = p.body; mentions = p.mentionCount
            self.facts = facts.map { Fact(id: $0.id, text: $0.fact, invalidAt: $0.invalidAt) }
        }
    }

    /// Returns whether the page was written.
    private func rewrite(slug: String, context: JobContext) async throws -> Bool {
        let policy = SnapshotPolicy.current(db)
        let now = context.now
        let store = ChronicleStore(db)
        let loaded: (WikiPage, [WikiFact], [WikiPage])? = try await db.reader.read { d in
            guard let page = try WikiStore.page(slug: slug, in: d), page.isDirty else { return nil }
            // A page backed only by sources excluded now is not rewritten and nothing is sent.
            guard try !DerivedPolicy.filter([page], ids: \.snapshotIDs, policy: policy, in: d).isEmpty else { return nil }
            let facts = try WikiStore.facts(slug: slug, includeInvalid: true, in: d)
            let known = try WikiPage.fetchAll(d, sql: "SELECT * FROM wiki_pages WHERE slug <> ? ORDER BY last_seen DESC, id DESC LIMIT ?",
                                              arguments: [slug, Self.knownPages * 2])
            let allowed = try DerivedPolicy.filter(known, ids: \.snapshotIDs, policy: policy, in: d)
            return (page, facts, Array(allowed.prefix(Self.knownPages)))
        }
        guard let (page, allFacts, known) = loaded else { return false }
        let source = Source(page, allFacts)

        let hits = try store.search([page.title] + page.aliases, levels: [.hour, .day], since: nil,
                                    limit: Self.maxChronicles * 2).map(\.0)
        let (facts, chronicles) = try await db.reader.read { d in
            (try DerivedPolicy.filter(allFacts, ids: \.snapshotIDs, policy: policy, in: d),
             try DerivedPolicy.filter(hits, ids: \.snapshotIDs, policy: policy, in: d))
        }
        let valid = facts.filter { $0.invalidAt == nil }.sorted(by: Self.validOrder).prefix(Self.maxValidFacts)
        let floor = now.addingTimeInterval(-Self.invalidatedWindow)
        let invalid = facts.filter { ($0.invalidAt ?? .distantPast) >= floor }
            .sorted { ($0.invalidAt ?? .distantPast, $0.id ?? 0) > ($1.invalidAt ?? .distantPast, $1.id ?? 0) }
            .prefix(Self.maxInvalidFacts)
        let block = PipelinePrompt.wikiPageBlock(page: page, known: known, valid: Array(valid), invalidated: Array(invalid),
                                                 chronicles: Array(chronicles.prefix(Self.maxChronicles)), calendar: calendar)
        let result = try await llm.complete(.wikiWriteup, instructions: PipelinePrompt.instructions(
            .curator, language: context.language, now: now, calendar: calendar),
                                            input: [.user(block), .user(PipelinePrompt.wikiRewriteTask)],
                                            format: WikiPageOutput.format, cloudAllowed: context.cloudAllowed)
        let output = try WikiPageOutput.decode(result.text)
        let summary = capSummary(output.summary), body = capWords(redactor.redact(output.body), max: WikiPageOutput.maxBodyWords)
        guard !summary.isEmpty || !body.isEmpty else { throw MemoryError.invalidOutput(schema: WikiPageOutput.schemaName) }
        let call = result.callID > 0 ? result.callID : nil
        let offered = Set(known.map(\.slug))
        let calls = LLMCallStore(db)
        return try DataGeneration.write(db, expected: context.generation) { d -> Bool in
            guard var current = try WikiStore.page(slug: slug, in: d) else { return false }
            guard Source(current, try WikiStore.facts(slug: slug, includeInvalid: true, in: d)) == source else { return false }
            let alive = Set(try String.fetchAll(d, sql: "SELECT slug FROM wiki_pages")).intersection(offered)
            var links: [String] = []
            for raw in output.links {
                let s = Self.slugText(raw)
                if alive.contains(s), !links.contains(s) { links.append(s) }
            }
            // A blank field keeps its previous value.
            if !summary.isEmpty { current.summary = summary }
            if !body.isEmpty { current.body = Self.keepKnownLinks(in: body, alive: alive) }
            current.links = links
            current.isDirty = false
            current.updatedAt = now
            current.llmCallID = call
            try WikiStore.update(current, in: d)
            if let call { try calls.setArtifact(callID: call, table: "wiki_pages", id: current.id, in: d) }
            return true
        }
    }

    /// Core facts first, then the newest.
    private static func validOrder(_ a: WikiFact, _ b: WikiFact) -> Bool {
        if a.worth != b.worth { return a.worth == .core }
        return (a.validAt, a.id ?? 0) > (b.validAt, b.id ?? 0)
    }

    // MARK: - Output cleaning

    /// Redacted, one line, at most 140 characters.
    private func capSummary(_ s: String) -> String {
        let line = redactor.redact(s).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(line.prefix(WikiPageOutput.maxSummaryChars)).trimmingCharacters(in: .whitespaces)
    }

    /// At most `max` words, keeping the line breaks of what is kept.
    private func capWords(_ text: String, max: Int) -> String {
        var count = 0
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let words = line.split(whereSeparator: \.isWhitespace)
            if count + words.count <= max {
                count += words.count
                lines.append(String(line))
                continue
            }
            if max - count > 0 { lines.append(words.prefix(max - count).joined(separator: " ")) }
            break
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A model-written slug: trimmed, without brackets.
    private static func slugText(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "[]").union(.whitespacesAndNewlines))
    }

    /// `[[slug]]` and `[[slug|label]]` stay when the slug is in `alive`; any other link becomes
    /// its label (or its text, or the slug when the label is empty) without the brackets, to a
    /// fixed point (nested links); leftover `[[` and `]]` outside a kept link are removed.
    static func keepKnownLinks(in body: String, alive: Set<String>) -> String {
        let flat = /\[\[([^\[\]]*)\]\]/
        var text = body
        while true {
            let next = text.replacing(flat) { match in
                let inner = String(match.output.1)
                let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let slug = parts.first.map(slugText) ?? ""
                if alive.contains(slug) { return String(match.output.0) }
                let label = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                return label.isEmpty ? (parts.first ?? "").trimmingCharacters(in: .whitespaces) : label
            }
            // Kept links match again unchanged; stop when nothing else changes.
            if next == text { break }
            text = next
        }
        var out = "", last = text.startIndex
        func strip(_ s: Substring) -> String { s.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "") }
        for m in text.matches(of: flat) {
            out += strip(text[last..<m.range.lowerBound]) + text[m.range]
            last = m.range.upperBound
        }
        return out + strip(text[last...])
    }
}

// MARK: - Prompt

extension PipelinePrompt {
    /// A stored page body is cut to this many characters in a prompt (a body is at most 300 words).
    static let maxPageBodyChars = 3_000
    static let maxSummaryPromptChars = 300

    /// The rewrite input: `<existing>` with the page and the known pages, `<memory>` with the facts
    /// (valid ones with their date, core first; recently invalidated ones as "no longer true since
    /// <date>") and the matching chronicle summaries, oldest first. Every stored string is escaped.
    public static func wikiPageBlock(page: WikiPage, known: [WikiPage], valid: [WikiFact], invalidated: [WikiFact],
                                     chronicles: [Chronicle], calendar: Calendar) -> String {
        func day(_ d: Date) -> String { stamp(d, calendar: calendar, format: "yyyy-MM-dd") }
        var out = "<existing>\nPage: \(escape(page.slug)) | \(page.type.rawValue) | \(oneLine(page.title, max: maxNameChars))\n"
        out += "Aliases: " + page.aliases.map { oneLine($0, max: maxNameChars) }.joined(separator: ", ") + "\n"
        out += "Current summary: \(oneLine(page.summary, max: maxSummaryPromptChars))\n"
        out += "Current body:\n\(escape(String(page.body.prefix(maxPageBodyChars))))\n"
        out += "Known pages (slug | type | title), the only slugs you may link to:\n"
        for p in known { out += "- \(escape(p.slug)) | \(p.type.rawValue) | \(oneLine(p.title, max: maxNameChars))\n" }
        out += "</existing>\n<memory>\nValid facts (date | fact), most important first:\n"
        if valid.isEmpty { out += "- none\n" }
        for f in valid { out += "- [\(day(f.validAt))] \(oneLine(f.fact, max: maxFactChars)) (\(f.worth.rawValue))\n" }
        if !invalidated.isEmpty {
            out += "Facts that stopped being true recently:\n"
            for f in invalidated {
                out += "- \(oneLine(f.fact, max: maxFactChars)) (no longer true since \(day(f.invalidAt ?? f.validAt)))\n"
            }
        }
        if !chronicles.isEmpty {
            out += "Activity summaries that mention it, oldest first ([period] summary):\n"
            for c in chronicles.sorted(by: { ($0.periodStart, $0.id ?? 0) < ($1.periodStart, $1.id ?? 0) }) {
                out += "[\(escape(c.periodKey))] \(oneLine(c.summary, max: maxChildSummaryChars))\n"
            }
        }
        return out + "</memory>"
    }

    /// The wiki write-up task (job `wikiWriteup`, schema `wiki_page`).
    public static let wikiRewriteTask = """
        Task: write the wiki page for the entity in <existing> from the facts and summaries in <memory>.
        - summary: one factual line of at most 140 characters saying what or who it is for the user.
        - body: at most 300 words of markdown. Current truth first, with dates ([yyyy-MM-dd]) on anything time-sensitive. Facts marked as no longer true may be mentioned only as history, never as current. Do not repeat the summary, and do not invent anything the facts and summaries do not support.
        - links: the slugs you linked in the body. Link with [[slug]] only to slugs listed under "Known pages" in <existing>; never invent a slug.
        """
}

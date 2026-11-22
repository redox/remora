import Foundation
import GRDB
import Redaction
import Storage

/// What one `EntityApplier.apply` stored and dropped (counts only: safe to log).
public struct EntityReport: Sendable, Equatable {
    public var pagesCreated = 0
    public var pagesUpdated = 0
    public var entitiesDropped = 0
    public var factsAdded = 0
    public var factsConfirmed = 0
    public var factsInvalidated = 0
    public var factsDropped = 0
    public var flagsAdded = 0
    public var flagsMerged = 0
    public var flagsDropped = 0
    /// The slugs of the pages this output touched, the most cited first.
    public var slugs: [String] = []

    public init() {}
}

/// Applies hour call B (`hour_entities`) to the wiki and the salient flags, inside the caller's
/// write transaction (`DataGeneration.write`; only `in d:` store calls, F-6/F-12).
///
/// - Every string from the model is redacted, then cut to the plan's caps (F-50).
/// - Only snapshots in `evidence` (which passed `SnapshotPolicy`) that still exist when the
///   write runs can be cited; a fact, flag or entity left with no cited snapshot is dropped.
/// - Every row stores the call id and its `snapshot_ids`.
public enum EntityApplier {
    /// Counts of model items considered per hour; the rest are ignored.
    public static let maxEntities = 30
    public static let maxFacts = 40
    public static let maxFlags = 20
    public static let maxSupersedes = 10
    public static let maxAliases = 8
    /// Page titles, aliases, flag persons and projects.
    public static let maxNameChars = 120
    public static let maxFactChars = 300
    public static let maxFlagChars = 200
    public static let maxQuoteChars = 300

    public static func apply(_ out: HourEntitiesOutput, evidence: HourEvidence, periodKey: String, callID: Int64?,
                             at: Date, calendar: Calendar, redactor: Redactor = .init(), in d: Database) throws
        -> EntityReport {
        var state = State(evidence: evidence, alive: try aliveSnapshotIDs(evidence, in: d),
                          names: try WikiNameIndex.load(in: d), call: callID.flatMap { $0 > 0 ? $0 : nil }, at: at,
                          redactor: redactor)
        for e in out.entities.prefix(maxEntities) { try state.entity(e, in: d) }
        for f in out.facts.prefix(maxFacts) { try state.fact(f, calendar: calendar, in: d) }
        for g in out.flags.prefix(maxFlags) { try state.flag(g, periodKey: periodKey, calendar: calendar, in: d) }
        state.report.slugs = state.touchOrder.enumerated()
            .sorted { (state.citations[$0.element, default: 0], -$0.offset) > (state.citations[$1.element, default: 0], -$1.offset) }
            .map(\.element)
        return state.report
    }

    /// The evidence snapshots that still exist (one may be forgotten during the model call).
    private static func aliveSnapshotIDs(_ e: HourEvidence, in d: Database) throws -> Set<Int64> {
        let ids = e.items.map(\.snapshotID)
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return Set(try Int64.fetchAll(d, sql: "SELECT id FROM snapshots WHERE id IN (\(marks))",
                                      arguments: StatementArguments(ids)))
    }

    private struct State {
        let evidence: HourEvidence
        let alive: Set<Int64>
        /// Every page's names, loaded once per apply and kept current after each insert/update.
        var names: WikiNameIndex
        let call: Int64?
        let at: Date
        let redactor: Redactor
        var report = EntityReport()
        /// Pages touched this hour, in first-touch order; each gets one mention per hour.
        var touchOrder: [String] = []
        var citations: [String: Int] = [:]
        /// Folded entity names (and aliases) of this output → slug.
        var hourNames: [String: String] = [:]
        var created: Set<String> = []

        init(evidence: HourEvidence, alive: Set<Int64>, names: WikiNameIndex, call: Int64?, at: Date,
             redactor: Redactor) {
            self.evidence = evidence; self.alive = alive; self.names = names; self.call = call; self.at = at
            self.redactor = redactor
        }

        // MARK: Entities

        mutating func entity(_ e: HourEntitiesOutput.Entity, in d: Database) throws {
            let name = clean(e.name, max: EntityApplier.maxNameChars)
            let ids = cite(e.evidence)
            // A name the redactor changes (it holds a secret) would turn into "[redacted]" and
            // merge unrelated entities into one page: drop it.
            guard redactor.redact(e.name) == e.name, !Slug.make(name).isEmpty, !ids.isEmpty else {
                report.entitiesDropped += 1
                return
            }
            // An alias the redactor changes would be stored as "[redacted]", and a later redacted
            // entity would match it: drop it, like a name.
            let aliases = e.aliases.prefix(EntityApplier.maxAliases * 2).filter { redactor.redact($0) == $0 }
                .map { clean($0, max: EntityApplier.maxNameChars) }.filter { !$0.isEmpty }
            let wanted = Set(([name] + aliases).map(TextFold.fold))
            let base = Slug.make(name)
            var page: WikiPage
            switch names.resolve(name: name, aliases: aliases) {
            case let (slug, .name)?:
                page = try existing(slug, in: d)
            case let (slug, .alias)? where names.entry(slug: base) != nil:
                // Found only through a multi-word alias while the name's own slug is taken.
                page = try existing(slug, in: d)
            case (_, .alias)?, (_, .slugCollision)?, nil:
                // No page carries this name: a new entity (numbered on a slug collision).
                page = try WikiStore.insert(WikiPage(
                    slug: freeSlug(base), type: e.type, title: name, firstSeen: evidence.span.start,
                    lastSeen: evidence.span.end, updatedAt: at, llmCallID: call), in: d)
                created.insert(page.slug)
                names.upsert(page)
                report.pagesCreated += 1
            }
            page.aliases = merged(page.aliases, adding: [name] + aliases, title: page.title)
            for n in wanted { hourNames[n] = page.slug }
            try touch(&page, ids: ids, in: d)
        }

        private func existing(_ slug: String, in d: Database) throws -> WikiPage {
            guard let page = try WikiStore.page(slug: slug, in: d) else { throw DatabaseError(resultCode: .SQLITE_NOTFOUND) }
            return page
        }

        /// `base`, or `base-2`, `base-3`… when the slug is taken (cut so it stays ≤ 60 chars).
        private func freeSlug(_ base: String) -> String {
            guard names.entry(slug: base) != nil else { return base }
            var n = 2
            while true {
                let suffix = "-\(n)"
                var head = String(base.prefix(Slug.maxLength - suffix.count))
                while head.hasSuffix("-") { head.removeLast() }
                if names.entry(slug: head + suffix) == nil { return head + suffix }
                n += 1
            }
        }

        /// Existing aliases first, then new ones not already a name of the page, at most 8.
        private func merged(_ existing: [String], adding new: [String], title: String) -> [String] {
            var seen = Set(([title] + existing).map(TextFold.fold))
            var out = existing
            for a in new where out.count < EntityApplier.maxAliases && seen.insert(TextFold.fold(a)).inserted {
                out.append(a)
            }
            return Array(out.prefix(max(EntityApplier.maxAliases, existing.count)))
        }

        /// Marks the page seen this hour (one mention per hour), dirty, citing `ids`; saves it.
        private mutating func touch(_ page: inout WikiPage, ids: [Int64], in d: Database) throws {
            if !touchOrder.contains(page.slug) {
                touchOrder.append(page.slug)
                page.mentionCount += 1
                if !created.contains(page.slug) { report.pagesUpdated += 1 }
            }
            citations[page.slug, default: 0] += ids.count
            page.lastSeen = max(page.lastSeen, evidence.span.end)
            page.isDirty = true
            page.snapshotIDs = union(page.snapshotIDs, ids)
            page.updatedAt = at
            page.llmCallID = page.llmCallID ?? call
            try WikiStore.update(page, in: d)
            names.upsert(page)
        }

        // MARK: Facts

        mutating func fact(_ f: HourEntitiesOutput.Fact, calendar: Calendar, in d: Database) throws {
            let text = clean(f.text, max: EntityApplier.maxFactChars)
            let key = TextFold.key(text, keepingSymbols: true)
            let ids = cite(f.evidence)
            guard f.worth != .noise, !key.isEmpty, !ids.isEmpty, var page = try resolvePage(f.entity, in: d) else {
                report.factsDropped += 1
                return
            }
            // When the fact became true, as this hour asserts it.
            let asserted = EntityApplier.date(f.asOf, calendar: calendar) ?? evidence.span.start
            let stored: WikiFact
            if var existing = try WikiStore.fact(slug: page.slug, normKey: key, in: d) {
                existing.lastConfirmedAt = max(existing.lastConfirmedAt, at)
                existing.snapshotIDs = union(existing.snapshotIDs, ids)
                if existing.invalidAt != nil {
                    // A value that was replaced is true again (A → B → A): valid from now on.
                    existing.invalidAt = nil
                    existing.supersededBy = nil
                    existing.validAt = asserted
                }
                try WikiStore.update(existing, in: d)
                stored = existing
                report.factsConfirmed += 1
            } else {
                stored = try WikiStore.insert(WikiFact(
                    slug: page.slug, fact: text, normKey: key, subject: f.subject, basis: f.basis,
                    worth: f.basis == .inferred || f.worth == .detail ? .detail : .core, snapshotIDs: ids,
                    validAt: asserted, recordedAt: at, lastConfirmedAt: at, llmCallID: call), in: d)
                report.factsAdded += 1
            }
            // Superseded facts end when this assertion starts (never at the stored start of an
            // older confirmed row); one that would end before or when it began is left valid.
            for id in f.supersedes.prefix(EntityApplier.maxSupersedes) where id != stored.id {
                guard var old = try WikiStore.fact(id: id, in: d), old.slug == stored.slug, old.invalidAt == nil,
                      asserted > old.validAt
                else { continue }
                old.invalidAt = asserted
                old.supersededBy = stored.id
                try WikiStore.update(old, in: d)
                report.factsInvalidated += 1
            }
            try touch(&page, ids: ids, in: d)
        }

        /// A page named in this output first; otherwise an existing page with that exact
        /// (folded) title or alias. A bare slug collision is not enough for a fact.
        private func resolvePage(_ entity: String, in d: Database) throws -> WikiPage? {
            let name = clean(entity, max: EntityApplier.maxNameChars)
            let folded = TextFold.fold(name)
            guard !folded.isEmpty else { return nil }
            if let slug = hourNames[folded] { return try WikiStore.page(slug: slug, in: d) }
            guard case let (slug, .name)? = names.resolve(name: name, aliases: []) else { return nil }
            return try WikiStore.page(slug: slug, in: d)
        }

        // MARK: Flags

        mutating func flag(_ g: HourEntitiesOutput.Flag, periodKey: String, calendar: Calendar, in d: Database) throws {
            let items = cited(g.evidence)
            let text = clean(g.text, max: EntityApplier.maxFlagChars)
            // Generate-then-verify: the quote must be literally in a cited snapshot's text (never
            // its title), so a planted "commitment" without on-screen text is dropped.
            guard !text.isEmpty, items.contains(where: { QuoteCheck.verify(g.quote, in: $0.text) }) else {
                report.flagsDropped += 1
                return
            }
            let person = clean(g.person, max: EntityApplier.maxNameChars)
            let key = SalientFlagStore.dedupeKey(kind: g.kind, text: text, person: person)
            let existed = try SalientFlagStore.flag(dedupeKey: key, in: d) != nil
            try SalientFlagStore.upsert(SalientFlag(
                kind: g.kind, text: text, owner: g.owner, person: person,
                project: clean(g.project, max: EntityApplier.maxNameChars),
                dueAt: EntityApplier.date(g.due, calendar: calendar, endOfDay: true), quote: clean(g.quote, max: EntityApplier.maxQuoteChars),
                snapshotIDs: items.map(\.snapshotID), periodKey: periodKey, dedupeKey: key, createdAt: at,
                lastSeenAt: evidence.span.end, llmCallID: call), in: d)
            if existed { report.flagsMerged += 1 } else { report.flagsAdded += 1 }
        }

        // MARK: Helpers

        /// The cited items that still exist, in citation order, without duplicates.
        private func cited(_ indices: [Int]) -> [EvidenceItem] {
            var seen = Set<Int>()
            return indices.compactMap { i in
                guard i >= 1, i <= evidence.items.count, seen.insert(i).inserted else { return nil }
                let item = evidence.items[i - 1]
                return alive.contains(item.snapshotID) ? item : nil
            }
        }

        private func cite(_ indices: [Int]) -> [Int64] {
            union([], cited(indices).map(\.snapshotID))
        }

        /// Redacted, on one line with single spaces, trimmed, at most `max` characters.
        private func clean(_ s: String, max: Int) -> String {
            let line = redactor.redact(s).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return String(line.prefix(max)).trimmingCharacters(in: .whitespaces)
        }

        private func union(_ a: [Int64], _ b: [Int64]) -> [Int64] {
            var seen = Set<Int64>()
            return (a + b).filter { seen.insert($0).inserted }
        }
    }

    /// `YYYY-MM-DD` (local midnight, or 23:59:59 local with `endOfDay`: a due *date* lasts all
    /// day), `YYYY-MM-DDTHH:MM[:SS]` or `YYYY-MM-DD HH:MM` (local), or an ISO 8601 date-time with
    /// a time zone; nil for anything else (including "").
    static func date(_ s: String, calendar: Calendar, endOfDay: Bool = false) -> Date? {
        let text = s.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        for format in ["yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.isLenient = false
            f.dateFormat = format
            guard let date = f.date(from: text) else { continue }
            if format == "yyyy-MM-dd", endOfDay {
                return calendar.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date
            }
            return date
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }
}

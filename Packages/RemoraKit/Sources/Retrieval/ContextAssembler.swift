import Capture
import Foundation
import Redaction
import Storage
import Synchronization
import os

public struct ContextSnippet: Sendable, Equatable {
    public var app: String
    public var windowTitle: String?
    public var capturedAt: Date
    public var text: String
    public init(app: String, windowTitle: String?, capturedAt: Date, text: String) {
        self.app = app; self.windowTitle = windowTitle; self.capturedAt = capturedAt; self.text = text
    }
}

public struct RewriteContext: Sendable, Equatable {
    public var windowText: String?
    public var related: [ContextSnippet]
    public var recent: [ContextSnippet]
    /// Digest, identity, working memory and style. Empty unless memory is allowed.
    public var memory: BaseMemory
    /// Chronicle and wiki hits (`HybridSearch`), best first.
    public var hits: [MemoryHit]
    /// The pages of the top wiki hits.
    public var pages: [WikiPageBrief]
    /// Open flags as `kind: text (person, due yyyy-MM-dd)` lines.
    public var openItems: [String]

    /// The style notes. One source for `<style>` (F-39): this is `memory.style`.
    public var styleNote: String? {
        get { memory.style }
        set { memory.style = newValue }
    }

    /// A non-nil `styleNote` sets `memory.style`.
    public init(windowText: String?, related: [ContextSnippet] = [], recent: [ContextSnippet] = [],
                styleNote: String? = nil, memory: BaseMemory = .empty, hits: [MemoryHit] = [],
                pages: [WikiPageBrief] = [], openItems: [String] = []) {
        self.windowText = windowText; self.related = related; self.recent = recent
        self.memory = memory; self.hits = hits; self.pages = pages; self.openItems = openItems
        if let styleNote { self.memory.style = styleNote }
    }

    public static let empty = RewriteContext(windowText: nil)
}

public struct ContextBudget: Sendable {
    public var windowChars = 12_000
    public var relatedChars = 6_000
    public var relatedMax = 6
    public var recentChars = 3_000
    public var recentMax = 5
    public var recentWindow: TimeInterval = 1_800
    public var styleChars = 2_000
    public var digestChars = 6_000
    public var identityChars = 4_000
    public var workingMemoryMax = 8
    public var hitsMax = 6
    public var hitsChars = 4_000
    public var pagesMax = 3
    public var pageSummaryChars = 300
    public var openItemsMax = 5
    /// Open items due within this window are included whether or not they match the query.
    public var openItemsDueWithin: TimeInterval = 7 * 86_400
    /// The whole memory part of the context, query expansion included. The rewrite key is
    /// interactive: past this the rewrite goes on with the window text only (never blocked on
    /// memory). The Plan 2 window read is bounded the same way (1.5 s, `RewriteController`).
    public var memoryTimeout: Duration = .milliseconds(1_500)
    /// Query expansion's own bound, inside `memoryTimeout`.
    public var expansionTimeout: Duration = .milliseconds(1_200)
    public init() {}
}

public struct ContextRequest: Sendable {
    public var fieldText: String
    public var windowTitle: String?
    /// Live text of the window being written in. The caller passes it only for capturable contexts
    /// (nil for excluded apps); it is redacted here.
    public var liveWindowText: String?
    public var app: String
    public var bundleID: String?
    public var surface: String
    /// The rewrite gate's verdict (`RewriteAccess.memoryAllowed`). False in excluded, private,
    /// unverifiable and paused contexts: then no memory is read at all.
    public var memoryAllowed: Bool
    public var now: Date
    /// The rewrite's own cloud permission (`RewriteAccess.cloudAllowed`); query expansion uses it.
    /// Fails closed: false (on-device only) unless the caller passes it.
    public var cloudAllowed: Bool
    public init(fieldText: String, windowTitle: String?, liveWindowText: String?, app: String, bundleID: String?,
                surface: String, memoryAllowed: Bool, now: Date, cloudAllowed: Bool = false) {
        self.fieldText = fieldText; self.windowTitle = windowTitle; self.liveWindowText = liveWindowText
        self.app = app; self.bundleID = bundleID; self.surface = surface
        self.memoryAllowed = memoryAllowed; self.now = now; self.cloudAllowed = cloudAllowed
    }
}

/// Builds the rewrite context.
///
/// Privacy: when `memoryAllowed` is false (the rewrite gate denies memory in excluded, private,
/// unverifiable and paused contexts) the context is the window text only: no digest, identity,
/// working memory, hits, open items, related or recent snapshots, and no query expansion call.
/// Otherwise every snapshot shown passes `SnapshotPolicy` and every derived row `DerivedPolicy`
/// under fresh exclusions (`.denyAll` when they cannot be loaded, F-37/F-37b).
///
/// Latency: the memory part is bounded by `ContextBudget.memoryTimeout`. Past it the window text
/// and the base memory (style, digest, identity, working memory) are returned if the base was
/// loaded, else the window text alone; the stages check for cancellation so timed-out work stops
/// early. One `CapturePolicy` is loaded per rewrite and used by every stage. Query text is
/// redacted before it is expanded or searched. Never logs the query, terms or any content.
public struct ContextAssembler: Sendable {
    private static let log = Logger(subsystem: "dev.remora", category: "rewrite")

    private let db: AppDatabase
    private let redactor: Redactor
    private let budget: ContextBudget
    private let search: HybridSearch
    private let expander: any QueryExpander
    private let policy: @Sendable () -> CapturePolicy

    /// `search` nil: FTS-only hybrid search over `db`. `policy` nil: fresh exclusions on every
    /// call (`SnapshotPolicy.current`, fail closed).
    public init(db: AppDatabase, redactor: Redactor = .init(), budget: ContextBudget = .init(), search: HybridSearch? = nil,
                expander: any QueryExpander = NoExpansion(), policy: (@Sendable () -> CapturePolicy)? = nil) {
        let policy = policy ?? { SnapshotPolicy.current(db) }
        self.db = db; self.redactor = redactor; self.budget = budget
        self.search = search ?? HybridSearch(db: db, embedder: nil, index: nil, policy: policy)
        self.expander = expander; self.policy = policy
    }

    public func context(for r: ContextRequest) async throws -> RewriteContext {
        let window = r.liveWindowText.map { cutWindow(redactor.redact($0), field: redactor.redact(r.fieldText)) }
        guard r.memoryAllowed else { return RewriteContext(windowText: window) }
        let partial = PartialMemory()
        let outcome = await TimeBound.run(within: budget.memoryTimeout) { [self] () async -> Result<RewriteContext, any Error> in
            do { return .success(try await withMemory(r, window: window, partial: partial)) } catch { return .failure(error) }
        }
        guard let outcome else {
            // Keep what finished: the base memory (Plan 2 always kept the style note).
            let base = partial.base.withLock { $0 }
            Self.log.notice("memory context timed out; \(base == nil ? "window only" : "base memory only", privacy: .public)")
            return RewriteContext(windowText: window, memory: base ?? .empty)
        }
        return try outcome.get()
    }

    /// The trimmed base memory once loaded, for the time-out path.
    private final class PartialMemory: Sendable {
        let base = Mutex<BaseMemory?>(nil)
    }

    // MARK: - Memory

    private func withMemory(_ r: ContextRequest, window: String?, partial: PartialMemory) async throws -> RewriteContext {
        // One policy for the whole rewrite: every stage (and the search) judges by the same rules.
        let policy = self.policy()
        // Redacted like the prompt: secrets in the field or title never reach expansion or search.
        let field = redactor.redact(r.fieldText), title = redactor.redact(r.windowTitle ?? "")
        let queryTexts = field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [title, String((window ?? "").suffix(500))]
            : [field, title]
        let baseTerms = QueryTerms.extract(from: queryTexts)
        let expander = self.expander, timeout = budget.expansionTimeout, cloudAllowed = r.cloudAllowed
        async let expanded = baseTerms.isEmpty ? [] : expander.expand(baseTerms, cloudAllowed: cloudAllowed, timeout: timeout)

        let base = trimmed(try MemoryContext.base(db: db, surface: r.surface, now: r.now, policy: policy))
        partial.base.withLock { $0 = base }
        let terms = Self.union(baseTerms, await expanded)
        try Task.checkCancellation()

        let snapshots = SnapshotStore(db)
        let related = try relatedSnippets(terms: terms, request: r, policy: policy, store: snapshots)
        try Task.checkCancellation()
        let recent = try recentSnippets(request: r, excluding: related.ids, policy: policy, store: snapshots)
        try Task.checkCancellation()

        let query = queryTexts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let found = terms.isEmpty && query.isEmpty ? [] : try await search.search(
            query: query, terms: terms, scopes: [.chronicle, .wikiPage, .wikiFact], limit: budget.hitsMax, policy: policy)
        try Task.checkCancellation()
        let pages = try pageBriefs(for: found, policy: policy)
        try Task.checkCancellation()
        let openItems = try openItemLines(terms: terms, now: r.now, policy: policy)

        return RewriteContext(windowText: window, related: related.snippets, recent: recent,
                              memory: base, hits: fitted(found), pages: pages, openItems: openItems)
    }

    /// `base` then the new terms of `added`, case-folded duplicates removed.
    static func union(_ base: [String], _ added: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in base + added where seen.insert(t.lowercased()).inserted { out.append(t) }
        return out
    }

    private func trimmed(_ m: BaseMemory) -> BaseMemory {
        BaseMemory(digest: m.digest.map { String($0.prefix(budget.digestChars)) },
                   identity: m.identity.map { String($0.prefix(budget.identityChars)) },
                   workingMemory: Array(m.workingMemory.prefix(budget.workingMemoryMax)),
                   style: m.style.map { String($0.prefix(budget.styleChars)) })
    }

    /// At most `hitsMax` hits whose snippets total at most `hitsChars`.
    private func fitted(_ hits: [MemoryHit]) -> [MemoryHit] {
        var out: [MemoryHit] = []
        var remaining = budget.hitsChars
        let per = max(1, budget.hitsChars / max(1, budget.hitsMax))
        for var hit in hits.prefix(budget.hitsMax) where remaining > 0 {
            hit.snippet = String(hit.snippet.prefix(min(per, remaining)))
            guard !hit.snippet.isEmpty else { continue }
            remaining -= hit.snippet.count
            out.append(hit)
        }
        return out
    }

    /// Snapshots matching the terms, outside the current window, allowed by `policy` now.
    private func relatedSnippets(terms: [String], request r: ContextRequest, policy: CapturePolicy,
                                 store: SnapshotStore) throws -> (snippets: [ContextSnippet], ids: Set<Int64>) {
        guard !terms.isEmpty else { return ([], []) }
        let hits = try store.searchAny(terms: terms, excludingApp: r.app, excludingTitle: r.windowTitle,
                                       limit: budget.relatedMax * 3)
        let byID = Self.allowed(try store.snapshots(ids: hits.map(\.id)), policy: policy)
        var out: [ContextSnippet] = [], ids = Set<Int64>()
        var remaining = budget.relatedChars
        let per = max(1, budget.relatedChars / max(1, budget.relatedMax))
        for hit in hits where remaining > 0 && out.count < budget.relatedMax {
            guard let s = byID[hit.id] else { continue }
            let text = String(Excerpt.around(terms: terms, in: s.text, radius: per / 2).prefix(remaining))
            guard !text.isEmpty else { continue }
            remaining -= text.count
            ids.insert(hit.id)
            out.append(ContextSnippet(app: s.app, windowTitle: s.windowTitle, capturedAt: s.capturedAt, text: text))
        }
        return (out, ids)
    }

    /// Other windows' snapshots of the last `recentWindow`, allowed by `policy` now.
    private func recentSnippets(request r: ContextRequest, excluding relatedIDs: Set<Int64>, policy: CapturePolicy,
                                store: SnapshotStore) throws -> [ContextSnippet] {
        let cutoff = r.now.addingTimeInterval(-budget.recentWindow)
        let candidates = try store.recent(limit: 60).filter { hit in
            hit.capturedAt >= cutoff && !relatedIDs.contains(hit.id)
                && !(hit.app.caseInsensitiveCompare(r.app) == .orderedSame && hit.windowTitle == r.windowTitle)
        }
        let full = Self.allowed(try store.snapshots(ids: candidates.map(\.id)), policy: policy)
        var out: [ContextSnippet] = []
        var remaining = budget.recentChars
        let per = max(1, budget.recentChars / max(1, budget.recentMax))
        for hit in candidates where remaining > 0 && out.count < budget.recentMax {
            guard let s = full[hit.id] else { continue }
            let text = String(s.text.prefix(min(per, remaining)))
            guard !text.isEmpty else { continue }
            remaining -= text.count
            out.append(ContextSnippet(app: s.app, windowTitle: s.windowTitle, capturedAt: s.capturedAt, text: text))
        }
        return out
    }

    private static func allowed(_ snapshots: [Snapshot], policy: CapturePolicy) -> [Int64: Snapshot] {
        Dictionary(snapshots.filter { SnapshotPolicy.allows($0, policy: policy) }.compactMap { s in s.id.map { ($0, s) } },
                   uniquingKeysWith: { a, _ in a })
    }

    /// The pages of the top wiki hits (page hits and facts' pages, in hit order).
    private func pageBriefs(for hits: [MemoryHit], policy: CapturePolicy) throws -> [WikiPageBrief] {
        var slugs: [String] = []
        for hit in hits where hit.scope == .wikiPage || hit.scope == .wikiFact {
            if let slug = hit.slug, !slugs.contains(slug) { slugs.append(slug) }
        }
        guard !slugs.isEmpty else { return [] }
        return try db.reader.read { d in
            let pages = try slugs.compactMap { try WikiStore.page(slug: $0, in: d) }
            return try DerivedPolicy.filter(pages, ids: \.snapshotIDs, policy: policy, in: d).prefix(budget.pagesMax).map {
                WikiPageBrief(slug: $0.slug, title: $0.title, type: $0.type, summary: String($0.summary.prefix(budget.pageSummaryChars)))
            }
        }
    }

    /// Open flags whose text, person or project contains a term (accent- and case-insensitive),
    /// then those due within `openItemsDueWithin` (overdue included), as prompt lines.
    private func openItemLines(terms: [String], now: Date, policy: CapturePolicy) throws -> [String] {
        let flags = SalientFlagStore(db)
        let folded = terms.map(TextFold.fold).filter { !$0.isEmpty }
        let matching = folded.isEmpty ? [] : try flags.open(kinds: Set(FlagKind.allCases), limit: 500).filter { f in
            let hay = TextFold.fold([f.text, f.person, f.project].joined(separator: " "))
            return folded.contains { hay.contains($0) }
        }
        let due = try flags.dueSoon(within: budget.openItemsDueWithin, now: now, limit: 50)
        var seen = Set<Int64>(), candidates: [SalientFlag] = []
        for f in matching + due { if let id = f.id, seen.insert(id).inserted { candidates.append(f) } }
        guard !candidates.isEmpty else { return [] }
        let allowed = try db.reader.read { d in
            try DerivedPolicy.filter(candidates, ids: \.snapshotIDs, policy: policy, in: d)
        }
        return allowed.prefix(budget.openItemsMax).map(Self.line)
    }

    static func line(_ f: SalientFlag) -> String {
        var extras: [String] = []
        if !f.person.isEmpty { extras.append(f.person) }
        if let due = f.dueAt {
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.dateFormat = "yyyy-MM-dd"
            extras.append("due " + day.string(from: due))
        }
        return "\(f.kind.rawValue): \(f.text)" + (extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))")
    }

    /// At most `windowChars`; when longer, the portion ending at the field's text (if found), else the tail.
    /// Both arguments must already be redacted.
    public func cutWindow(_ text: String, field: String) -> String {
        guard text.count > budget.windowChars else { return text }
        let probe = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if !probe.isEmpty, let r = text.range(of: probe, options: .backwards) {
            return String(text[..<r.upperBound].suffix(budget.windowChars))
        }
        return String(text.suffix(budget.windowChars))
    }
}

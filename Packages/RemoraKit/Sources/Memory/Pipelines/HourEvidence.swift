import Capture
import Foundation
import GRDB
import Storage

/// One snapshot as the model sees it. `index` (1-based) is how the model cites it.
public struct EvidenceItem: Sendable, Equatable {
    public var index: Int
    public var snapshotID: Int64
    public var app: String
    public var title: String?
    public var domain: String?
    public var at: Date
    public var text: String

    public init(index: Int, snapshotID: Int64, app: String, title: String?, domain: String?, at: Date, text: String) {
        self.index = index; self.snapshotID = snapshotID; self.app = app; self.title = title
        self.domain = domain; self.at = at; self.text = text
    }
}

extension Array where Element == EvidenceItem {
    /// The snapshot ids of the cited items (1-based `index` order), in citation order, without
    /// duplicates; unknown indices are dropped.
    public func snapshotIDs(for indices: [Int]) -> [Int64] {
        var seen = Set<Int64>()
        return indices.compactMap { i in
            guard i >= 1, i <= count else { return nil }
            let id = self[i - 1].snapshotID
            return seen.insert(id).inserted ? id : nil
        }
    }
}

/// Focus time in one (app, domain) during a span.
public struct AppTime: Sendable, Equatable {
    public var app: String
    public var domain: String?
    public var seconds: TimeInterval

    public init(app: String, domain: String?, seconds: TimeInterval) {
        self.app = app; self.domain = domain; self.seconds = seconds
    }
}

/// What an hour span's prompts are built from. Built under the user's exclusions as they stand
/// now, so a snapshot or focus event of an app or site excluded after capture never reaches a
/// prompt, not even by name (F-58).
public struct HourEvidence: Sendable, Equatable {
    public var span: DateInterval
    public var items: [EvidenceItem]
    /// Descending by seconds.
    public var activity: [AppTime]

    public init(span: DateInterval, items: [EvidenceItem], activity: [AppTime]) {
        self.span = span; self.items = items; self.activity = activity
    }

    /// Total focus seconds in the span.
    public var focusSeconds: TimeInterval { activity.reduce(0) { $0 + $1.seconds } }

    /// The snapshot ids of the cited items, in citation order, without duplicates; unknown
    /// indices are dropped.
    public func snapshotIDs(for indices: [Int]) -> [Int64] { items.snapshotIDs(for: indices) }

    /// Longest window title kept in a prompt.
    static let maxTitleChars = 200

    /// Snapshots overlapping `span` (`first_captured_at < end AND captured_at >= start`: a rolled
    /// row counts in every hour it was live, F-29), allowed by `policy`, deduped by content hash,
    /// oldest first, fitted to the budget (see `fit`). Activity is the focus time per (app,
    /// domain) clipped to the span, allowed by `policy`, most first.
    ///
    /// `maxChars` (36,000) budgets snapshot **body text only**. The rest of the evidence block is
    /// bounded separately: titles are cut to `maxTitleChars`, app names and domains to
    /// `PipelinePrompt.maxNameChars`, and `<activity>` to `PipelinePrompt.maxActivityLines` lines.
    public static func build(db: AppDatabase, span: DateInterval, policy: CapturePolicy, maxChars: Int = 36_000,
                             perItem: Int = 3_000, minShare: Int = 400) throws -> HourEvidence {
        let (snapshots, events) = try db.reader.read { d in
            (try Snapshot.fetchAll(d, sql: """
                SELECT * FROM snapshots
                WHERE COALESCE(first_captured_at, captured_at) < ? AND captured_at >= ?
                ORDER BY captured_at, id
                """, arguments: [span.end, span.start]),
             try ActivityEvent.fetchAll(d, sql: """
                SELECT * FROM activity_events WHERE started_at < ? AND ended_at > ? ORDER BY started_at, id
                """, arguments: [span.end, span.start]))
        }
        let items = Self.items(allowed(snapshots, policy: policy), maxChars: maxChars, perItem: perItem,
                               minShare: minShare)
        return HourEvidence(span: span, items: items, activity: activity(events, span: span, policy: policy))
    }

    /// The snapshots `policy` allows, in order, without content-hash duplicates (the first kept).
    /// Shared by every evidence builder (hour, working memory).
    static func allowed(_ snapshots: [Snapshot], policy: CapturePolicy) -> [Snapshot] {
        var hashes = Set<String>()
        return snapshots.filter { s in
            s.id != nil && SnapshotPolicy.allows(s, policy: policy) && hashes.insert(s.contentHash).inserted
        }
    }

    /// `snapshots` (already allowed) fitted to the budget (`fit`), as numbered evidence items in
    /// the same order. Titles are cut to `maxTitleChars`.
    static func items(_ snapshots: [Snapshot], maxChars: Int, perItem: Int, minShare: Int) -> [EvidenceItem] {
        fit(snapshots.map(\.text), maxChars: maxChars, perItem: perItem, minShare: minShare).enumerated().map { n, k in
            let s = snapshots[k.index]
            return EvidenceItem(index: n + 1, snapshotID: s.id ?? 0, app: s.app,
                                title: s.windowTitle.map { String($0.prefix(maxTitleChars)) }, domain: s.domain,
                                at: s.capturedAt, text: k.text)
        }
    }

    static func activity(_ events: [ActivityEvent], span: DateInterval, policy: CapturePolicy) -> [AppTime] {
        activity(events.map { e in
            ActivityStore.FocusTotal(app: e.app, bundleID: e.bundleID, windowTitle: e.windowTitle, domain: e.domain,
                                     seconds: min(e.endedAt, span.end).timeIntervalSince(max(e.startedAt, span.start)))
        }, policy: policy)
    }

    /// Focus seconds per (app, domain) from clipped totals that `policy` allows (judged as the
    /// focus events they sum), most first. Shared by the hour evidence and the rollups.
    static func activity(_ totals: [ActivityStore.FocusTotal], policy: CapturePolicy) -> [AppTime] {
        struct Key: Hashable { var app: String; var domain: String? }
        var seconds: [Key: TimeInterval] = [:]
        for t in totals where t.seconds > 0 {
            let event = ActivityEvent(app: t.app, bundleID: t.bundleID, windowTitle: t.windowTitle, domain: t.domain,
                                      startedAt: .distantPast, endedAt: .distantPast)
            guard SnapshotPolicy.allows(event, policy: policy) else { continue }
            let domain = t.domain.flatMap { $0.isEmpty ? nil : $0 }
            seconds[Key(app: t.app, domain: domain), default: 0] += t.seconds
        }
        return seconds.map { AppTime(app: $0.key.app, domain: $0.key.domain, seconds: $0.value) }
            .sorted { ($0.seconds, $1.app, $1.domain ?? "") > ($1.seconds, $0.app, $0.domain ?? "") }
    }


    /// Fits texts (in order) into `maxChars`:
    /// - each text is cut to `perItem` first;
    /// - when more than `maxChars / minShare` texts remain, an evenly spaced subset of that many
    ///   is kept (first and last included), so the whole span stays covered;
    /// - if still over budget, every text longer than a common cap `c >= minShare` is cut to `c`,
    ///   with `c` as large as the budget allows (short texts give their unused share to long ones).
    /// A cut text ends with `…` inside its length. Returns the kept texts with their input index.
    static func fit(_ texts: [String], maxChars: Int, perItem: Int, minShare: Int) -> [(index: Int, text: String)] {
        guard !texts.isEmpty, maxChars > 0 else { return [] }
        var lengths = texts.map { min($0.count, perItem) }
        var indices = Array(texts.indices)
        let fitting = max(1, maxChars / max(minShare, 1))
        if indices.count > fitting {
            indices = sample(indices, count: fitting)
            lengths = indices.map { min(texts[$0].count, perItem) }
        }
        var cap = perItem
        if lengths.reduce(0, +) > maxChars {
            // Water-filling: the largest cap whose total fits.
            let sorted = lengths.sorted()
            var remaining = maxChars
            cap = minShare
            for (n, length) in sorted.enumerated() {
                let share = remaining / (sorted.count - n)
                if length <= share { remaining -= length; continue }
                cap = max(minShare, share)
                break
            }
        }
        return indices.map { i in (index: i, text: cut(texts[i], to: min(cap, perItem))) }
    }

    /// `count` indices spread evenly over `indices`, first and last included.
    private static func sample(_ indices: [Int], count: Int) -> [Int] {
        guard count > 1 else { return [indices[0]] }
        let step = Double(indices.count - 1) / Double(count - 1)
        return (0..<count).map { indices[Int((Double($0) * step).rounded())] }
    }

    private static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(limit - 1, 0))) + "…"
    }
}

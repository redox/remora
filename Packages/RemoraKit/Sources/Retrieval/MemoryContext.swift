import Capture
import Foundation
import GRDB
import Storage

/// The memory every rewrite (and Plan 5 chat) starts from, before any search.
public struct BaseMemory: Sendable, Equatable {
    public var digest: String?
    public var identity: String?
    /// Current working-memory items, most relevant first.
    public var workingMemory: [String]
    /// The all-surfaces (`"*"`) style note, then the surface's own.
    public var style: String?

    public init(digest: String? = nil, identity: String? = nil, workingMemory: [String] = [], style: String? = nil) {
        self.digest = digest; self.identity = identity; self.workingMemory = workingMemory; self.style = style
    }

    public static let empty = BaseMemory()
}

/// A wiki page as the rewrite prompt shows it.
public struct WikiPageBrief: Sendable, Equatable {
    public var slug: String
    public var title: String
    public var type: WikiPageType
    public var summary: String

    public init(slug: String, title: String, type: WikiPageType, summary: String) {
        self.slug = slug; self.title = title; self.type = type; self.summary = summary
    }
}

public enum MemoryContext {
    /// The style surface whose note applies everywhere.
    public static let allSurfaces = "*"

    /// The current digest (none while a forget has left it dirty, `ForgetMarks`) and identity, the working-memory items still alive now (unseen for at
    /// most 24 h, decayed relevance ≥ 0.05), and the style notes for `surface`. Working-memory
    /// items whose snapshots are all excluded under `policy` (fresh exclusions when nil, `.denyAll`
    /// when they cannot be loaded) or all deleted are left out (`DerivedPolicy.requiringLiveEvidence`,
    /// the working-memory prompt's own filter). Untrimmed: callers apply their budgets.
    public static func base(db: AppDatabase, surface: String, now: Date, policy: CapturePolicy? = nil) throws -> BaseMemory {
        let policy = policy ?? SnapshotPolicy.current(db)
        let store = WorkingMemoryStore(db)
        let styles = StyleNoteStore(db)
        return try db.reader.read { d in
            // After a forget the digest may name forgotten content until a rebuild is stored.
            let digest = ForgetMarks.digestIsDirty(in: d) ? nil
                : try String.fetchOne(d, sql: "SELECT body FROM memory_digest ORDER BY id DESC LIMIT 1")
            let identity = try IdentityStore.current(in: d)?.body
            let alive = try store.top(WorkingMemoryStore.maxItems, now: now, in: d).filter {
                now.timeIntervalSince($0.lastSeenAt) <= WorkingMemoryStore.maxAge
                    && WorkingMemoryStore.decayed($0, now: now) >= WorkingMemoryStore.minRelevance
            }
            let items = try DerivedPolicy.requiringLiveEvidence(alive, ids: \.snapshotIDs, policy: policy, in: d)
            let surfaces = surface == allSurfaces ? [allSurfaces] : [allSurfaces, surface]
            let notes = try surfaces.compactMap { try styles.row(for: $0, in: d)?.notes }.compactMap(nonEmpty)
            return BaseMemory(digest: digest.flatMap(nonEmpty), identity: identity.flatMap(nonEmpty),
                              workingMemory: items.map(\.text).compactMap(nonEmpty),
                              style: notes.isEmpty ? nil : notes.joined(separator: "\n"))
        }
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

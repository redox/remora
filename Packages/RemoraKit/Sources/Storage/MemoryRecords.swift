import Foundation
import GRDB

// Plan 4 (background memory) records over the `v4` tables. JSON columns (`snapshot_ids`,
// `aliases`, `metadata`, …) are TEXT holding JSON, encoded by GRDB from the Codable values.
// Callers redact LLM output before storing it here.

// MARK: - Enums (raw values = the CHECK values)

public enum JobKind: String, Codable, Sendable, CaseIterable {
    case workingMemory = "working_memory"
    case timeLedger = "time_ledger"
    case hour
    case dayRollup = "day_rollup"
    case weekRollup = "week_rollup"
    case monthRollup = "month_rollup"
    case yearRollup = "year_rollup"
    case wikiRewrite = "wiki_rewrite"
    case embeddings
    case styleNotes = "style_notes"
    case identity
    case compaction
    // Plan 5 proactive jobs (`jobs.kind` has no CHECK).
    case morningBrief = "morning_brief"
    case eveningWrap = "evening_wrap"
    case nudgeScan = "nudge_scan"
    case routineScan = "routine_scan"
    /// Plan 5: the digest rebuilt after a forget (only through `runNow`, or left pending until the
    /// gate allows it; never planned).
    case digestRebuild = "digest_rebuild"

    /// Lower runs first (plan 4 and plan 5 pinned values): briefs, then nudge scans, then memory.
    public var priority: Int {
        switch self {
        case .digestRebuild: -3
        case .morningBrief, .eveningWrap: -2
        case .nudgeScan: -1
        case .workingMemory: 0
        case .timeLedger: 1
        case .hour: 2
        case .dayRollup: 3
        case .weekRollup: 4
        case .monthRollup: 5
        case .yearRollup: 6
        case .wikiRewrite: 7
        case .embeddings: 8
        case .styleNotes: 9
        case .identity: 10
        case .compaction: 11
        case .routineScan: 12
        }
    }
}

public enum JobStatus: String, Codable, Sendable, CaseIterable { case pending, running, done, skipped, failed }

public enum ChronicleLevel: String, Codable, Sendable, CaseIterable {
    case hour, day, week, month, year

    /// The levels a chronicle of this level rolls up into: a day feeds both its ISO week and
    /// its month; weeks feed nothing (a month is built from days).
    public var parents: [ChronicleLevel] {
        switch self {
        case .hour: [.day]
        case .day: [.week, .month]
        case .week: []
        case .month: [.year]
        case .year: []
        }
    }

    /// The job that writes a chronicle of this level (one mapping for the planner, the rollups,
    /// compaction and the provenance cascade).
    public var jobKind: JobKind {
        switch self {
        case .hour: .hour
        case .day: .dayRollup
        case .week: .weekRollup
        case .month: .monthRollup
        case .year: .yearRollup
        }
    }

    /// The calendar unit of this level's period (ISO week for `.week`, with an ISO 8601 calendar).
    public var calendarComponent: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

/// The one calendar memory periods are computed in (plan 4 pinned value): ISO 8601 in the local
/// time zone, auto-updating, so a time-zone change (travel, DST rules) is followed without a
/// relaunch. The app's planner, scheduler and runners and the MCP tools all use it; never
/// `Calendar.current`, whose week start depends on the locale and would not line up with the
/// stored week keys.
public enum MemoryCalendar {
    public static var local: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .autoupdatingCurrent
        return c
    }
}

public enum WikiPageType: String, Codable, Sendable, CaseIterable { case person, project, topic, tool, org }
public enum FactSubject: String, Codable, Sendable, CaseIterable {
    case user, world
    case thirdParty = "third_party"
}
public enum FactBasis: String, Codable, Sendable, CaseIterable {
    case observedAction = "observed_action"
    case onScreenContent = "on_screen_content"
    case userStated = "user_stated"
    case inferred
}
public enum FactWorth: String, Codable, Sendable, CaseIterable { case core, detail }
public enum FlagKind: String, Codable, Sendable, CaseIterable { case event, email, commitment, todo }
public enum FlagOwner: String, Codable, Sendable, CaseIterable { case user, other }
public enum FlagStatus: String, Codable, Sendable, CaseIterable { case open, done, dismissed, expired }
public enum IdentitySource: String, Codable, Sendable, CaseIterable { case llm, user }

// MARK: - jobs

public struct Job: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var kind: JobKind
    public var periodKey: String
    public var periodStart: Date?
    public var periodEnd: Date?
    public var status: JobStatus
    public var priority: Int
    public var attempts: Int
    public var nextRunAt: Date
    /// An error code only (`LLMError.errorCode`, a `MemoryError` case name or "timeout"), never content.
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    /// `priority` defaults to `kind.priority`, `updatedAt` to `createdAt`.
    public init(id: Int64? = nil, kind: JobKind, periodKey: String, periodStart: Date? = nil,
                periodEnd: Date? = nil, status: JobStatus = .pending, priority: Int? = nil, attempts: Int = 0,
                nextRunAt: Date, lastError: String? = nil, createdAt: Date, updatedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.periodKey = periodKey; self.periodStart = periodStart
        self.periodEnd = periodEnd; self.status = status; self.priority = priority ?? kind.priority
        self.attempts = attempts; self.nextRunAt = nextRunAt; self.lastError = lastError
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    public static let databaseTableName = "jobs"

    enum CodingKeys: String, CodingKey {
        case id, kind, status, priority, attempts
        case periodKey = "period_key"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case nextRunAt = "next_run_at"
        case lastError = "last_error"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - working_memory

public struct WorkingMemoryItem: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var text: String
    public var kind: String
    public var normKey: String
    public var relevance: Double
    public var snapshotIDs: [Int64]
    public var addedAt: Date
    public var lastSeenAt: Date
    public var llmCallID: Int64?

    public init(id: Int64? = nil, text: String, kind: String, normKey: String, relevance: Double,
                snapshotIDs: [Int64] = [], addedAt: Date, lastSeenAt: Date, llmCallID: Int64? = nil) {
        self.id = id; self.text = text; self.kind = kind; self.normKey = normKey; self.relevance = relevance
        self.snapshotIDs = snapshotIDs; self.addedAt = addedAt; self.lastSeenAt = lastSeenAt
        self.llmCallID = llmCallID
    }

    public static let databaseTableName = "working_memory"

    enum CodingKeys: String, CodingKey {
        case id, text, kind, relevance
        case normKey = "norm_key"
        case snapshotIDs = "snapshot_ids"
        case addedAt = "added_at"
        case lastSeenAt = "last_seen_at"
        case llmCallID = "llm_call_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - chronicle

/// A project's share of a span's focus time, with the apps and domains that attributed it.
public struct ProjectShare: Codable, Sendable, Equatable {
    public var name: String
    public var apps: [String]
    public var domains: [String]
    public var share: Double

    public init(name: String, apps: [String] = [], domains: [String] = [], share: Double) {
        self.name = name; self.apps = apps; self.domains = domains; self.share = share
    }
}

public struct Chronicle: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    /// Stored as a JSON object. Missing keys decode to the defaults, so the column default
    /// `'{}'` reads as `Metadata()`.
    public struct Metadata: Codable, Sendable, Equatable {
        public var projects: [ProjectShare]
        public var highlights: [String]
        public var apps: [String]
        /// Wiki slugs of the entities extracted from this span (hour call B).
        public var entities: [String]
        /// Consecutive sparse hours merged into this span (1 for a plain hour).
        public var mergedHours: Int
        /// Hour call B (entities, facts, flags) has run for this span.
        public var entitiesDone: Bool

        public init(projects: [ProjectShare] = [], highlights: [String] = [], apps: [String] = [],
                    entities: [String] = [], mergedHours: Int = 1, entitiesDone: Bool = false) {
            self.projects = projects; self.highlights = highlights; self.apps = apps
            self.entities = entities; self.mergedHours = mergedHours; self.entitiesDone = entitiesDone
        }

        enum CodingKeys: String, CodingKey {
            case projects, highlights, apps, entities
            case mergedHours = "merged_hours"
            case entitiesDone = "entities_done"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Metadata()
            projects = try c.decodeIfPresent([ProjectShare].self, forKey: .projects) ?? d.projects
            highlights = try c.decodeIfPresent([String].self, forKey: .highlights) ?? d.highlights
            apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? d.apps
            entities = try c.decodeIfPresent([String].self, forKey: .entities) ?? d.entities
            mergedHours = try c.decodeIfPresent(Int.self, forKey: .mergedHours) ?? d.mergedHours
            entitiesDone = try c.decodeIfPresent(Bool.self, forKey: .entitiesDone) ?? d.entitiesDone
        }
    }

    public var id: Int64?
    public var level: ChronicleLevel
    public var periodKey: String
    public var periodStart: Date
    public var periodEnd: Date
    public var summary: String
    public var metadata: Metadata
    public var snapshotIDs: [Int64]
    public var childIDs: [Int64]
    public var isDirty: Bool
    public var generatedAt: Date
    public var llmCallID: Int64?

    public init(id: Int64? = nil, level: ChronicleLevel, periodKey: String, periodStart: Date, periodEnd: Date,
                summary: String, metadata: Metadata = Metadata(), snapshotIDs: [Int64] = [],
                childIDs: [Int64] = [], isDirty: Bool = false, generatedAt: Date, llmCallID: Int64? = nil) {
        self.id = id; self.level = level; self.periodKey = periodKey; self.periodStart = periodStart
        self.periodEnd = periodEnd; self.summary = summary; self.metadata = metadata
        self.snapshotIDs = snapshotIDs; self.childIDs = childIDs; self.isDirty = isDirty
        self.generatedAt = generatedAt; self.llmCallID = llmCallID
    }

    public static let databaseTableName = "chronicle"

    enum CodingKeys: String, CodingKey {
        case id, level, summary, metadata
        case periodKey = "period_key"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case snapshotIDs = "snapshot_ids"
        case childIDs = "child_ids"
        case isDirty = "is_dirty"
        case generatedAt = "generated_at"
        case llmCallID = "llm_call_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - wiki_pages / wiki_facts

public struct WikiPage: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var slug: String
    public var type: WikiPageType
    public var title: String
    public var aliases: [String]
    public var summary: String
    public var body: String
    public var links: [String]
    public var mentionCount: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var isDirty: Bool
    public var snapshotIDs: [Int64]
    public var updatedAt: Date
    public var llmCallID: Int64?

    public init(id: Int64? = nil, slug: String, type: WikiPageType, title: String, aliases: [String] = [],
                summary: String = "", body: String = "", links: [String] = [], mentionCount: Int = 0,
                firstSeen: Date, lastSeen: Date, isDirty: Bool = false, snapshotIDs: [Int64] = [],
                updatedAt: Date, llmCallID: Int64? = nil) {
        self.id = id; self.slug = slug; self.type = type; self.title = title; self.aliases = aliases
        self.summary = summary; self.body = body; self.links = links; self.mentionCount = mentionCount
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.isDirty = isDirty
        self.snapshotIDs = snapshotIDs; self.updatedAt = updatedAt; self.llmCallID = llmCallID
    }

    public static let databaseTableName = "wiki_pages"

    enum CodingKeys: String, CodingKey {
        case id, slug, type, title, aliases, summary, body, links
        case mentionCount = "mention_count"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case isDirty = "is_dirty"
        case snapshotIDs = "snapshot_ids"
        case updatedAt = "updated_at"
        case llmCallID = "llm_call_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A bitemporal fact: true from `validAt` until `invalidAt` (nil = still true); `recordedAt`
/// is when Remora learned it.
public struct WikiFact: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var slug: String
    public var fact: String
    public var normKey: String
    public var subject: FactSubject
    public var basis: FactBasis
    public var worth: FactWorth
    public var snapshotIDs: [Int64]
    public var validAt: Date
    public var invalidAt: Date?
    public var supersededBy: Int64?
    public var recordedAt: Date
    public var lastConfirmedAt: Date
    public var llmCallID: Int64?

    public init(id: Int64? = nil, slug: String, fact: String, normKey: String, subject: FactSubject,
                basis: FactBasis, worth: FactWorth, snapshotIDs: [Int64] = [], validAt: Date,
                invalidAt: Date? = nil, supersededBy: Int64? = nil, recordedAt: Date, lastConfirmedAt: Date,
                llmCallID: Int64? = nil) {
        self.id = id; self.slug = slug; self.fact = fact; self.normKey = normKey; self.subject = subject
        self.basis = basis; self.worth = worth; self.snapshotIDs = snapshotIDs; self.validAt = validAt
        self.invalidAt = invalidAt; self.supersededBy = supersededBy; self.recordedAt = recordedAt
        self.lastConfirmedAt = lastConfirmedAt; self.llmCallID = llmCallID
    }

    public static let databaseTableName = "wiki_facts"

    enum CodingKeys: String, CodingKey {
        case id, slug, fact, subject, basis, worth
        case normKey = "norm_key"
        case snapshotIDs = "snapshot_ids"
        case validAt = "valid_at"
        case invalidAt = "invalid_at"
        case supersededBy = "superseded_by"
        case recordedAt = "recorded_at"
        case lastConfirmedAt = "last_confirmed_at"
        case llmCallID = "llm_call_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - identity

/// One revision of the identity profile; the newest row is current.
public struct IdentityRevision: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var body: String
    public var source: IdentitySource
    public var createdAt: Date
    public var llmCallID: Int64?

    public init(id: Int64? = nil, body: String, source: IdentitySource, createdAt: Date, llmCallID: Int64? = nil) {
        self.id = id; self.body = body; self.source = source; self.createdAt = createdAt; self.llmCallID = llmCallID
    }

    public static let databaseTableName = "identity"

    enum CodingKeys: String, CodingKey {
        case id, body, source
        case createdAt = "created_at"
        case llmCallID = "llm_call_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - salient_flags

/// An event, email, commitment or todo seen on screen. Open commitments/todos are the open loops.
public struct SalientFlag: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var kind: FlagKind
    public var text: String
    public var owner: FlagOwner
    public var person: String
    public var project: String
    public var dueAt: Date?
    public var status: FlagStatus
    public var confidence: Double
    public var quote: String
    public var snapshotIDs: [Int64]
    public var closeSnapshotIDs: [Int64]
    public var periodKey: String?
    public var dedupeKey: String
    public var createdAt: Date
    public var lastSeenAt: Date
    public var closedAt: Date?
    public var checkedAt: Date?
    public var llmCallID: Int64?

    public init(id: Int64? = nil, kind: FlagKind, text: String, owner: FlagOwner, person: String = "",
                project: String = "", dueAt: Date? = nil, status: FlagStatus = .open, confidence: Double = 0.5,
                quote: String = "", snapshotIDs: [Int64] = [], closeSnapshotIDs: [Int64] = [],
                periodKey: String? = nil, dedupeKey: String, createdAt: Date, lastSeenAt: Date,
                closedAt: Date? = nil, checkedAt: Date? = nil, llmCallID: Int64? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.owner = owner; self.person = person
        self.project = project; self.dueAt = dueAt; self.status = status; self.confidence = confidence
        self.quote = quote; self.snapshotIDs = snapshotIDs; self.closeSnapshotIDs = closeSnapshotIDs
        self.periodKey = periodKey; self.dedupeKey = dedupeKey; self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt; self.closedAt = closedAt; self.checkedAt = checkedAt
        self.llmCallID = llmCallID
    }

    public static let databaseTableName = "salient_flags"

    enum CodingKeys: String, CodingKey {
        case id, kind, text, owner, person, project, status, confidence, quote
        case dueAt = "due_at"
        case snapshotIDs = "snapshot_ids"
        case closeSnapshotIDs = "close_snapshot_ids"
        case periodKey = "period_key"
        case dedupeKey = "dedupe_key"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
        case closedAt = "closed_at"
        case checkedAt = "checked_at"
        case llmCallID = "llm_call_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - time_ledger / time_rules

/// Focus seconds in one hour for one (project, app, domain). Empty strings mean "none"
/// (the key columns are NOT NULL so the primary key stays unique).
public struct TimeLedgerRow: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var hourStart: Date
    public var project: String
    public var app: String
    public var domain: String
    public var seconds: Double

    public init(hourStart: Date, project: String, app: String, domain: String = "", seconds: Double) {
        self.hourStart = hourStart; self.project = project; self.app = app; self.domain = domain
        self.seconds = seconds
    }

    public static let databaseTableName = "time_ledger"

    enum CodingKeys: String, CodingKey {
        case project, app, domain, seconds
        case hourStart = "hour_start"
    }
}

/// Maps activity to a project. `source` is "user" for rules the user made (kept by delete-all);
/// any other source is derived and deleted with captured data.
public struct TimeRule: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let userSource = "user"

    public var id: Int64?
    public var project: String
    public var app: String?
    public var domain: String?
    public var titleContains: String?
    public var source: String
    public var createdAt: Date

    public init(id: Int64? = nil, project: String, app: String? = nil, domain: String? = nil,
                titleContains: String? = nil, source: String = TimeRule.userSource, createdAt: Date) {
        self.id = id; self.project = project; self.app = app; self.domain = domain
        self.titleContains = titleContains; self.source = source; self.createdAt = createdAt
    }

    public static let databaseTableName = "time_rules"

    enum CodingKeys: String, CodingKey {
        case id, project, app, domain, source
        case titleContains = "title_contains"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - embeddings

/// One vector per owner row (`owner_table` = chronicle / wiki_pages / wiki_facts).
/// `vector` is float32 little-endian.
public struct EmbeddingRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var ownerTable: String
    public var ownerID: Int64
    public var modelID: String
    public var revision: Int
    public var dims: Int
    public var vector: Data
    public var contentHash: String
    public var createdAt: Date

    public init(id: Int64? = nil, ownerTable: String, ownerID: Int64, modelID: String, revision: Int, dims: Int,
                vector: Data, contentHash: String, createdAt: Date) {
        self.id = id; self.ownerTable = ownerTable; self.ownerID = ownerID; self.modelID = modelID
        self.revision = revision; self.dims = dims; self.vector = vector; self.contentHash = contentHash
        self.createdAt = createdAt
    }

    public static let databaseTableName = "embeddings"

    enum CodingKeys: String, CodingKey {
        case id, revision, dims, vector
        case ownerTable = "owner_table"
        case ownerID = "owner_id"
        case modelID = "model_id"
        case contentHash = "content_hash"
        case createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - memory_digest

public struct MemoryDigest: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var body: String
    public var createdAt: Date
    public var llmCallID: Int64?

    public init(id: Int64? = nil, body: String, createdAt: Date, llmCallID: Int64? = nil) {
        self.id = id; self.body = body; self.createdAt = createdAt; self.llmCallID = llmCallID
    }

    public static let databaseTableName = "memory_digest"

    enum CodingKeys: String, CodingKey {
        case id, body
        case createdAt = "created_at"
        case llmCallID = "llm_call_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

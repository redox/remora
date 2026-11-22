import Capture
import Foundation
import Redaction
import Storage

public actor MeetingImporter {
    public struct SyncResult: Equatable, Sendable {
        public let saved: Int
        public let reachedLimit: Bool
    }

    private let db: AppDatabase
    private let store: ImportedMeetingStore
    private let settings: SettingsStore
    private let redactor = Redactor()
    private let granola: GranolaAuthorization
    private let now: @Sendable () -> Date
    private var inProgress: Set<UUID> = []

    public init(db: AppDatabase, granola: GranolaAuthorization, now: @escaping @Sendable () -> Date = Date.init) {
        self.db = db
        self.store = ImportedMeetingStore(db)
        self.settings = SettingsStore(db)
        self.granola = granola
        self.now = now
    }

    public func search(_ query: String) throws -> [ImportedMeeting] {
        try search(query, forChat: false)
    }

    public func searchForChat(_ query: String) throws -> [ImportedMeeting] {
        guard (try? store.chatAccessEnabled()) == true,
              (try? settings.isPaused(now: now())) == false else { return [] }
        let results = try search(query, forChat: true)
        return (try? store.chatAccessEnabled()) == true ? results : []
    }

    private func search(_ query: String, forChat: Bool) throws -> [ImportedMeeting] {
        let policy = SnapshotPolicy.current(db)
        let sources = Dictionary(uniqueKeysWithValues: try store.sources().map { ($0.id, $0) })
        return try store.search(query, limit: forChat ? 30 : 100).filter { meeting in
            guard let source = sources[meeting.sourceID] else { return false }
            return Self.allows(source, title: meeting.title, policy: policy)
        }
    }

    public func sync(_ source: MeetingSource, since: Date) async throws -> SyncResult {
        guard inProgress.insert(source.id).inserted else { throw MeetingImportError.alreadySyncing }
        defer { inProgress.remove(source.id) }

        let generation = try DataGeneration.current(db)
        let started = now()
        try checkConnection(source)
        let endpoint = try MeetingEndpoint(source.provider, source.endpoint)
        let client: MeetingMCPClient
        if source.provider == .granola {
            do {
                client = try await .connect(endpoint: endpoint.url, token: granola.token())
            } catch MeetingImportError.httpStatus(401) {
                client = try await .connect(endpoint: endpoint.url, token: granola.token(forceRefresh: true))
            }
        } else {
            client = try await .connect(endpoint: endpoint.url, token: nil)
        }
        do {
            let result = try await importPages(from: source, since: since, generation: generation, client: client)
            try checkConnection(source)
            if !result.reachedLimit { try store.recordSync(source, at: started, generation: generation) }
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }

    func importPages(
        from source: MeetingSource, since: Date, generation: Int, client: any MeetingMCPCalling
    ) async throws -> SyncResult {
        try checkConnection(source)
        let adapter = try await MeetingMCPAdapter(provider: source.provider, client: client)
        var cursor: MeetingMCPAdapter.Cursor?
        var seen: Set<String> = []
        var saved = 0
        for _ in 0..<20 {
            try checkConnection(source)
            let page = try await adapter.page(since: since, cursor: cursor)
            let candidates = try page.meetings.filter { meeting in
                guard meeting.startedAt >= since, meeting.startedAt <= now(),
                      seen.insert(meeting.id).inserted,
                      Self.allows(source, title: meeting.title, policy: SnapshotPolicy.current(db)) else { return false }
                return try !store.isForgotten(meeting.id, source: source)
            }
            try checkConnection(source)
            let summaries = try await adapter.batchSummaries(for: candidates)
            for meeting in candidates {
                try checkConnection(source)
                guard Self.allows(source, title: meeting.title, policy: SnapshotPolicy.current(db)) else { continue }
                let body = try await adapter.body(for: meeting, summary: summaries[meeting.id])
                try Task.checkCancellation()
                guard !body.isEmpty else { continue }
                let row = ImportedMeeting(sourceID: source.id, remoteID: meeting.id, startedAt: meeting.startedAt,
                                          title: String(redactor.redact(meeting.title).prefix(300)),
                                          body: String(redactor.redact(body).prefix(1_000_000)))
                let result = try store.write(row, source: source, generation: generation, now: now()) { patterns in
                    Self.allows(source, title: meeting.title,
                                policy: CapturePolicy(userRules: patterns.compactMap(ExclusionRule.init(pattern:))))
                }
                if result == .saved { saved += 1 }
            }
            guard let next = page.next else { return SyncResult(saved: saved, reachedLimit: false) }
            guard next != cursor else { throw MeetingImportError.invalidResponse }
            cursor = next
        }
        return SyncResult(saved: saved, reachedLimit: true)
    }

    private func checkConnection(_ source: MeetingSource) throws {
        try Task.checkCancellation()
        guard try store.sources().contains(source) else { throw CancellationError() }
        guard (try? settings.isPaused(now: now())) == false else { throw MeetingImportError.paused }
        guard Self.allows(source, policy: SnapshotPolicy.current(db)) else { throw MeetingImportError.excluded }
    }

    private static func allows(_ source: MeetingSource, title: String? = nil, policy: CapturePolicy) -> Bool {
        let url = URL(string: source.endpoint)
        if source.provider == .quill {
            let bundleID = "com.quillmeetings.Quill-desktop"
            return ["Quill", source.provider.title].allSatisfy { app in
                policy.shouldCapture(WindowContext(app: app, bundleID: bundleID, windowTitle: title, url: url))
            }
        }
        return policy.shouldCapture(WindowContext(app: source.provider.title, windowTitle: title, url: url))
    }
}

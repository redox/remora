import Foundation
import MeetingImport
import Observation
import Storage

@MainActor @Observable
final class MeetingSourcesModel {
    private(set) var sources: [MeetingSource] = []
    private(set) var revision = 0
    private(set) var syncing: Set<UUID> = []
    private(set) var statuses: [UUID: String] = [:]
    private(set) var connecting = false
    private(set) var errorMessage: String?
    private(set) var chatAccessEnabled = false

    @ObservationIgnored private let store: ImportedMeetingStore
    @ObservationIgnored let importer: MeetingImporter
    @ObservationIgnored private let granola: GranolaAuthorization
    @ObservationIgnored private var automaticSync: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var manualSync: [UUID: Task<Void, Never>] = [:]

    init(db: AppDatabase) {
        store = ImportedMeetingStore(db)
        granola = GranolaAuthorization(browser: SystemBrowser())
        importer = MeetingImporter(db: db, granola: granola)
        reload()
    }

    func start() {
        guard automaticSync == nil else { return }
        automaticSync = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncRecent()
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            }
        }
    }

    func prepareForReset() {
        automaticSync?.cancel()
        automaticSync = nil
        connectionTask?.cancel()
        for task in manualSync.values { task.cancel() }
    }

    func didReset() async {
        do { try await granola.disconnect() } catch { errorMessage = "Could not remove the Granola sign-in." }
        statuses.removeAll()
        reload()
    }

    func connect(provider: MeetingSource.Provider, endpoint: String, since: Date) {
        guard !connecting else { return }
        errorMessage = nil
        connecting = true
        connectionTask = Task { [weak self] in
            guard let self else { return }
            defer { connecting = false; connectionTask = nil }
            do {
                let endpoint = try MeetingEndpoint(provider, endpoint)
                if provider == .granola { try await granola.signIn() }
                try Task.checkCancellation()
                if let existing = sources.first(where: { $0.provider == provider && $0.endpoint == endpoint.url.absoluteString }) {
                    await sync(existing, since: since)
                } else {
                    let source = MeetingSource(provider: provider, endpoint: endpoint.url.absoluteString,
                                               initialSince: since)
                    try store.save(source)
                    reload()
                    await sync(source, since: since)
                }
            } catch is CancellationError {
            } catch {
                errorMessage = Self.message(error)
            }
        }
    }

    func syncNow(_ source: MeetingSource, since: Date) {
        guard manualSync[source.id] == nil, !syncing.contains(source.id) else { return }
        manualSync[source.id] = Task { [weak self] in
            guard let self else { return }
            defer { manualSync[source.id] = nil }
            await sync(source, since: since)
        }
    }

    func disconnect(_ source: MeetingSource) async {
        manualSync[source.id]?.cancel()
        do {
            try store.disconnect(source)
            statuses[source.id] = nil
            reload()
            if source.provider == .granola { try await granola.disconnect() }
        } catch {
            errorMessage = "Could not finish disconnecting the source."
        }
    }

    func forget(_ meeting: ImportedMeeting) {
        do {
            try store.forget(meeting)
            revision += 1
        } catch {
            errorMessage = "Could not forget this meeting."
        }
    }

    func setChatAccess(_ enabled: Bool) {
        do {
            try store.setChatAccessEnabled(enabled)
            chatAccessEnabled = enabled
        } catch {
            errorMessage = "Could not save the meeting access setting."
        }
    }

    func search(_ query: String) async throws -> [ImportedMeeting] {
        try await importer.search(query)
    }

    private func syncRecent() async {
        for source in sources where !Task.isCancelled {
            let now = Date()
            let previous = try? store.lastSyncDate(for: source)
            let recent = min(previous ?? now, now).addingTimeInterval(-2 * 86_400)
            let since = previous == nil ? source.initialSince ?? recent : recent
            await sync(source, since: since)
        }
    }

    private func sync(_ source: MeetingSource, since: Date) async {
        guard syncing.insert(source.id).inserted else { return }
        defer {
            syncing.remove(source.id)
            revision += 1
        }
        do {
            let result = try await importer.sync(source, since: since)
            guard sources.contains(source) else { return }
            statuses[source.id] = result.reachedLimit ? "Import limit reached. Try a more recent start date." :
                result.saved == 0 ? "Up to date" : "Imported or updated \(result.saved) meetings."
        } catch is CancellationError {
        } catch {
            if sources.contains(source) { statuses[source.id] = Self.message(error) }
        }
    }

    private func reload() {
        do {
            sources = try store.sources()
            chatAccessEnabled = (try? store.chatAccessEnabled()) == true
            revision += 1
        } catch {
            sources = []
            errorMessage = "Could not load meeting sources."
        }
    }

    private static func message(_ error: any Error) -> String {
        switch error as? MeetingImportError {
        case .invalidEndpoint: "Enter the local HTTP URL from the meeting app."
        case .incompatibleServer: "This server does not expose compatible meeting tools."
        case .signInRequired, .httpStatus(401): "Connect Granola again to sign in."
        case .signInFailed: "Could not sign in to Granola."
        case .paused: "Capture is paused."
        case .excluded: "This source is excluded in Privacy settings."
        case .httpStatus(429): "The provider is limiting requests. Try again later."
        case .invalidResponse, .responseTooLarge, .toolFailed: "The provider could not return the meeting data."
        default: "Could not sync. Check that the meeting app and its MCP server are available."
        }
    }
}

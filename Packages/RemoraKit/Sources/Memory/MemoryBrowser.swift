import Foundation
import Storage

/// A bounded read of the stored wiki for Settings. This inspector does not assemble model
/// context; prompt and tool readers continue to apply their own retrieval policies.
public struct WikiBrowserRequest: Hashable, Sendable {
    public static let pageSize = 100
    public static let maxPages = 500
    public let query: String
    public let type: WikiPageType?
    public let limit: Int

    public init(query: String = "", type: WikiPageType? = nil, limit: Int = pageSize) {
        self.query = query
        self.type = type
        self.limit = min(max(1, limit), Self.maxPages)
    }

    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var emptyMessage: String { isSearching || type != nil ? "No matching pages." : "No pages yet." }

    public func load(_ db: AppDatabase) throws -> WikiBrowserResult {
        let store = WikiStore(db)
        // User searches include short names and acronyms; the context assembler's four-letter
        // minimum would silently discard names such as Ana or AI here.
        let terms = Array(query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.prefix(16))
        let rows: [WikiPage]
        if isSearching {
            // A punctuation-only search is still a search, not a request to list everything.
            rows = terms.isEmpty ? [] : try store.search(terms, type: type, limit: limit + 1).map(\.0)
        } else {
            rows = try store.list(type: type, sort: .recent, limit: limit + 1, offset: 0)
        }
        return WikiBrowserResult(pages: Array(rows.prefix(limit)), hasMore: rows.count > limit)
    }
}

public struct WikiBrowserResult: Sendable {
    public var pages: [WikiPage]
    public var hasMore: Bool
}

/// Publish a complete day's browser result at once, rather than mixing new and old periods
/// when one of the reads fails. Sparse hours overlapping midnight are included.
public struct ChronicleBrowserResult: Sendable {
    public var day: Chronicle?
    public var hours: [Chronicle]
    public var week: Chronicle?
    public var month: Chronicle?

    public static func load(_ db: AppDatabase, date: Date, calendar: Calendar) throws -> Self {
        let store = ChronicleStore(db)
        let interval = PeriodKey.interval(.day, containing: date, calendar: calendar)
        return try Self(
            day: store.chronicle(.day, key: PeriodKey.key(.day, for: date, calendar: calendar)),
            hours: store.list(level: .hour, from: interval.start, to: interval.end),
            week: store.chronicle(.week, key: PeriodKey.key(.week, for: date, calendar: calendar)),
            month: store.chronicle(.month, key: PeriodKey.key(.month, for: date, calendar: calendar)))
    }
}

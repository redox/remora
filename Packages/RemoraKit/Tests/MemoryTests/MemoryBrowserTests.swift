import Foundation
import Storage
import Testing
@testable import Memory

@Suite struct MemoryBrowserTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func page(_ db: AppDatabase, _ title: String, type: WikiPageType = .project, age: TimeInterval = 0) throws {
        try db.writer.write { d in
            _ = try WikiStore.insert(WikiPage(slug: Slug.make(title), type: type, title: title,
                                              firstSeen: now, lastSeen: now.addingTimeInterval(-age), updatedAt: now), in: d)
        }
    }

    @Test func wikiDistinguishesAnEmptyLibraryFromAnEmptySearch() throws {
        let db = try AppDatabase.inMemory()
        let all = WikiBrowserRequest()
        #expect(try all.load(db).pages.isEmpty)
        #expect(all.emptyMessage == "No pages yet.")
        #expect(WikiBrowserRequest(query: "missing").emptyMessage == "No matching pages.")
        #expect(WikiBrowserRequest(type: .person).emptyMessage == "No matching pages.")
    }

    @Test func wikiLoadsMoreWithoutDroppingItsTypeFilter() throws {
        let db = try AppDatabase.inMemory()
        try page(db, "Ana", type: .person)
        try page(db, "Oslo", age: 1)
        try page(db, "Bergen", age: 2)
        let first = try WikiBrowserRequest(type: .project, limit: 1).load(db)
        #expect(first.pages.map(\.title) == ["Oslo"])
        #expect(first.hasMore)
        let more = try WikiBrowserRequest(type: .project, limit: 2).load(db)
        #expect(more.pages.map(\.title) == ["Oslo", "Bergen"])
        #expect(!more.hasMore)
    }

    @Test func wikiSearchWithNoSearchableWordsDoesNotShowEveryPage() throws {
        let db = try AppDatabase.inMemory()
        try page(db, "Oslo")
        try page(db, "Ana", type: .person)
        #expect(try WikiBrowserRequest(query: "?!").load(db).pages.isEmpty)
        #expect(try WikiBrowserRequest(query: "Oslo").load(db).pages.map(\.title) == ["Oslo"])
        #expect(try WikiBrowserRequest(query: "Ana").load(db).pages.map(\.title) == ["Ana"])
    }

    @Test func matchingFactsOnOnePageDoNotHideOtherSearchResults() throws {
        let db = try AppDatabase.inMemory()
        try page(db, "Oslo")
        try page(db, "Bergen", age: 1)
        try page(db, "Ana", type: .person)
        try db.writer.write { d in
            for index in 0..<105 {
                _ = try WikiStore.insert(WikiFact(slug: "oslo", fact: "Harbor", normKey: "harbor-\(index)",
                    subject: .world, basis: .onScreenContent, worth: .core, validAt: now,
                    recordedAt: now, lastConfirmedAt: now), in: d)
            }
            for slug in ["bergen", "ana"] {
                _ = try WikiStore.insert(WikiFact(slug: slug, fact: "Harbor planning for the coming year",
                    normKey: "harbor", subject: .world, basis: .onScreenContent, worth: .core,
                    validAt: now, recordedAt: now, lastConfirmedAt: now), in: d)
            }
        }
        let first = try WikiBrowserRequest(query: "Harbor", type: .project, limit: 1).load(db)
        #expect(first.pages.map(\.title) == ["Oslo"])
        #expect(first.hasMore)
        let more = try WikiBrowserRequest(query: "Harbor", type: .project, limit: 2).load(db)
        #expect(more.pages.map(\.title) == ["Oslo", "Bergen"])
        #expect(!more.hasMore)
    }

    @Test func chronicleBrowserIncludesHoursOverlappingTheSelectedDay() throws {
        let db = try AppDatabase.inMemory()
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: now)
        let store = ChronicleStore(db)
        try db.writer.write { d in
            _ = try store.upsert(Chronicle(level: .hour, periodKey: "overlap", periodStart: day.addingTimeInterval(-3600),
                                           periodEnd: day.addingTimeInterval(3600), summary: "Overlapping hour",
                                           generatedAt: now), in: d)
            _ = try store.upsert(Chronicle(level: .hour, periodKey: "previous", periodStart: day.addingTimeInterval(-7200),
                                           periodEnd: day, summary: "Previous day", generatedAt: now), in: d)
        }
        let result = try ChronicleBrowserResult.load(db, date: now, calendar: calendar)
        #expect(result.hours.map(\.summary) == ["Overlapping hour"])
        #expect(result.day == nil && result.week == nil && result.month == nil)
    }
}

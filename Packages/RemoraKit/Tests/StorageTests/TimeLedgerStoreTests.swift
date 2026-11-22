import Foundation
import GRDB
import Testing
@testable import Storage

private let h14 = Date(timeIntervalSince1970: 1_800_000_000)
private let h15 = h14.addingTimeInterval(3_600)
private let h16 = h15.addingTimeInterval(3_600)

private func allRows(_ db: AppDatabase) throws -> [TimeLedgerRow] {
    try db.reader.read { d in
        try TimeLedgerRow.fetchAll(d, sql: "SELECT * FROM time_ledger ORDER BY hour_start, project, app, domain")
    }
}

private func replace(_ db: AppDatabase, _ hour: Date, _ rows: [TimeLedgerRow]) throws {
    try db.writer.write { d in try TimeLedgerStore(db).replace(hour: hour, rows: rows, in: d) }
}

@Test func replaceSwapsOnlyThatHourAndIsIdempotent() throws {
    let db = try AppDatabase.inMemory()
    let a = [TimeLedgerRow(hourStart: h14, project: "Remora", app: "Xcode", seconds: 1_200),
             TimeLedgerRow(hourStart: h14, project: "Remora", app: "Safari", domain: "github.com", seconds: 600)]
    let other = [TimeLedgerRow(hourStart: h15, project: "Oslo", app: "Mail", seconds: 300)]
    try replace(db, h15, other)
    try replace(db, h14, a)
    try replace(db, h14, a)
    #expect(try allRows(db).count == 3)
    #expect(try allRows(db).filter { $0.hourStart == h14 }.map(\.seconds).reduce(0, +) == 1_800)

    try replace(db, h14, [TimeLedgerRow(hourStart: h14, project: "Unassigned", app: "Notes", seconds: 60)])
    #expect(try allRows(db).map(\.app) == ["Notes", "Mail"])
    try replace(db, h14, [])
    #expect(try allRows(db) == other)
}

@Test func replaceRefusesRowsOfAnotherHour() throws {
    let db = try AppDatabase.inMemory()
    #expect(throws: TimeLedgerStore.HourMismatch.self) {
        try replace(db, h14, [TimeLedgerRow(hourStart: h15, project: "Oslo", app: "Mail", seconds: 300)])
    }
    #expect(try allRows(db).isEmpty)
}

@Test func reportSumsProjectsInRangeMostFirst() throws {
    let db = try AppDatabase.inMemory()
    try replace(db, h14, [TimeLedgerRow(hourStart: h14, project: "Remora", app: "Xcode", seconds: 1_200),
                          TimeLedgerRow(hourStart: h14, project: "Oslo", app: "Mail", seconds: 900)])
    try replace(db, h15, [TimeLedgerRow(hourStart: h15, project: "Oslo", app: "Keynote", seconds: 600)])
    try replace(db, h16, [TimeLedgerRow(hourStart: h16, project: "Remora", app: "Xcode", seconds: 3_000)])

    let report = try TimeLedgerStore(db).report(from: h14, to: h16)
    #expect(report.map(\.project) == ["Oslo", "Remora"])
    #expect(report.map(\.seconds) == [1_500, 1_200])
    #expect(try TimeLedgerStore(db).report(from: h16, to: h16.addingTimeInterval(3_600)).map(\.seconds) == [3_000])
}

@Test func rulesRoundTripInIDOrder() throws {
    let db = try AppDatabase.inMemory()
    let store = TimeLedgerStore(db)
    let first = try store.addRule(TimeRule(project: "Remora", domain: "github.com", createdAt: h14))
    let second = try store.addRule(TimeRule(project: "Oslo", app: "Keynote", titleContains: "deck", createdAt: h15))
    #expect(first.id != nil && second.id != nil)
    #expect(try store.rules().map(\.project) == ["Remora", "Oslo"])
    #expect(try store.rules().last?.titleContains == "deck")

    try store.removeRule(id: try #require(first.id))
    #expect(try store.rules().map(\.project) == ["Oslo"])
}

@Test func rowsListsHoursInRange() throws {
    let db = try AppDatabase.inMemory()
    try replace(db, h14, [TimeLedgerRow(hourStart: h14, project: "Remora", app: "Xcode", seconds: 1_200)])
    try replace(db, h16, [TimeLedgerRow(hourStart: h16, project: "Oslo", app: "Mail", seconds: 300)])
    let rows = try db.reader.read { try TimeLedgerStore(db).rows(from: h14, to: h16, in: $0) }
    #expect(rows == [TimeLedgerRow(hourStart: h14, project: "Remora", app: "Xcode", seconds: 1_200)])
}

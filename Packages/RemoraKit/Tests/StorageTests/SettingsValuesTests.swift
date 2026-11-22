import Foundation
import GRDB
import Testing
@testable import Storage

@Test func settingsValuesRoundTripAndDelete() throws {
    let db = try AppDatabase.inMemory()
    let s = SettingsStore(db)
    #expect(try s.value([String: Int].self, forKey: "k") == nil)
    try s.setValue(["a": 1], forKey: "k")
    #expect(try s.value([String: Int].self, forKey: "k") == ["a": 1])
    try s.setValue("plain", forKey: "str")
    #expect(try s.value(String.self, forKey: "str") == "plain")
    try s.setValue(nil as [String: Int]?, forKey: "k")
    #expect(try s.value([String: Int].self, forKey: "k") == nil)
    try db.writer.write { try $0.execute(sql: "INSERT OR REPLACE INTO settings (key, value) VALUES ('bad', '{')") }
    #expect(throws: SettingsStore.CorruptValue(key: "bad")) {
        try s.value([String: Int].self, forKey: "bad")
    }
}

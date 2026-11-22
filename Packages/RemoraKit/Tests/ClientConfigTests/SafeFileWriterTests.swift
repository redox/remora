import Foundation
import Testing
@testable import ClientConfig

@Suite struct SafeFileWriterTests {
    func backups(of url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".remora-backup-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func writesBackupAndKeepsThree() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("c.json")
        try Data("v0".utf8).write(to: file)
        let w = SafeFileWriter(now: steppingClock())
        var prev = "v0"
        var lastBackup: URL?
        for i in 1...5 {
            let (data, resolved) = try w.read(file)
            lastBackup = try w.write(Data("v\(i)".utf8), to: resolved, expectedOriginal: data)
            #expect(read(lastBackup!) == prev)
            prev = "v\(i)"
        }
        let kept = try backups(of: file)
        #expect(kept.count == 3)
        #expect(kept.map(read) == ["v2", "v3", "v4"])
        #expect(read(file) == "v5")
        #expect(kept.last?.lastPathComponent == lastBackup?.lastPathComponent)
    }

    @Test func backupNameUsesTimestamp() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("c.json")
        try Data("a".utf8).write(to: file)
        let w = SafeFileWriter(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let backup = try w.write(Data("b".utf8), to: w.read(file).resolved, expectedOriginal: Data("a".utf8))
        let name = backup!.lastPathComponent
        #expect(name.range(of: #"^c\.json\.remora-backup-\d{8}-\d{6}$"#, options: .regularExpression) != nil)
    }

    @Test func sameSecondBackupsDoNotOverwrite() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("c.json")
        try Data("a".utf8).write(to: file)
        let w = SafeFileWriter(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        _ = try w.write(Data("b".utf8), to: file.resolvingSymlinksInPath(), expectedOriginal: Data("a".utf8))
        _ = try w.write(Data("c".utf8), to: file.resolvingSymlinksInPath(), expectedOriginal: Data("b".utf8))
        #expect(try backups(of: file).map(read).sorted() == ["a", "b"])
    }

    @Test func refusesWhenChangedOnDisk() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("c.json")
        try Data("old".utf8).write(to: file)
        let w = SafeFileWriter(now: steppingClock())
        let (data, resolved) = try w.read(file)
        try Data("changed by app".utf8).write(to: file)
        #expect(throws: ConfigError.changedOnDisk) { try w.write(Data("new".utf8), to: resolved, expectedOriginal: data) }
        #expect(read(file) == "changed by app")
        #expect(try backups(of: file).isEmpty)
    }

    @Test func refusesWhenCreatedOrDeletedMeanwhile() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("c.json")
        let w = SafeFileWriter(now: steppingClock())
        let (none, resolved) = try w.read(file)
        #expect(none == nil)
        try Data("appeared".utf8).write(to: file)
        #expect(throws: ConfigError.changedOnDisk) { try w.write(Data("new".utf8), to: resolved, expectedOriginal: nil) }
        #expect(read(file) == "appeared")
        try FileManager.default.removeItem(at: file)
        #expect(throws: ConfigError.changedOnDisk) { try w.write(Data("new".utf8), to: resolved, expectedOriginal: Data("appeared".utf8)) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func editsSymlinkTarget() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let dot = home.appendingPathComponent("dotfiles"), cur = home.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: dot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cur, withIntermediateDirectories: true)
        let target = dot.appendingPathComponent("mcp.json"), link = cur.appendingPathComponent("mcp.json")
        try Data("old".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let w = SafeFileWriter(now: steppingClock())
        let (data, resolved) = try w.read(link)
        #expect(resolved.path == target.resolvingSymlinksInPath().path)
        let backup = try w.write(Data("new".utf8), to: resolved, expectedOriginal: data)
        #expect(read(target) == "new")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(backup!.deletingLastPathComponent().resolvingSymlinksInPath().path == dot.resolvingSymlinksInPath().path)
        #expect(try backups(of: link).isEmpty)
    }

    @Test func preservesPermissions() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("c.json")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let w = SafeFileWriter(now: steppingClock())
        let (data, resolved) = try w.read(file)
        let backup = try w.write(Data("new".utf8), to: resolved, expectedOriginal: data)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: backup!.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func newFilePermissionsDependOnDotDirectory() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let dot = home.appendingPathComponent(".cursor"), plain = home.appendingPathComponent("Claude")
        try FileManager.default.createDirectory(at: dot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let w = SafeFileWriter(now: steppingClock())
        let a = dot.appendingPathComponent("mcp.json"), b = plain.appendingPathComponent("c.json")
        let backupA = try w.write(Data("x".utf8), to: a.resolvingSymlinksInPath(), expectedOriginal: nil)
        _ = try w.write(Data("x".utf8), to: b.resolvingSymlinksInPath(), expectedOriginal: nil)
        #expect(backupA == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: b.path)[.posixPermissions] as? Int == 0o644)
    }

    @Test func refusesHugeFile() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("big.json")
        try Data(repeating: 0x20, count: 5 * 1024 * 1024 + 1).write(to: file)
        let w = SafeFileWriter(now: steppingClock())
        #expect(throws: ConfigError.tooLarge) { try w.read(file) }
        try Data(repeating: 0x20, count: 5 * 1024 * 1024).write(to: file)
        #expect((try w.read(file)).data?.count == 5 * 1024 * 1024)
    }

    @Test func leavesNoTempFilesBehind() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("c.json")
        try Data("a".utf8).write(to: file)
        let w = SafeFileWriter(now: steppingClock())
        _ = try w.write(Data("b".utf8), to: file.resolvingSymlinksInPath(), expectedOriginal: Data("a".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: home.path)
        #expect(names.allSatisfy { !$0.contains("remora-tmp") })
    }

    @Test func missingParentDirectoryIsAnError() throws {
        let home = try makeTempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("nope/c.json")
        let w = SafeFileWriter(now: steppingClock())
        #expect(throws: ConfigError.self) { try w.write(Data("x".utf8), to: file, expectedOriginal: nil) }
    }
}

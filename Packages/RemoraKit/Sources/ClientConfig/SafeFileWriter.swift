import Foundation

/// Writes a user's config file without ever clobbering it: symlinks are followed, the file is
/// compared with what the caller read, a backup is kept, and the replacement is atomic.
public struct SafeFileWriter: Sendable {
    public static let maxFileSize = 5 * 1024 * 1024
    /// Reads (status checks) may look at bigger files than we are willing to rewrite.
    public static let maxReadSize = 64 * 1024 * 1024
    public static let backupsKept = 3
    static let backupInfix = ".remora-backup-"

    private let now: @Sendable () -> Date
    private nonisolated(unsafe) let fileManager: FileManager

    public init(now: @escaping @Sendable () -> Date, fileManager: FileManager = .default) {
        self.now = now
        self.fileManager = fileManager
    }

    /// The file's bytes (nil when it doesn't exist) and the symlink-resolved location to write to.
    /// Files over `maxSize` (default 5 MB, the write cap) are `.tooLarge`; status checks pass `maxReadSize`.
    public func read(_ url: URL, maxSize: Int = SafeFileWriter.maxFileSize) throws(ConfigError) -> (data: Data?, resolved: URL) {
        let resolved = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return (nil, resolved) }
        if isDirectory.boolValue { throw ConfigError.io("The settings path is a folder.") }
        if let size = (try? fileManager.attributesOfItem(atPath: resolved.path))?[.size] as? NSNumber,
           size.intValue > maxSize {
            throw ConfigError.tooLarge
        }
        guard let data = fileManager.contents(atPath: resolved.path) else { throw ConfigError.io("The settings file can't be read.") }
        if data.count > maxSize { throw ConfigError.tooLarge }
        return (data, resolved)
    }

    /// Returns the backup's URL (nil when there was no original to back up).
    public func write(_ new: Data, to resolved: URL, expectedOriginal: Data?) throws(ConfigError) -> URL? {
        if new.count > Self.maxFileSize { throw ConfigError.tooLarge }
        let directory = resolved.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigError.io("The settings folder doesn't exist.")
        }
        let current = try read(resolved).data
        guard current == expectedOriginal else { throw ConfigError.changedOnDisk }

        let permissions = existingPermissions(resolved) ?? (directory.lastPathComponent.hasPrefix(".") ? 0o600 : 0o644)

        var backup: URL?
        if let current {
            backup = try writeBackup(current, for: resolved)
        }

        let temp = directory.appendingPathComponent(".\(resolved.lastPathComponent).remora-tmp-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temp.path, contents: new, attributes: [.posixPermissions: permissions]) else {
            if let backup { try? fileManager.removeItem(at: backup) }
            throw ConfigError.io("Couldn't write a temporary file.")
        }
        do {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            // One more look right before swapping: the user's app may have saved in the meantime.
            guard try read(resolved).data == expectedOriginal else { throw ConfigError.changedOnDisk }
            if current != nil {
                _ = try fileManager.replaceItemAt(resolved, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: resolved)
            }
        } catch let error as ConfigError {
            try? fileManager.removeItem(at: temp)
            if let backup { try? fileManager.removeItem(at: backup) }
            throw error
        } catch {
            try? fileManager.removeItem(at: temp)
            if let backup { try? fileManager.removeItem(at: backup) }
            throw ConfigError.io("Couldn't replace the settings file.")
        }
        pruneBackups(of: resolved)
        return backup
    }

    // MARK: -

    private func existingPermissions(_ url: URL) -> Int? {
        guard let value = (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber else { return nil }
        return value.intValue & 0o7777
    }

    private func writeBackup(_ data: Data, for resolved: URL) throws(ConfigError) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = resolved.lastPathComponent + Self.backupInfix + formatter.string(from: now())
        let directory = resolved.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(stem)
        var counter = 1
        while fileManager.fileExists(atPath: candidate.path) {
            counter += 1
            candidate = directory.appendingPathComponent("\(stem)-\(counter)")
        }
        // Backups may hold tokens: owner-only, whatever the original's mode was.
        guard fileManager.createFile(atPath: candidate.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigError.io("Couldn't write a backup.")
        }
        return candidate
    }

    private func pruneBackups(of resolved: URL) {
        let directory = resolved.deletingLastPathComponent()
        let prefix = resolved.lastPathComponent + Self.backupInfix
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        // Newest by modification date (names only break ties): "-10" must not sort before "-2".
        var entries: [(name: String, date: Date)] = []
        for name in names where name.hasPrefix(prefix) {
            let path = directory.appendingPathComponent(name).path
            let date = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            entries.append((name, date ?? Date.distantPast))
        }
        entries.sort { (a, b) -> Bool in
            if a.date != b.date { return a.date < b.date }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.name < b.name
        }
        let backups = entries.map { $0.name }
        for name in backups.dropLast(Self.backupsKept) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

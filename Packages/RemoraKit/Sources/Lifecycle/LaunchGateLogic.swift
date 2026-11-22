import Foundation

/// Whether to register the login item automatically. Only an installed copy registers, so a copy
/// opened from a disk image or Downloads leaves the first-launch flag unset for the installed one.
public enum LoginItemPolicy {
    public static func shouldRegisterOnFirstLaunch(firstLaunchDone: Bool, location: InstallLocation) -> Bool {
        !firstLaunchDone && location.isInstalled
    }

    /// The Settings toggle may always turn the login item off, but only an installed copy may turn it on.
    public static func allowsUserChange(to enabled: Bool, location: InstallLocation) -> Bool {
        !enabled || location.isInstalled
    }
}

public enum DisplayPath {
    /// The path with the home folder shown as `~` (only at a path-component boundary).
    public static func abbreviatingHome(_ path: String, homeDirectory: String) -> String {
        let path = InstallLocation.standardized(path)
        let home = InstallLocation.standardized(homeDirectory)
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// A bundle's `CFBundleShortVersionString` and `CFBundleVersion`.
public struct BundleVersion: Equatable, Comparable, Sendable {
    public var shortVersion: String
    public var build: String

    public init(shortVersion: String, build: String) {
        self.shortVersion = shortVersion
        self.build = build
    }

    /// "0.1.0 (3)", or just the short version when the build is unknown.
    public var display: String { build.isEmpty ? shortVersion : "\(shortVersion) (\(build))" }

    /// By build number (it increases every release), then by short version; both compare numerically.
    public static func < (lhs: BundleVersion, rhs: BundleVersion) -> Bool {
        let builds = lhs.build.compare(rhs.build, options: .numeric)
        if builds != .orderedSame { return builds == .orderedAscending }
        return lhs.shortVersion.compare(rhs.shortVersion, options: .numeric) == .orderedAscending
    }
}

/// What is already at a move destination.
public enum ExistingCopy: Equatable, Sendable {
    case absent, unknownVersion, version(BundleVersion)
}

/// The launch-time decision about moving to Applications.
public enum MoveOffer: Equatable, Sendable {
    /// Installed, a developer build, or the destination is this very bundle (never trash the running app).
    case none
    /// Ask the user; `replacing` is what goes to the Trash.
    case offer(MovePlan, replacing: ExistingCopy)
    /// A newer copy is already installed: keep it and say so instead of downgrading.
    case newerInstalled(BundleVersion)

    /// `destinationIsSource` comes from file identity (symlinks, `/Volumes/<boot disk>/Applications`); the caller
    /// sets it when this bundle is any installed copy. `otherInstalled` is what the other Applications folder holds:
    /// a newer copy there also blocks the move.
    public static func decide(plan: MovePlan?, destinationIsSource: Bool, existing: ExistingCopy,
                              otherInstalled: [ExistingCopy] = [], running: BundleVersion) -> MoveOffer {
        guard let plan, !destinationIsSource else { return .none }
        let newest = ([existing] + otherInstalled).compactMap { copy -> BundleVersion? in
            if case .version(let v) = copy { v } else { nil }
        }.max()
        if let newest, newest > running { return .newerInstalled(newest) }
        return .offer(plan, replacing: existing)
    }

    /// A copy that defers to a newer install quits, so two copies never capture at once.
    public var quitsThisCopy: Bool {
        if case .newerInstalled = self { true } else { false }
    }
}

/// Pinned user-facing copy for the launch gate and the MCP guard.
public enum LaunchCopy {
    public static let moveTitle = "Move Remora to Applications?"
    public static let moveButton = "Move to Applications"
    public static let notNowButton = "Not now"
    public static let moveFailureTitle = "Couldn't move Remora"
    public static let secondInstanceTitle = "Remora is already running"
    public static let newerInstalledTitle = "A newer Remora is already in Applications"
    public static let mcpNotInstalled = "Move Remora to Applications first."
    public static let loginItemNotInstalled = "Move Remora to Applications to open it at login."
    public static let relaunchFailureTitle = "Couldn't reopen Remora"
    public static let relaunchFailureBody = "Remora was moved to your Applications folder. Open it from there."

    public static func moveBody(replacing existing: ExistingCopy) -> String {
        let base = "Remora needs to live in your Applications folder to keep its permissions and update itself."
        switch existing {
        case .absent: return base
        case .unknownVersion: return base + " The copy already there will be moved to the Trash."
        case .version(let v): return base + " The copy already there (version \(v.display)) will be moved to the Trash."
        }
    }

    public static func moveFailureBody(errorDescription: String, previousCopyInTrash: Bool) -> String {
        let trash = previousCopyInTrash ? " The previous copy is in the Trash." : ""
        return "\(errorDescription)\(trash) Drag Remora to your Applications folder, then open it from there."
    }

    public static func secondInstanceBody(otherBundlePath: String?, homeDirectory: String) -> String {
        let tail = "Quit it from its menu-bar icon before opening this one."
        guard let otherBundlePath else { return "Another copy of Remora is open. \(tail)" }
        return "Another copy of Remora is open (\(DisplayPath.abbreviatingHome(otherBundlePath, homeDirectory: homeDirectory))). \(tail)"
    }

    public static func newerInstalledBody(installed: BundleVersion, running: BundleVersion) -> String {
        "Version \(installed.display) is already in your Applications folder, so this copy (\(running.display)) won't replace it. Open Remora from Applications instead. This copy will quit."
    }
}

/// The file operations a move needs, so the sequence can be tested without touching the disk.
public protocol MoveFileOperations {
    func fileExists(atPath path: String) -> Bool
    /// True when both paths are the same file system object (after symlinks).
    func isSameItem(atPath a: String, as b: String) -> Bool
    func createDirectory(atPath path: String) throws
    /// Returns where the item went in the Trash, when known.
    func trashItem(atPath path: String) throws -> String?
    func copyItem(atPath source: String, toPath destination: String) throws
    func removeItem(atPath path: String) throws
    func moveItem(atPath source: String, toPath destination: String) throws
}

/// The copy failed. `previousCopyInTrash` is true when the replaced install could not be put back.
public struct AppMoveError: Error, LocalizedError {
    public var underlying: any Error
    public var previousCopyInTrash: Bool

    public init(underlying: any Error, previousCopyInTrash: Bool) {
        self.underlying = underlying
        self.previousCopyInTrash = previousCopyInTrash
    }

    public var errorDescription: String? { underlying.localizedDescription }
}

public struct MoveResult: Equatable, Sendable {
    /// nil when the plan keeps the source; false when trashing it failed (the move still succeeded).
    public var sourceTrashed: Bool?
    /// The source already is the destination; nothing was done.
    public var alreadyInPlace: Bool

    public init(sourceTrashed: Bool?, alreadyInPlace: Bool = false) {
        self.sourceTrashed = sourceTrashed
        self.alreadyInPlace = alreadyInPlace
    }
}

public enum AppMove {
    /// Creates the destination folder when missing, trashes an existing destination (a failure throws
    /// before anything is copied), copies, then trashes the source when the plan says so (failure reported).
    /// A failed copy throws `AppMoveError` after removing the partial copy and putting the old install back.
    /// Does nothing when the source is the destination, so the running app is never trashed.
    public static func perform(_ plan: MovePlan, sourcePath: String,
                               using fs: some MoveFileOperations) throws -> MoveResult {
        let destination = plan.destination
        if fs.isSameItem(atPath: sourcePath, as: destination) {
            return MoveResult(sourceTrashed: nil, alreadyInPlace: true)
        }
        let folder = (destination as NSString).deletingLastPathComponent
        if !fs.fileExists(atPath: folder) { try fs.createDirectory(atPath: folder) }
        let hadOldCopy = fs.fileExists(atPath: destination)
        let trashedOldCopy = hadOldCopy ? try fs.trashItem(atPath: destination) : nil
        do {
            try fs.copyItem(atPath: sourcePath, toPath: destination)
        } catch {
            // Never leave a partial bundle; put the old install back where it was.
            if fs.fileExists(atPath: destination) { try? fs.removeItem(atPath: destination) }
            var restored = !hadOldCopy
            if hadOldCopy, let trashedOldCopy {
                restored = (try? fs.moveItem(atPath: trashedOldCopy, toPath: destination)) != nil
            }
            throw AppMoveError(underlying: error, previousCopyInTrash: !restored)
        }
        guard plan.trashSource else { return MoveResult(sourceTrashed: nil) }
        do {
            _ = try fs.trashItem(atPath: sourcePath)
            return MoveResult(sourceTrashed: true)
        } catch {
            return MoveResult(sourceTrashed: false)
        }
    }
}

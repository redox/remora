import Foundation

/// Where the running Remora.app lives. Only the two Applications folders count as installed.
public enum InstallLocation: Equatable, Sendable {
    case applications, userApplications, diskImage, translocated, elsewhere

    public var isInstalled: Bool {
        switch self {
        case .applications, .userApplications: true
        case .diskImage, .translocated, .elsewhere: false
        }
    }

    /// Pure classification of a bundle path. The path is standardized first; prefixes compare case-insensitively.
    public static func classify(bundlePath: String, homeDirectory: String) -> InstallLocation {
        let path = standardized(bundlePath)
        if path.range(of: "/AppTranslocation/", options: .caseInsensitive) != nil { return .translocated }
        if hasPrefix(path, "/Volumes/") { return .diskImage }
        if hasPrefix(path, "/Applications/") { return .applications }
        if hasPrefix(path, userApplications(homeDirectory: homeDirectory) + "/") { return .userApplications }
        return .elsewhere
    }

    /// Like `classify`, but a translocated copy whose original (`SecTranslocateCreateOriginalPathForURL`) is in an
    /// Applications folder counts as installed there. `originalPath` is ignored for any other copy.
    public static func resolve(bundlePath: String, originalPath: String?, homeDirectory: String) -> InstallLocation {
        let location = classify(bundlePath: bundlePath, homeDirectory: homeDirectory)
        guard location == .translocated, let originalPath else { return location }
        let original = classify(bundlePath: originalPath, homeDirectory: homeDirectory)
        return original.isInstalled ? original : location
    }

    /// A developer's own build (Xcode's `DerivedData` or a project `build` folder): never offered a move.
    public static func isDeveloperBuild(bundlePath: String) -> Bool {
        (standardized(bundlePath) as NSString).pathComponents.dropLast().contains {
            $0.caseInsensitiveCompare("DerivedData") == .orderedSame || $0.caseInsensitiveCompare("build") == .orderedSame
        }
    }

    static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    static func userApplications(homeDirectory: String) -> String {
        (standardized(homeDirectory) as NSString).appendingPathComponent("Applications")
    }

    private static func hasPrefix(_ path: String, _ prefix: String) -> Bool {
        path.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
    }
}

/// What to do with a copy that is not installed: copy it to `destination`, then trash the source when `trashSource`.
/// Disk images and translocated copies are read-only or ephemeral, so only ordinary folders are trashed.
public struct MovePlan: Equatable, Sendable {
    public static let bundleName = "Remora.app"

    public var destination: String
    public var trashSource: Bool

    public init(destination: String, trashSource: Bool) {
        self.destination = destination
        self.trashSource = trashSource
    }

    /// `/Applications/Remora.app` and `~/Applications/Remora.app`, in that order.
    public static func candidateDestinations(homeDirectory: String) -> [String] {
        ["/Applications", InstallLocation.userApplications(homeDirectory: homeDirectory)]
            .map { ($0 as NSString).appendingPathComponent(bundleName) }
    }

    /// Nil when the copy is already installed (a translocated copy counts through its `originalPath`) or is a
    /// developer build. The destination is always `Remora.app`, even for a renamed bundle.
    /// `installedCopies` are the candidate destinations that already hold Remora: an existing install is replaced in
    /// place (the system one when writable, else the user one) rather than leaving a second copy in the other folder.
    public static func make(bundlePath: String, originalPath: String? = nil, homeDirectory: String,
                            systemApplicationsWritable: Bool, installedCopies: Set<String> = []) -> MovePlan? {
        let location = InstallLocation.resolve(bundlePath: bundlePath, originalPath: originalPath,
                                               homeDirectory: homeDirectory)
        guard !location.isInstalled, !InstallLocation.isDeveloperBuild(bundlePath: bundlePath) else { return nil }
        let candidates = candidateDestinations(homeDirectory: homeDirectory)
        let system = candidates[0], user = candidates[1]
        let destination: String
        if installedCopies.contains(system), systemApplicationsWritable {
            destination = system
        } else if installedCopies.contains(user) {
            destination = user
        } else {
            destination = systemApplicationsWritable ? system : user
        }
        return MovePlan(destination: destination, trashSource: location == .elsewhere)
    }
}

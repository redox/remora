import Darwin
import Foundation
import Lifecycle
import os

/// Copies Remora into Applications and relaunches it from there. The sequence lives in `AppMove`.
enum AppMover {
    private static let logger = Logger(subsystem: "dev.remora", category: "lifecycle")

    /// False when the source already is the destination (nothing done, nothing to relaunch).
    @discardableResult
    static func move(_ plan: MovePlan, from source: URL) throws -> Bool {
        let result = try AppMove.perform(plan, sourcePath: source.resolvingSymlinksInPath().path,
                                         using: FileOperations())
        if result.sourceTrashed == false { logger.error("old copy not moved to the Trash") }
        guard !result.alreadyInPlace else { return false }
        // The copy keeps the download's quarantine; relaunching it would be translocated again (and offered the
        // move again). The user just chose to install it, as with Finder's own move.
        stripQuarantine(at: URL(filePath: plan.destination))
        return true
    }

    /// Removes `com.apple.quarantine` from the bundle and everything in it (symlinks themselves, not their
    /// targets). Logs only a failure count, never paths.
    static func stripQuarantine(at bundle: URL) {
        let name = "com.apple.quarantine"
        var failures = 0
        func strip(_ url: URL) {
            if removexattr(url.path, name, XATTR_NOFOLLOW) != 0, errno != ENOATTR { failures += 1 }
        }
        strip(bundle)
        if let items = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) {
            for case let url as URL in items { strip(url) }
        }
        if failures > 0 { logger.error("quarantine not removed from \(failures, privacy: .public) items") }
    }

    /// Waits for this process to exit, then opens the new copy. Arguments are positional, never interpolated.
    /// If the helper can't start, says where the moved copy is before quitting.
    @MainActor
    static func relaunch(at destination: URL) -> Never {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), destination.path,
        ]
        do { try process.run() } catch {
            logger.error("relaunch failed: \(String(describing: type(of: error)), privacy: .public)")
            LaunchGate.alert(title: LaunchCopy.relaunchFailureTitle, body: LaunchCopy.relaunchFailureBody)
        }
        exit(0)
    }

    /// Reads the version of a bundle at `path`; nil values become empty strings.
    static func version(ofBundleAt url: URL) -> BundleVersion? {
        guard let info = Bundle(url: url)?.infoDictionary else { return nil }
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return short.isEmpty && build.isEmpty ? nil : BundleVersion(shortVersion: short, build: build)
    }

    static func isSameItem(_ a: URL, _ b: URL) -> Bool { FileOperations().isSameItem(atPath: a.path, as: b.path) }
}

private struct FileOperations: MoveFileOperations {
    private var fm: FileManager { .default }

    func fileExists(atPath path: String) -> Bool { fm.fileExists(atPath: path) }

    func isSameItem(atPath a: String, as b: String) -> Bool {
        let ua = URL(filePath: a).resolvingSymlinksInPath(), ub = URL(filePath: b).resolvingSymlinksInPath()
        if ua.standardizedFileURL.path.caseInsensitiveCompare(ub.standardizedFileURL.path) == .orderedSame { return true }
        guard let ia = try? ua.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let ib = try? ub.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return ia.isEqual(ib)
    }

    func createDirectory(atPath path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func trashItem(atPath path: String) throws -> String? {
        var resulting: NSURL?
        try fm.trashItem(at: URL(filePath: path), resultingItemURL: &resulting)
        return resulting?.path
    }

    func removeItem(atPath path: String) throws { try fm.removeItem(atPath: path) }

    func moveItem(atPath source: String, toPath destination: String) throws {
        try fm.moveItem(atPath: source, toPath: destination)
    }

    func copyItem(atPath source: String, toPath destination: String) throws {
        try fm.copyItem(atPath: source, toPath: destination)
    }
}

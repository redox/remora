import AppKit
import Darwin
import Lifecycle
import os

/// Runs first in `RemoraApp.init()`, before the database opens, capture starts or the login item is touched.
@MainActor
enum LaunchGate {
    private static let logger = Logger(subsystem: "dev.remora", category: "lifecycle")

    static func run() {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let home = NSHomeDirectory()
        // A quarantined copy runs from a random read-only mount; its original path decides whether it is installed.
        let original = InstallLocation.classify(bundlePath: bundleURL.path, homeDirectory: home) == .translocated
            ? Translocation.originalPath(of: bundleURL) : nil
        let location = InstallLocation.resolve(bundlePath: bundleURL.path, originalPath: original, homeDirectory: home)
        logger.info("install location: \(String(describing: location), privacy: .public) translocated: \(original != nil, privacy: .public)")
        quitIfAnotherCopyIsRunning(home: home)
        #if !DEBUG
        offerMove(bundleURL: bundleURL, originalPath: original, home: home)
        #endif
    }

    private static func quitIfAnotherCopyIsRunning(home: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.remora.Remora").map {
            RunningCopy(pid: $0.processIdentifier, bundlePath: $0.bundleURL?.path, isTerminated: $0.isTerminated,
                        launchDate: $0.launchDate)
        }
        guard let other = SingleInstance.otherInstance(ownPID: ProcessInfo.processInfo.processIdentifier,
                                                       running: running) else { return }
        logger.notice("second instance")
        NSApplication.shared.setActivationPolicy(.accessory)
        alert(title: LaunchCopy.secondInstanceTitle,
              body: LaunchCopy.secondInstanceBody(otherBundlePath: other.bundlePath, homeDirectory: home))
        exit(0)
    }

    /// A translocated copy whose original is in Applications counts as installed: never offered a move, never trashed.
    private static func offerMove(bundleURL: URL, originalPath: String?, home: String) {
        let fm = FileManager.default
        let candidates = MovePlan.candidateDestinations(homeDirectory: home).map { URL(filePath: $0) }
        let installed = candidates.filter { fm.fileExists(atPath: $0.path) }
        let plan = MovePlan.make(bundlePath: bundleURL.path, originalPath: originalPath, homeDirectory: home,
                                 systemApplicationsWritable: fm.isWritableFile(atPath: "/Applications"),
                                 installedCopies: Set(installed.map(\.path)))
        func copy(at url: URL) -> ExistingCopy {
            guard fm.fileExists(atPath: url.path) else { return .absent }
            return AppMover.version(ofBundleAt: url).map(ExistingCopy.version) ?? .unknownVersion
        }
        let destination = plan.map { URL(filePath: $0.destination) }
        let others = installed.filter { $0.path != destination?.path }.map(copy(at:))
        let running = AppMover.version(ofBundleAt: Bundle.main.bundleURL) ?? BundleVersion(shortVersion: "", build: "")
        // This bundle is one of the installed copies (symlink, alias, /Volumes/<boot>/Applications): never move it.
        let isInstalledCopy = installed.contains { AppMover.isSameItem(bundleURL, $0) }
        let offer = MoveOffer.decide(plan: plan, destinationIsSource: isInstalledCopy,
                                     existing: destination.map(copy(at:)) ?? .absent,
                                     otherInstalled: others, running: running)
        switch offer {
        case .none:
            return
        case .newerInstalled(let installed):
            logger.notice("move skipped: newer copy installed")
            alert(title: LaunchCopy.newerInstalledTitle,
                  body: LaunchCopy.newerInstalledBody(installed: installed, running: running))
            if offer.quitsThisCopy { exit(0) }
        case .offer(let plan, let replacing):
            guard ask(body: LaunchCopy.moveBody(replacing: replacing)) else {
                logger.notice("move declined")
                return
            }
            do {
                guard try AppMover.move(plan, from: bundleURL) else { return }
                logger.notice("moved")
                AppMover.relaunch(at: URL(filePath: plan.destination))
            } catch {
                let inTrash = (error as? AppMoveError)?.previousCopyInTrash ?? false
                let kind = (error as? AppMoveError).map { String(describing: type(of: $0.underlying)) }
                    ?? String(describing: type(of: error))
                logger.error("move failed: \(kind, privacy: .public) old copy in Trash: \(inTrash, privacy: .public)")
                alert(title: LaunchCopy.moveFailureTitle,
                      body: LaunchCopy.moveFailureBody(errorDescription: error.localizedDescription,
                                                       previousCopyInTrash: inTrash))
            }
        }
    }

    private static func ask(body: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = LaunchCopy.moveTitle
        alert.informativeText = body
        alert.addButton(withTitle: LaunchCopy.moveButton)
        alert.addButton(withTitle: LaunchCopy.notNowButton)
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func alert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate()
        alert.runModal()
    }
}

/// Gatekeeper App Translocation. `SecTranslocate*` has no public Swift header, so it is looked up at run time;
/// if it is missing the copy is simply treated as translocated (the move offer, as before).
enum Translocation {
    private typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>,
                                                       UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8
    private typealias CreateOriginal = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?)
        -> Unmanaged<CFURL>?

    /// The path the user opened (e.g. `/Applications/Remora.app`), or nil when `url` isn't translocated.
    static func originalPath(of url: URL) -> String? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD)
                ?? dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSym = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let createSym = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
        else { return nil }
        let isTranslocated = unsafeBitCast(isSym, to: IsTranslocated.self)
        let createOriginal = unsafeBitCast(createSym, to: CreateOriginal.self)
        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil) != 0, translocated,
              let original = createOriginal(url as CFURL, nil)?.takeRetainedValue()
        else { return nil }
        return (original as URL).resolvingSymlinksInPath().path
    }
}

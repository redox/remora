import Foundation
import Testing
@testable import Lifecycle

// MARK: - Login item

@Test func loginItemRegistersOnlyFromAnInstalledCopy() {
    #expect(LoginItemPolicy.shouldRegisterOnFirstLaunch(firstLaunchDone: false, location: .applications))
    #expect(LoginItemPolicy.shouldRegisterOnFirstLaunch(firstLaunchDone: false, location: .userApplications))
    for location in [InstallLocation.diskImage, .translocated, .elsewhere] {
        #expect(!LoginItemPolicy.shouldRegisterOnFirstLaunch(firstLaunchDone: false, location: location))
    }
}

@Test func loginItemIsNeverAutoRegisteredTwice() {
    for location in [InstallLocation.applications, .userApplications, .diskImage, .translocated, .elsewhere] {
        #expect(!LoginItemPolicy.shouldRegisterOnFirstLaunch(firstLaunchDone: true, location: location))
    }
}

// MARK: - Display path

@Test(arguments: [
    ("/Users/me/Applications/Remora.app", "~/Applications/Remora.app"),
    ("/Users/me", "~"),
    ("/Users/me2/Remora.app", "/Users/me2/Remora.app"),
    ("/Applications/Remora.app", "/Applications/Remora.app"),
    ("/Users/me/Downloads/../Desktop/Remora.app", "~/Desktop/Remora.app"),
])
func displayPathShowsHomeAsTilde(path: String, expected: String) {
    #expect(DisplayPath.abbreviatingHome(path, homeDirectory: "/Users/me") == expected)
    #expect(DisplayPath.abbreviatingHome(path, homeDirectory: "/Users/me/") == expected)
}

// MARK: - Pinned copy

@Test func moveAlertMentionsTheTrashOnlyWhenACopyExists() {
    let base = "Remora needs to live in your Applications folder to keep its permissions and update itself."
    #expect(LaunchCopy.moveTitle == "Move Remora to Applications?")
    #expect(LaunchCopy.moveBody(replacing: .absent) == base)
    #expect(LaunchCopy.moveBody(replacing: .unknownVersion)
        == base + " The copy already there will be moved to the Trash.")
    #expect(LaunchCopy.moveButton == "Move to Applications")
    #expect(LaunchCopy.notNowButton == "Not now")
}

@Test func moveFailureCopyIsPinned() {
    #expect(LaunchCopy.moveFailureTitle == "Couldn't move Remora")
    #expect(LaunchCopy.moveFailureBody(errorDescription: "Disk full.", previousCopyInTrash: false)
        == "Disk full. Drag Remora to your Applications folder, then open it from there.")
}

@Test func secondInstanceCopyShowsTheOtherCopyWithHomeAsTilde() {
    #expect(LaunchCopy.secondInstanceTitle == "Remora is already running")
    #expect(LaunchCopy.secondInstanceBody(otherBundlePath: "/Users/me/Applications/Remora.app", homeDirectory: "/Users/me")
        == "Another copy of Remora is open (~/Applications/Remora.app). Quit it from its menu-bar icon before opening this one.")
    #expect(LaunchCopy.secondInstanceBody(otherBundlePath: nil, homeDirectory: "/Users/me")
        == "Another copy of Remora is open. Quit it from its menu-bar icon before opening this one.")
}

@Test func mcpNotInstalledCaptionIsPinned() {
    #expect(LaunchCopy.mcpNotInstalled == "Move Remora to Applications first.")
}

// MARK: - Move execution

/// Records every file operation; never touches the disk.
final class FakeFileOperations: MoveFileOperations, @unchecked Sendable {
    var existing: Set<String>
    var failTrash: Set<String> = []
    var failCopy = false
    var partialCopy = false
    private(set) var log: [String] = []

    init(existing: Set<String>) { self.existing = existing }

    struct Failure: Error {}

    var sameItems: Set<[String]> = []

    func fileExists(atPath path: String) -> Bool { existing.contains(path) }
    func isSameItem(atPath a: String, as b: String) -> Bool { sameItems.contains([a, b]) || sameItems.contains([b, a]) }
    func createDirectory(atPath path: String) throws {
        log.append("mkdir \(path)"); existing.insert(path)
    }
    var failRestore = false
    var trashReturnsNoLocation = false

    func trashItem(atPath path: String) throws -> String? {
        log.append("trash \(path)")
        if failTrash.contains(path) { throw Failure() }
        existing.remove(path)
        if trashReturnsNoLocation { return nil }
        let trashed = "/Trash/" + (path as NSString).lastPathComponent
        existing.insert(trashed)
        return trashed
    }
    func removeItem(atPath path: String) throws {
        log.append("remove \(path)"); existing.remove(path)
    }
    func moveItem(atPath source: String, toPath destination: String) throws {
        log.append("move \(source) -> \(destination)")
        if failRestore { throw Failure() }
        existing.remove(source); existing.insert(destination)
    }
    func copyItem(atPath source: String, toPath destination: String) throws {
        log.append("copy \(source) -> \(destination)")
        if failCopy {
            if partialCopy { existing.insert(destination) }
            throw Failure()
        }
        existing.insert(destination)
    }
}

@Test func moveCopiesIntoAnExistingFolderAndKeepsADiskImageSource() throws {
    let fs = FakeFileOperations(existing: ["/Applications", "/Volumes/Remora/Remora.app"])
    let plan = MovePlan(destination: "/Applications/Remora.app", trashSource: false)
    let result = try AppMove.perform(plan, sourcePath: "/Volumes/Remora/Remora.app", using: fs)
    #expect(fs.log == ["copy /Volumes/Remora/Remora.app -> /Applications/Remora.app"])
    #expect(result == MoveResult(sourceTrashed: nil))
}

@Test func moveIntoItselfDoesNothing() throws {
    // e.g. /Volumes/<boot disk>/Applications/Remora.app is /Applications/Remora.app.
    let source = "/Volumes/Macintosh HD/Applications/Remora.app"
    let fs = FakeFileOperations(existing: ["/Applications", "/Applications/Remora.app", source])
    fs.sameItems = [[source, "/Applications/Remora.app"]]
    let plan = MovePlan(destination: "/Applications/Remora.app", trashSource: false)
    let result = try AppMove.perform(plan, sourcePath: source, using: fs)
    #expect(fs.log.isEmpty)
    #expect(result == MoveResult(sourceTrashed: nil, alreadyInPlace: true))
}

@Test func moveCreatesUserApplicationsWhenMissing() throws {
    let fs = FakeFileOperations(existing: ["/Users/me/Downloads/Remora.app"])
    let plan = MovePlan(destination: "/Users/me/Applications/Remora.app", trashSource: true)
    _ = try AppMove.perform(plan, sourcePath: "/Users/me/Downloads/Remora.app", using: fs)
    #expect(fs.log.first == "mkdir /Users/me/Applications")
}

@Test func moveTrashesAnExistingDestinationBeforeCopying() throws {
    let fs = FakeFileOperations(existing: ["/Applications", "/Applications/Remora.app", "/Users/me/Downloads/Remora.app"])
    let plan = MovePlan(destination: "/Applications/Remora.app", trashSource: true)
    let result = try AppMove.perform(plan, sourcePath: "/Users/me/Downloads/Remora.app", using: fs)
    #expect(fs.log == [
        "trash /Applications/Remora.app",
        "copy /Users/me/Downloads/Remora.app -> /Applications/Remora.app",
        "trash /Users/me/Downloads/Remora.app",
    ])
    #expect(result == MoveResult(sourceTrashed: true))
}

@Test func failingToTrashTheOldCopyThrowsAndCopiesNothing() {
    let fs = FakeFileOperations(existing: ["/Applications", "/Applications/Remora.app"])
    fs.failTrash = ["/Applications/Remora.app"]
    let plan = MovePlan(destination: "/Applications/Remora.app", trashSource: true)
    #expect(throws: FakeFileOperations.Failure.self) {
        try AppMove.perform(plan, sourcePath: "/Users/me/Downloads/Remora.app", using: fs)
    }
    #expect(fs.log == ["trash /Applications/Remora.app"])
}

@Test func failingToCopyThrowsAndKeepsTheSource() {
    let fs = FakeFileOperations(existing: ["/Applications"])
    fs.failCopy = true
    let plan = MovePlan(destination: "/Applications/Remora.app", trashSource: true)
    #expect(throws: AppMoveError.self) {
        try AppMove.perform(plan, sourcePath: "/Users/me/Downloads/Remora.app", using: fs)
    }
    #expect(!fs.log.contains("trash /Users/me/Downloads/Remora.app"))
}

@Test func failingToTrashTheSourceIsReportedNotThrown() throws {
    let fs = FakeFileOperations(existing: ["/Applications"])
    fs.failTrash = ["/Users/me/Downloads/Remora.app"]
    let plan = MovePlan(destination: "/Applications/Remora.app", trashSource: true)
    let result = try AppMove.perform(plan, sourcePath: "/Users/me/Downloads/Remora.app", using: fs)
    #expect(result == MoveResult(sourceTrashed: false))
    #expect(fs.existing.contains("/Applications/Remora.app"))
}

// MARK: - Developer builds and same-bundle guard

@Test(arguments: [
    "/Users/me/dev/remora/build/Build/Products/Release/Remora.app",
    "/Users/me/Library/Developer/Xcode/DerivedData/Remora-abc/Build/Products/Release/Remora.app",
    "/Users/me/dev/remora/Build/Products/Release/Remora.app",
])
func developerBuildsAreNeverOfferedAMove(path: String) {
    #expect(InstallLocation.isDeveloperBuild(bundlePath: path))
    #expect(MovePlan.make(bundlePath: path, homeDirectory: "/Users/me", systemApplicationsWritable: true) == nil)
}

@Test func ordinaryFoldersAreNotDeveloperBuilds() {
    #expect(!InstallLocation.isDeveloperBuild(bundlePath: "/Users/me/Downloads/Remora.app"))
    #expect(!InstallLocation.isDeveloperBuild(bundlePath: "/Users/me/builds-old/Remora.app"))
    #expect(!InstallLocation.isDeveloperBuild(bundlePath: "/Volumes/Remora/Remora.app"))
}

// MARK: - Move offer (same bundle, versions)

private let running = BundleVersion(shortVersion: "0.2.0", build: "5")
private let plan = MovePlan(destination: "/Applications/Remora.app", trashSource: false)

@Test func sameBundleAtDestinationIsNeverOffered() {
    // A symlinked or /Volumes/<boot>/Applications path to the installed copy: never trash it.
    #expect(MoveOffer.decide(plan: plan, destinationIsSource: true, existing: .version(running), running: running) == .none)
    #expect(MoveOffer.decide(plan: plan, destinationIsSource: true, existing: .absent, running: running) == .none)
}

@Test func noPlanMeansNoOffer() {
    #expect(MoveOffer.decide(plan: nil, destinationIsSource: false, existing: .absent, running: running) == .none)
}

@Test func emptyDestinationIsOfferedWithoutAVersion() {
    #expect(MoveOffer.decide(plan: plan, destinationIsSource: false, existing: .absent, running: running)
        == .offer(plan, replacing: .absent))
    #expect(MoveOffer.decide(plan: plan, destinationIsSource: false, existing: .unknownVersion, running: running)
        == .offer(plan, replacing: .unknownVersion))
}

@Test func olderOrEqualCopyIsReplacedAndNamed() {
    let older = BundleVersion(shortVersion: "0.1.0", build: "4")
    #expect(MoveOffer.decide(plan: plan, destinationIsSource: false, existing: .version(older), running: running)
        == .offer(plan, replacing: .version(older)))
    #expect(MoveOffer.decide(plan: plan, destinationIsSource: false, existing: .version(running), running: running)
        == .offer(plan, replacing: .version(running)))
}

@Test func newerCopyIsNeverDowngraded() {
    let newer = BundleVersion(shortVersion: "0.10.0", build: "10")
    #expect(MoveOffer.decide(plan: plan, destinationIsSource: false, existing: .version(newer), running: running)
        == .newerInstalled(newer))
}

@Test func buildsCompareNumerically() {
    #expect(BundleVersion(shortVersion: "1.0", build: "10") > BundleVersion(shortVersion: "1.0", build: "9"))
    #expect(!(BundleVersion(shortVersion: "1.0", build: "9") > BundleVersion(shortVersion: "1.0", build: "9")))
    #expect(BundleVersion(shortVersion: "0.10.0", build: "") > BundleVersion(shortVersion: "0.9.0", build: ""))
}

@Test func versionDisplaysAsShortAndBuild() {
    #expect(BundleVersion(shortVersion: "0.1.0", build: "3").display == "0.1.0 (3)")
    #expect(BundleVersion(shortVersion: "0.1.0", build: "").display == "0.1.0")
}

@Test func moveAlertNamesTheReplacedVersion() {
    #expect(LaunchCopy.moveBody(replacing: .version(BundleVersion(shortVersion: "0.1.0", build: "3")))
        == "Remora needs to live in your Applications folder to keep its permissions and update itself."
        + " The copy already there (version 0.1.0 (3)) will be moved to the Trash.")
}

@Test func newerInstalledCopyIsPinned() {
    #expect(LaunchCopy.newerInstalledTitle == "A newer Remora is already in Applications")
    #expect(LaunchCopy.newerInstalledBody(installed: BundleVersion(shortVersion: "0.3.0", build: "7"),
                                          running: BundleVersion(shortVersion: "0.2.0", build: "5"))
        == "Version 0.3.0 (7) is already in your Applications folder, so this copy (0.2.0 (5)) won't replace it. Open Remora from Applications instead. This copy will quit.")
}

// MARK: - Fix round 1

// I1: an existing ~/Applications install is the target, not a second copy in /Applications.
@Test func existingUserApplicationsInstallIsTheTarget() {
    let plan = MovePlan.make(bundlePath: "/Volumes/Remora/Remora.app", homeDirectory: "/Users/me",
                             systemApplicationsWritable: true,
                             installedCopies: ["/Users/me/Applications/Remora.app"])
    #expect(plan?.destination == "/Users/me/Applications/Remora.app")
}

@Test func existingSystemInstallWinsWhenWritable() {
    let both: Set<String> = ["/Applications/Remora.app", "/Users/me/Applications/Remora.app"]
    let plan = MovePlan.make(bundlePath: "/Volumes/Remora/Remora.app", homeDirectory: "/Users/me",
                             systemApplicationsWritable: true, installedCopies: both)
    #expect(plan?.destination == "/Applications/Remora.app")
    let readOnly = MovePlan.make(bundlePath: "/Volumes/Remora/Remora.app", homeDirectory: "/Users/me",
                                 systemApplicationsWritable: false, installedCopies: both)
    #expect(readOnly?.destination == "/Users/me/Applications/Remora.app")
}

@Test func noExistingInstallKeepsTheDefaultTarget() {
    #expect(MovePlan.make(bundlePath: "/Volumes/Remora/Remora.app", homeDirectory: "/Users/me",
                          systemApplicationsWritable: true, installedCopies: [])?.destination
        == "/Applications/Remora.app")
}

@Test func candidateInstallPathsCoverBothFolders() {
    #expect(MovePlan.candidateDestinations(homeDirectory: "/Users/me/")
        == ["/Applications/Remora.app", "/Users/me/Applications/Remora.app"])
}

@Test func newerCopyInTheOtherApplicationsFolderAlsoBlocksTheMove() {
    let newer = BundleVersion(shortVersion: "0.3.0", build: "7")
    #expect(MoveOffer.decide(plan: plan, destinationIsSource: false, existing: .absent,
                             otherInstalled: [.version(newer)], running: running) == .newerInstalled(newer))
    let older = BundleVersion(shortVersion: "0.1.0", build: "1")
    #expect(MoveOffer.decide(plan: plan, destinationIsSource: false, existing: .absent,
                             otherInstalled: [.version(older), .unknownVersion], running: running)
        == .offer(plan, replacing: .absent))
}

// I2: a failed copy restores the old install from the Trash.
@Test func failedCopyRestoresThePreviousCopy() {
    let fs = FakeFileOperations(existing: ["/Applications", "/Applications/Remora.app"])
    fs.failCopy = true
    fs.partialCopy = true
    let plan = MovePlan(destination: "/Applications/Remora.app", trashSource: true)
    #expect {
        try AppMove.perform(plan, sourcePath: "/Users/me/Downloads/Remora.app", using: fs)
    } throws: { ($0 as? AppMoveError)?.previousCopyInTrash == false }
    #expect(fs.log == [
        "trash /Applications/Remora.app",
        "copy /Users/me/Downloads/Remora.app -> /Applications/Remora.app",
        "remove /Applications/Remora.app",
        "move /Trash/Remora.app -> /Applications/Remora.app",
    ])
    #expect(fs.existing.contains("/Applications/Remora.app"))
    #expect(!fs.existing.contains("/Trash/Remora.app"))
}

@Test func failedRestoreReportsThePreviousCopyInTheTrash() {
    let fs = FakeFileOperations(existing: ["/Applications", "/Applications/Remora.app"])
    fs.failCopy = true
    fs.failRestore = true
    let plan = MovePlan(destination: "/Applications/Remora.app", trashSource: true)
    #expect {
        try AppMove.perform(plan, sourcePath: "/Users/me/Downloads/Remora.app", using: fs)
    } throws: { ($0 as? AppMoveError)?.previousCopyInTrash == true }
}

@Test func unknownTrashLocationReportsThePreviousCopyInTheTrash() {
    let fs = FakeFileOperations(existing: ["/Applications", "/Applications/Remora.app"])
    fs.failCopy = true
    fs.trashReturnsNoLocation = true
    let plan = MovePlan(destination: "/Applications/Remora.app", trashSource: true)
    #expect {
        try AppMove.perform(plan, sourcePath: "/Users/me/Downloads/Remora.app", using: fs)
    } throws: { ($0 as? AppMoveError)?.previousCopyInTrash == true }
}

@Test func failedCopyWithNoPreviousCopyReportsNothingInTheTrash() {
    let fs = FakeFileOperations(existing: ["/Applications"])
    fs.failCopy = true
    let plan = MovePlan(destination: "/Applications/Remora.app", trashSource: true)
    #expect {
        try AppMove.perform(plan, sourcePath: "/Users/me/Downloads/Remora.app", using: fs)
    } throws: { ($0 as? AppMoveError)?.previousCopyInTrash == false }
}

@Test func moveFailureCopyMentionsTheTrashOnlyWhenTheOldCopyIsThere() {
    let tail = " Drag Remora to your Applications folder, then open it from there."
    #expect(LaunchCopy.moveFailureBody(errorDescription: "Disk full.", previousCopyInTrash: false)
        == "Disk full." + tail)
    #expect(LaunchCopy.moveFailureBody(errorDescription: "Disk full.", previousCopyInTrash: true)
        == "Disk full. The previous copy is in the Trash." + tail)
}

// M1: a failed relaunch says where the moved copy is.
@Test func relaunchFailureCopyIsPinned() {
    #expect(LaunchCopy.relaunchFailureTitle == "Couldn't reopen Remora")
    #expect(LaunchCopy.relaunchFailureBody
        == "Remora was moved to your Applications folder. Open it from there.")
}

// M2: the manual toggle can only turn the login item on from an installed copy.
@Test func manualLoginToggleTurnsOnOnlyWhenInstalled() {
    #expect(LoginItemPolicy.allowsUserChange(to: true, location: .applications))
    #expect(LoginItemPolicy.allowsUserChange(to: true, location: .userApplications))
    for location in [InstallLocation.diskImage, .translocated, .elsewhere] {
        #expect(!LoginItemPolicy.allowsUserChange(to: true, location: location))
        #expect(LoginItemPolicy.allowsUserChange(to: false, location: location))
    }
    #expect(LaunchCopy.loginItemNotInstalled == "Move Remora to Applications to open it at login.")
}

// M4: a copy that defers to a newer install quits instead of running a second capture.
@Test func onlyANewerInstallQuitsThisCopy() {
    #expect(MoveOffer.newerInstalled(running).quitsThisCopy)
    #expect(!MoveOffer.none.quitsThisCopy)
    #expect(!MoveOffer.offer(plan, replacing: .absent).quitsThisCopy)
    #expect(LaunchCopy.newerInstalledBody(installed: BundleVersion(shortVersion: "0.3.0", build: "7"),
                                          running: BundleVersion(shortVersion: "0.2.0", build: "5")).hasSuffix("This copy will quit."))
}

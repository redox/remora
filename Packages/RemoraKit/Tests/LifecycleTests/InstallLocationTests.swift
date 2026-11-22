import Testing
@testable import Lifecycle

@Test(arguments: [
    ("/Applications/Remora.app", InstallLocation.applications),
    ("/Applications/Utilities/Remora.app", .applications),
    ("/applications/Remora.app", .applications),
    ("/Users/me/Applications/Remora.app", .userApplications),
    ("/users/me/applications/Remora.app", .userApplications),
    ("/Volumes/Remora/Remora.app", .diskImage),
    ("/private/var/folders/ab/T/AppTranslocation/0A1B/d/Remora.app", .translocated),
    ("/Users/me/Downloads/Remora.app", .elsewhere),
    ("/Applicationsfoo/Remora.app", .elsewhere),
    ("/Users/me/Applicationsfoo/Remora.app", .elsewhere),
    ("/Users/me/Downloads/../../../Applications/Remora.app", .applications),
])
func classifiesInstallLocations(path: String, expected: InstallLocation) {
    #expect(InstallLocation.classify(bundlePath: path, homeDirectory: "/Users/me") == expected)
}

@Test func onlyApplicationsFoldersCountAsInstalled() {
    #expect(InstallLocation.applications.isInstalled)
    #expect(InstallLocation.userApplications.isInstalled)
    #expect(!InstallLocation.diskImage.isInstalled)
    #expect(!InstallLocation.translocated.isInstalled)
    #expect(!InstallLocation.elsewhere.isInstalled)
}

@Test func installedCopiesNeedNoMove() {
    for writable in [true, false] {
        #expect(MovePlan.make(bundlePath: "/Applications/Remora.app", homeDirectory: "/Users/me",
                              systemApplicationsWritable: writable) == nil)
        #expect(MovePlan.make(bundlePath: "/Users/me/Applications/Remora.app", homeDirectory: "/Users/me",
                              systemApplicationsWritable: writable) == nil)
    }
}

@Test func movesToSystemApplicationsWhenWritable() {
    let plan = MovePlan.make(bundlePath: "/Users/me/Downloads/Remora.app", homeDirectory: "/Users/me",
                             systemApplicationsWritable: true)
    #expect(plan == MovePlan(destination: "/Applications/Remora.app", trashSource: true))
}

@Test func fallsBackToUserApplications() {
    let plan = MovePlan.make(bundlePath: "/Volumes/Remora/Remora.app", homeDirectory: "/Users/me",
                             systemApplicationsWritable: false)
    #expect(plan == MovePlan(destination: "/Users/me/Applications/Remora.app", trashSource: false))
}

@Test func userApplicationsDestinationToleratesTrailingSlashInHome() {
    let plan = MovePlan.make(bundlePath: "/Users/me/Downloads/Remora.app", homeDirectory: "/Users/me/",
                             systemApplicationsWritable: false)
    #expect(plan?.destination == "/Users/me/Applications/Remora.app")
}

@Test func trashesSourceOnlyFromOrdinaryFolders() {
    func trash(_ path: String) -> Bool? {
        MovePlan.make(bundlePath: path, homeDirectory: "/Users/me", systemApplicationsWritable: true)?.trashSource
    }
    #expect(trash("/Volumes/Remora/Remora.app") == false)
    #expect(trash("/private/var/folders/ab/T/AppTranslocation/0A1B/d/Remora.app") == false)
    #expect(trash("/Users/me/Downloads/Remora.app") == true)
}

@Test func destinationIsAlwaysRemoraApp() {
    let plan = MovePlan.make(bundlePath: "/Users/me/Downloads/Remora 2.app", homeDirectory: "/Users/me",
                             systemApplicationsWritable: true)
    #expect(plan?.destination == "/Applications/Remora.app")
    let user = MovePlan.make(bundlePath: "/Users/me/Downloads/Remora 2.app", homeDirectory: "/Users/me",
                             systemApplicationsWritable: false)
    #expect(user?.destination == "/Users/me/Applications/Remora.app")
}

// MARK: - Translocation

/// macOS translocates a quarantined app even inside Applications; the original path decides.
@Test(arguments: [
    ("/Applications/Remora.app", InstallLocation.applications),
    ("/Users/me/Applications/Remora.app", .userApplications),
    ("/Users/me/Downloads/Remora.app", .translocated),
    ("/Volumes/Remora/Remora.app", .translocated),
])
func translocatedCopyResolvesThroughItsOriginal(original: String, expected: InstallLocation) {
    let translocated = "/private/var/folders/ab/T/AppTranslocation/0A1B/d/Remora.app"
    #expect(InstallLocation.resolve(bundlePath: translocated, originalPath: original, homeDirectory: "/Users/me")
        == expected)
}

@Test func originalPathOnlyMattersWhenTranslocated() {
    let home = "/Users/me"
    #expect(InstallLocation.resolve(bundlePath: "/private/var/folders/ab/T/AppTranslocation/0A1B/d/Remora.app",
                                    originalPath: nil, homeDirectory: home) == .translocated)
    #expect(InstallLocation.resolve(bundlePath: "/Users/me/Downloads/Remora.app",
                                    originalPath: "/Applications/Remora.app", homeDirectory: home) == .elsewhere)
}

@Test func translocatedCopyFromApplicationsIsNeverMoved() {
    let translocated = "/private/var/folders/ab/T/AppTranslocation/0A1B/d/Remora.app"
    for original in ["/Applications/Remora.app", "/Users/me/Applications/Remora.app"] {
        #expect(MovePlan.make(bundlePath: translocated, originalPath: original, homeDirectory: "/Users/me",
                              systemApplicationsWritable: true,
                              installedCopies: ["/Applications/Remora.app"]) == nil)
    }
}

@Test func translocatedCopyFromElsewhereIsOfferedTheMove() {
    let translocated = "/private/var/folders/ab/T/AppTranslocation/0A1B/d/Remora.app"
    #expect(MovePlan.make(bundlePath: translocated, originalPath: "/Users/me/Downloads/Remora.app",
                          homeDirectory: "/Users/me", systemApplicationsWritable: true)
        == MovePlan(destination: "/Applications/Remora.app", trashSource: false))
    #expect(MovePlan.make(bundlePath: translocated, originalPath: nil, homeDirectory: "/Users/me",
                          systemApplicationsWritable: false)
        == MovePlan(destination: "/Users/me/Applications/Remora.app", trashSource: false))
}

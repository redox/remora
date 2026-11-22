import Foundation
import Testing
@testable import Lifecycle

@Test func settingsCopyIsPinned() {
    #expect(UpdateCopy.versionLine(short: "0.1.0", build: "1") == "Version 0.1.0 (1)")
    #expect(UpdateCopy.automaticToggle == "Install updates automatically")
    #expect(UpdateCopy.checkForUpdates == "Check for Updates…")
    #expect(UpdateCopy.caption == "Remora checks GitHub for a new version about once an hour, downloads it, and installs it when you're away from the keyboard, then restarts.")
    #expect(UpdateCopy.restartToUpdate(version: "0.2.0") == "Restart to Update to Remora 0.2.0")
}

@Test func disabledCaptionExplainsWhy() {
    #expect(UpdateCopy.disabledCaption(.debugBuild) == "Updates are off in development builds.")
    for reason in [UpdatesDisabledReason.missingFeed, .invalidFeed, .missingKey, .invalidKey] {
        #expect(UpdateCopy.disabledCaption(reason) == "Updates aren't set up in this build.")
    }
}

@Test func menuHidesCheckWhileUpdatesAreOff() {
    #expect(UpdateMenuItem.make(phase: .disabled(.debugBuild), canCheck: true) == nil)
    #expect(UpdateMenuItem.make(phase: .disabled(.invalidFeed), canCheck: true) == nil)
}

@Test func menuOffersCheckWhenIdleOrAnUpdateWaits() {
    #expect(UpdateMenuItem.make(phase: .idle, canCheck: true)
        == UpdateMenuItem(title: "Check for Updates…", action: .check, enabled: true))
    #expect(UpdateMenuItem.make(phase: .idle, canCheck: false)
        == UpdateMenuItem(title: "Check for Updates…", action: .check, enabled: false))
}

/// Sparkle may report `canCheckForUpdates` false while a reminder holds the update; the item must still open it.
@Test func menuOpensAWaitingUpdateEvenWhileACheckIsHeld() {
    #expect(UpdateMenuItem.make(phase: .updateAvailable(version: "0.2.0"), canCheck: false)
        == UpdateMenuItem(title: "Check for Updates…", action: .check, enabled: true))
}

@Test func menuOffersRestartWhenAnUpdateIsReady() {
    #expect(UpdateMenuItem.make(phase: .readyToInstall(version: "0.2.0"), canCheck: false)
        == UpdateMenuItem(title: "Restart to Update to Remora 0.2.0", action: .installNow, enabled: true))
}

@Test func pendingInstallWaitsForIdleOrADay() {
    let ready = Date(timeIntervalSince1970: 1_000_000)
    let pending = PendingInstall(readySince: ready)
    #expect(!pending.shouldInstall(now: ready.addingTimeInterval(60), busy: false, idleSeconds: 30))
    #expect(pending.shouldInstall(now: ready.addingTimeInterval(60), busy: false, idleSeconds: 120))
    #expect(!pending.shouldInstall(now: ready.addingTimeInterval(60), busy: true, idleSeconds: 600))
    #expect(pending.shouldInstall(now: ready.addingTimeInterval(86_400), busy: false, idleSeconds: 0))
    #expect(!pending.shouldInstall(now: ready.addingTimeInterval(86_400), busy: true, idleSeconds: 0))
}

@Test func pendingInstallIgnoresAClockThatWentBackwards() {
    let ready = Date(timeIntervalSince1970: 1_000_000)
    #expect(!PendingInstall(readySince: ready).shouldInstall(now: ready.addingTimeInterval(-90_000), busy: false,
                                                             idleSeconds: 0))
}

@Test func notInstalledCaptionPointsToApplications() {
    #expect(UpdateCopy.disabledCaption(.notInstalled) == "Updates work once Remora is in Applications.")
}

/// "Restart to Update" would quit mid-dictation or mid-rewrite: it waits until Remora is idle.
@Test func restartToUpdateIsDisabledWhileBusy() {
    #expect(UpdateMenuItem.make(phase: .readyToInstall(version: "0.2.0"), canCheck: true, busy: true)
        == UpdateMenuItem(title: "Restart to Update to Remora 0.2.0", action: .installNow, enabled: false))
    #expect(UpdateMenuItem.make(phase: .idle, canCheck: true, busy: true)
        == UpdateMenuItem(title: "Check for Updates…", action: .check, enabled: true))
}

@Test func aNewerUpdateKeepsTheEarliestReadyTime() {
    let first = Date(timeIntervalSince1970: 1_000_000)
    let later = first.addingTimeInterval(3_600)
    #expect(PendingInstall.next(after: nil, now: later) == PendingInstall(readySince: later))
    #expect(PendingInstall.next(after: PendingInstall(readySince: first), now: later) == PendingInstall(readySince: first))
}

import Foundation
import Testing
@testable import Lifecycle

@Test func secondInstanceIsDetected() {
    let t = Date(timeIntervalSince1970: 1_000_000)
    let running = [RunningCopy(pid: 10, bundlePath: "/Applications/Remora.app", isTerminated: false,
                               launchDate: t.addingTimeInterval(60)),
                   RunningCopy(pid: 11, bundlePath: "/Users/me/Downloads/Remora.app", isTerminated: false,
                               launchDate: t)]
    #expect(SingleInstance.otherInstance(ownPID: 10, running: running)?.pid == 11)
}

@Test func ownAndTerminatedProcessesAreIgnored() {
    let running = [RunningCopy(pid: 10, bundlePath: "/Applications/Remora.app", isTerminated: false),
                   RunningCopy(pid: 12, bundlePath: nil, isTerminated: true)]
    #expect(SingleInstance.otherInstance(ownPID: 10, running: running) == nil)
}

@Test func withoutItsOwnEntryAnyOtherCopyWins() {
    let running = [RunningCopy(pid: 11, bundlePath: nil, isTerminated: false)]
    #expect(SingleInstance.otherInstance(ownPID: 10, running: running)?.pid == 11)
}

@Test func noOtherCopiesMeansNoOtherInstance() {
    #expect(SingleInstance.otherInstance(ownPID: 10, running: []) == nil)
}

/// Two copies launched together each see the other: only the later one (then the higher PID) quits.
@Test func simultaneousLaunchesKeepTheEarliestCopy() {
    let t = Date(timeIntervalSince1970: 1_000_000)
    let running = [RunningCopy(pid: 20, bundlePath: "/Applications/Remora.app", isTerminated: false, launchDate: t),
                   RunningCopy(pid: 21, bundlePath: "/Users/me/Downloads/Remora.app", isTerminated: false,
                               launchDate: t.addingTimeInterval(0.1))]
    #expect(SingleInstance.otherInstance(ownPID: 20, running: running) == nil)
    #expect(SingleInstance.otherInstance(ownPID: 21, running: running)?.pid == 20)
}

@Test func equalLaunchDatesKeepTheLowestPID() {
    let t = Date(timeIntervalSince1970: 1_000_000)
    let running = [RunningCopy(pid: 31, bundlePath: nil, isTerminated: false, launchDate: t),
                   RunningCopy(pid: 30, bundlePath: nil, isTerminated: false, launchDate: t)]
    #expect(SingleInstance.otherInstance(ownPID: 30, running: running) == nil)
    #expect(SingleInstance.otherInstance(ownPID: 31, running: running)?.pid == 30)
}

/// A copy with no known launch date counts as the older one, so this copy never fights an existing one.
@Test func unknownLaunchDateCountsAsEarlier() {
    let t = Date(timeIntervalSince1970: 1_000_000)
    let running = [RunningCopy(pid: 40, bundlePath: nil, isTerminated: false, launchDate: t),
                   RunningCopy(pid: 41, bundlePath: nil, isTerminated: false, launchDate: nil)]
    #expect(SingleInstance.otherInstance(ownPID: 40, running: running)?.pid == 41)
}

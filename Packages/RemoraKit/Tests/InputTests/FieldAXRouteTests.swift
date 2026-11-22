import Foundation
import Testing
@testable import Input

/// Remora's own practice field is reached through Accessibility in-process: AppKit then runs the
/// text update on the calling thread, so it must be the main thread (crash 2026-11-21: the
/// practice rewrite wrote the result from the AX queue and AppKit trapped).
struct FieldAXRouteTests {
    @Test func ownFieldRunsOnTheMainThread() {
        #expect(FieldAXRoute.route(fieldPID: 42, ownPID: 42) == .mainThread)
    }

    @Test func otherAppsUseTheAXQueue() {
        #expect(FieldAXRoute.route(fieldPID: 7, ownPID: 42) == .axQueue)
    }

    @Test func mainThreadRouteRunsOnMainFromABackgroundThread() async {
        let ranOnMain = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                c.resume(returning: MainThreadRunner.sync { Thread.isMainThread })
            }
        }
        #expect(ranOnMain)
    }

    @Test @MainActor func mainThreadRouteRunsInlineOnMain() {
        #expect(MainThreadRunner.sync { Thread.isMainThread })
    }
}

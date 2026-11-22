import AppKit
import Lifecycle
import Observation
import SwiftUI

/// The onboarding step machine plus the live facts it is driven by. `refresh()` re-reads the facts
/// (the 2 s permissions tick, account changes) and lets the flow move past a step that no longer applies,
/// or back to Accessibility when it is lost.
@MainActor @Observable
final class OnboardingModel {
    private(set) var flow = OnboardingFlow()
    private(set) var facts: OnboardingFacts
    @ObservationIgnored private let readFacts: @MainActor () -> OnboardingFacts

    init(facts: @escaping @MainActor () -> OnboardingFacts) {
        readFacts = facts
        self.facts = facts()
    }

    func refresh() {
        let current = readFacts()
        if current != facts { facts = current }
        var updated = flow
        updated.refresh(current)
        if updated != flow { flow = updated }
    }

    func next() { refresh(); flow.next(facts) }
    func back() { refresh(); flow.back(facts) }
    func skipSignIn() { refresh(); flow.skipSignIn(facts) }
}

/// Owns the onboarding window. Showing is always an explicit decision by the caller.
///
/// One window, one `OnboardingFlow`: welcome, Accessibility (until granted), what Remora never reads,
/// sign-in, "Try the key" (a practice box the rewrite key may read, `FieldRefusal.practiceFieldIdentifier`),
/// dictation, "Stay in the loop" (notifications), done. Done sets `onboarding.completed` and closes it.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let completedKey = "onboarding.completed"
    /// Set by the earlier onboarding once it had offered sign-in; read only to treat upgraders as completed.
    static let legacySignInOfferedKey = "onboarding.signInOffered"

    private var window: NSWindow?
    private var model: OnboardingModel?
    private weak var env: AppEnvironment?
    /// Set while `close()` closes the window, so only the user's close button cancels a sign-in.
    private var closingProgrammatically = false

    init(env: AppEnvironment) {
        self.env = env
    }

    /// The window is on screen (an update never restarts Remora under it).
    var isShowing: Bool { window?.isVisible ?? false }

    /// Fronts the open window, or opens a fresh flow (starting at welcome).
    func show() {
        guard let env else { return }
        if let window {
            model?.refresh()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let model = OnboardingModel(facts: { [weak env] in
            env?.onboardingFacts
                ?? OnboardingFacts(accessibilityGranted: false, signedIn: false, notificationsAsked: true)
        })
        self.model = model
        let view = OnboardingView(env: env, model: model, onDone: { [weak self] in self?.finish() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Remora"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The facts may have changed (permissions tick, Accessibility grant or revoke).
    func refresh() { model?.refresh() }

    func close() {
        closingProgrammatically = true
        window?.close()
        closingProgrammatically = false
        window = nil
        model = nil
    }

    /// "Done": onboarding is finished for good (a signed-out user is no longer shown it at launch).
    private func finish() {
        env?.markOnboardingCompleted()
        close()
    }

    /// The window's close button: a sign-in waiting in the browser is abandoned with it.
    func windowWillClose(_ notification: Notification) {
        guard !closingProgrammatically else { return }
        env?.account.cancelSignIn()
        window = nil
        model = nil
    }
}

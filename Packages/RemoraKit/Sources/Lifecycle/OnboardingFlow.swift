import Foundation


/// The onboarding window's steps, in order. A step that does not apply is skipped (see `OnboardingFlow`).
public enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome, accessibility, neverRead, signIn, tryKey, dictation, notifications, done
}

/// What the flow needs to know about the Mac and the account. Re-read on every permissions tick
/// and account change.
public struct OnboardingFacts: Sendable, Equatable {
    public var accessibilityGranted: Bool
    public var signedIn: Bool
    /// `notifications.asked`: the notification prompt was already shown or declined.
    public var notificationsAsked: Bool

    public init(accessibilityGranted: Bool, signedIn: Bool, notificationsAsked: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.signedIn = signedIn
        self.notificationsAsked = notificationsAsked
    }
}

/// The onboarding step machine. Pure, so it is unit-tested; the window only renders `step`.
///
/// - `accessibility` applies until it is granted; Continue is blocked on it and `refresh` moves past it.
/// - `signIn` applies while signed out; Continue waits for a sign-in, "Later" is `skipSignIn`.
/// - `tryKey` applies only when signed in; `notifications` only while `!notificationsAsked`.
/// - `welcome`, `neverRead`, `dictation` and `done` always apply.
public struct OnboardingFlow: Sendable, Equatable {
    public private(set) var step: OnboardingStep
    /// The user chose "Later" on the sign-in step.
    public private(set) var signInSkipped: Bool

    public init() {
        step = .welcome
        signInSkipped = false
    }

    public func canContinue(_ f: OnboardingFacts) -> Bool {
        switch step {
        case .accessibility: f.accessibilityGranted
        case .signIn: f.signedIn
        default: true
        }
    }

    /// Continue: the next applicable step. Stays put when Continue is blocked or on `done`.
    public mutating func next(_ f: OnboardingFacts) {
        guard canContinue(f), let following = Self.applicable(after: step, f) else { return }
        step = following
    }

    /// The previous applicable step; stays on `welcome`.
    public mutating func back(_ f: OnboardingFacts) {
        let all = OnboardingStep.allCases
        guard let index = all.firstIndex(of: step),
              let previous = all[..<index].last(where: { Self.applies($0, f) }) else { return }
        step = previous
    }

    /// "Later" on the sign-in step: moves on without signing in (which also skips `tryKey`).
    public mutating func skipSignIn(_ f: OnboardingFacts) {
        guard step == .signIn else { return }
        signInSkipped = true
        if let following = Self.applicable(after: step, f) { step = following }
    }

    /// The facts changed: a step that no longer applies (Accessibility granted, signed in) is left
    /// for the next applicable one. Losing Accessibility past its step moves back to it, the only
    /// backward move `refresh` makes.
    public mutating func refresh(_ f: OnboardingFacts) {
        if !f.accessibilityGranted, Self.index(step) > Self.index(.accessibility) {
            step = .accessibility
            return
        }
        guard !Self.applies(step, f), let following = Self.applicable(after: step, f) else { return }
        step = following
    }

    /// An install from before this flow that already saw the old sign-in offer
    /// (`onboarding.signInOffered`) counts as having completed onboarding.
    public static func effectiveCompleted(completed: Bool, legacySignInOffered: Bool) -> Bool {
        completed || legacySignInOffered
    }

    private static func index(_ step: OnboardingStep) -> Int {
        OnboardingStep.allCases.firstIndex(of: step) ?? 0
    }

    /// Shown at launch while Accessibility is missing, or until a signed-out user finishes it once.
    public static func shouldShowAtLaunch(completed: Bool, facts: OnboardingFacts) -> Bool {
        !facts.accessibilityGranted || (!completed && !facts.signedIn)
    }

    /// The step dot row: every applicable step, plus the current one.
    public func visibleSteps(_ f: OnboardingFacts) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { $0 == step || Self.applies($0, f) }
    }

    /// The welcome step's "Read the privacy statement" link; nil (link hidden) while the repository
    /// (`RemoraRepositoryURL`) is empty or a placeholder.
    public static func privacyStatementURL(repository: String?) -> URL? {
        UpdateConfiguration.repositoryURL(repository)?.appending(path: "blob/main/PRIVACY.md")
    }

    static func applies(_ step: OnboardingStep, _ f: OnboardingFacts) -> Bool {
        switch step {
        case .welcome, .neverRead, .dictation, .done: true
        case .accessibility: !f.accessibilityGranted
        case .signIn: !f.signedIn
        case .tryKey: f.signedIn
        case .notifications: !f.notificationsAsked
        }
    }

    private static func applicable(after step: OnboardingStep, _ f: OnboardingFacts) -> OnboardingStep? {
        let all = OnboardingStep.allCases
        guard let index = all.firstIndex(of: step) else { return nil }
        return all[(index + 1)...].first { applies($0, f) }
    }
}

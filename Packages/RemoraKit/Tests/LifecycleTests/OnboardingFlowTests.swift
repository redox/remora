import Testing
@testable import Lifecycle

private let fresh = OnboardingFacts(accessibilityGranted: false, signedIn: false, notificationsAsked: false)

/// Walks `flow` with `next` until `target`, failing after a few steps.
private func advance(_ flow: inout OnboardingFlow, to target: OnboardingStep, _ facts: OnboardingFacts) {
    for _ in 0..<OnboardingStep.allCases.count where flow.step != target { flow.next(facts) }
    #expect(flow.step == target)
}

@Test func freshUserVisitsEveryStepInOrder() {
    var flow = OnboardingFlow()
    var facts = fresh
    var visited = [flow.step]
    while flow.step != .done {
        if flow.step == .accessibility { facts.accessibilityGranted = true }
        if flow.step == .signIn { facts.signedIn = true }
        flow.next(facts)
        visited.append(flow.step)
    }
    #expect(visited == OnboardingStep.allCases)
    #expect(!flow.signInSkipped)
}

@Test func accessibilityBlocksContinueUntilGranted() {
    var flow = OnboardingFlow()
    flow.next(fresh)
    #expect(flow.step == .accessibility)
    #expect(!flow.canContinue(fresh))
    flow.next(fresh)
    #expect(flow.step == .accessibility)
}

@Test func grantingAccessibilityAutoAdvances() {
    var flow = OnboardingFlow()
    flow.next(fresh)
    #expect(flow.step == .accessibility)
    var granted = fresh
    granted.accessibilityGranted = true
    flow.refresh(granted)
    #expect(flow.step == .neverRead)
}

@Test func refreshLeavesAnApplicableStepAlone() {
    var flow = OnboardingFlow()
    flow.refresh(fresh)
    #expect(flow.step == .welcome)
    flow.next(fresh)
    flow.refresh(fresh)
    #expect(flow.step == .accessibility)
}

@Test func laterOnSignInSkipsTryKey() {
    var flow = OnboardingFlow()
    let granted = OnboardingFacts(accessibilityGranted: true, signedIn: false, notificationsAsked: false)
    advance(&flow, to: .neverRead, granted)
    flow.next(granted)
    #expect(flow.step == .signIn)
    flow.skipSignIn(granted)
    #expect(flow.step == .dictation)
    #expect(flow.signInSkipped)
}

@Test func signInBlocksContinueUntilSignedIn() {
    var flow = OnboardingFlow()
    let granted = OnboardingFacts(accessibilityGranted: true, signedIn: false, notificationsAsked: false)
    advance(&flow, to: .signIn, granted)
    #expect(!flow.canContinue(granted))
    var signedIn = granted
    signedIn.signedIn = true
    flow.refresh(signedIn)
    #expect(flow.step == .tryKey)
}

@Test func signedInSkipsSignInStep() {
    var flow = OnboardingFlow()
    let facts = OnboardingFacts(accessibilityGranted: true, signedIn: true, notificationsAsked: false)
    flow.next(facts)
    #expect(flow.step == .neverRead)
    flow.next(facts)
    #expect(flow.step == .tryKey)
}

@Test func notificationsAskedSkipsStep() {
    var flow = OnboardingFlow()
    let facts = OnboardingFacts(accessibilityGranted: true, signedIn: true, notificationsAsked: true)
    advance(&flow, to: .dictation, facts)
    flow.next(facts)
    #expect(flow.step == .done)
}

@Test func nextOnDoneStaysOnDone() {
    var flow = OnboardingFlow()
    let facts = OnboardingFacts(accessibilityGranted: true, signedIn: true, notificationsAsked: true)
    advance(&flow, to: .done, facts)
    flow.next(facts)
    #expect(flow.step == .done)
    #expect(flow.canContinue(facts))
}

@Test func backReturnsToPreviousApplicableStep() {
    var flow = OnboardingFlow()
    let granted = OnboardingFacts(accessibilityGranted: true, signedIn: false, notificationsAsked: false)
    flow.next(granted)
    #expect(flow.step == .neverRead)
    flow.back(granted)
    #expect(flow.step == .welcome)
    flow.back(granted)
    #expect(flow.step == .welcome)
}

@Test func backFromDictationAfterLaterReturnsToSignIn() {
    var flow = OnboardingFlow()
    let granted = OnboardingFacts(accessibilityGranted: true, signedIn: false, notificationsAsked: false)
    advance(&flow, to: .signIn, granted)
    flow.skipSignIn(granted)
    flow.back(granted)
    #expect(flow.step == .signIn)
}

@Test func existingUserWithGrantsIsNotShownOnboarding() {
    #expect(!OnboardingFlow.shouldShowAtLaunch(completed: false, facts: .init(accessibilityGranted: true, signedIn: true, notificationsAsked: false)))
}

@Test func missingAccessibilityAlwaysShowsOnboarding() {
    #expect(OnboardingFlow.shouldShowAtLaunch(completed: true, facts: .init(accessibilityGranted: false, signedIn: true, notificationsAsked: true)))
}

@Test func signedOutUserIsShownOnboardingUntilCompleted() {
    let facts = OnboardingFacts(accessibilityGranted: true, signedIn: false, notificationsAsked: true)
    #expect(OnboardingFlow.shouldShowAtLaunch(completed: false, facts: facts))
    #expect(!OnboardingFlow.shouldShowAtLaunch(completed: true, facts: facts))
}

@Test func dotsShowTheApplicableStepsAndTheCurrentOne() {
    var flow = OnboardingFlow()
    let facts = OnboardingFacts(accessibilityGranted: true, signedIn: true, notificationsAsked: true)
    #expect(flow.visibleSteps(facts) == [.welcome, .neverRead, .tryKey, .dictation, .done])
    flow.next(fresh)
    #expect(flow.step == .accessibility)
    #expect(flow.visibleSteps(facts) == [.welcome, .accessibility, .neverRead, .tryKey, .dictation, .done])
}

@Test func privacyStatementLinksToTheRepository() {
    #expect(OnboardingFlow.privacyStatementURL(repository: "https://github.com/owner/remora")?.absoluteString
        == "https://github.com/owner/remora/blob/main/PRIVACY.md")
}

@Test(arguments: [nil, "", "$(REMORA_REPOSITORY_URL)", "https://github.com//"])
func privacyStatementIsHiddenWithoutARepository(repository: String?) {
    #expect(OnboardingFlow.privacyStatementURL(repository: repository) == nil)
}

@Test func losingAccessibilityPastItsStepMovesBackToIt() {
    var flow = OnboardingFlow()
    let granted = OnboardingFacts(accessibilityGranted: true, signedIn: true, notificationsAsked: false)
    advance(&flow, to: .dictation, granted)
    var revoked = granted
    revoked.accessibilityGranted = false
    flow.refresh(revoked)
    #expect(flow.step == .accessibility)
    flow.refresh(granted)
    #expect(flow.step == .neverRead)
}

@Test func losingAccessibilityOnWelcomeStaysOnWelcome() {
    var flow = OnboardingFlow()
    flow.refresh(fresh)
    #expect(flow.step == .welcome)
}

@Test func refreshNeverMovesBackElsewhere() {
    var flow = OnboardingFlow()
    let signedIn = OnboardingFacts(accessibilityGranted: true, signedIn: true, notificationsAsked: false)
    advance(&flow, to: .dictation, signedIn)
    // Signing out (signIn applies again) or a reset notifications flag never pulls the flow back.
    flow.refresh(OnboardingFacts(accessibilityGranted: true, signedIn: false, notificationsAsked: false))
    #expect(flow.step == .dictation)
}

@Test(arguments: [(false, false, false), (true, false, true), (false, true, true), (true, true, true)])
func legacySignInOfferCountsAsCompleted(completed: Bool, legacy: Bool, expected: Bool) {
    #expect(OnboardingFlow.effectiveCompleted(completed: completed, legacySignInOffered: legacy) == expected)
}

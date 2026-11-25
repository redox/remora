import Capture
import CoreGraphics
import Foundation
import Input
import LLM
import Testing
@testable import Rewrite

// MARK: - Plan

@Test func planUsesTheFieldValueAndItsSelection() throws {
    let p = try #require(try RewriteFlow.plan(value: "Hello world", selection: NSRange(location: 6, length: 5),
                                          selectedText: "world", placeholder: nil))
    #expect(p.mode == .selection(NSRange(location: 6, length: 5)))
    #expect(p.fieldValue == "Hello world" && p.expectedValue == "Hello world")
}

@Test func planDraftsIntoAnEmptyOrPlaceholderField() throws {
    #expect(try RewriteFlow.plan(value: "", selection: nil, selectedText: nil, placeholder: nil)?.mode == .draft)
    #expect(try RewriteFlow.plan(value: "Reply…", selection: NSRange(location: 0, length: 0), selectedText: nil, placeholder: "Reply…")?.mode == .draft)
}

@Test func planFallsBackToTheSelectedTextWhenTheValueIsUnreadable() throws {
    let sel = NSRange(location: 4, length: 3)
    let p = try #require(try RewriteFlow.plan(value: nil, selection: sel, selectedText: "abc", placeholder: nil))
    #expect(p.mode == .full && p.fieldValue == "abc" && p.expectedValue == nil)
    // Written over the selection it came from, never the whole field.
    let out = RewriteOutput(replacement: "xyz", range: NSRange(location: 0, length: 3), callID: 1)
    #expect(p.target(for: out) == .range(sel))
}

@Test(arguments: [
    (String?.none, NSRange?.none, String?.none),
    (nil, NSRange(location: 2, length: 0), ""),
    (nil, nil, "abc"),  // selected text without its range: nowhere safe to write
])
func planRefusesAnUnreadableField(value: String?, sel: NSRange?, selected: String?) throws {
    #expect(try RewriteFlow.plan(value: value, selection: sel, selectedText: selected, placeholder: nil) == nil)
}

@Test func targetIsWholeOnlyWhenTheOutputCoversTheWholeValue() throws {
    let p = try #require(try RewriteFlow.plan(value: "/q why", selection: nil, selectedText: nil, placeholder: nil))
    #expect(p.target(for: RewriteOutput(replacement: "x", range: NSRange(location: 0, length: 6), callID: 1)) == .whole)
    #expect(p.target(for: RewriteOutput(replacement: "x", range: NSRange(location: 1, length: 2), callID: 1))
        == .range(NSRange(location: 1, length: 2)))
}

// MARK: - Gate

private let mail = WindowContext(app: "Mail", bundleID: "com.apple.mail", windowTitle: "Re: lunch")
private let open = CapturePolicy(userRules: [])

private func gate(_ ctx: WindowContext?, contextPID: pid_t? = 10, fieldPID: pid_t = 10, fieldBundleID: String? = "com.apple.mail",
                  policy: CapturePolicy = open, paused: Bool = false) -> RewriteGate {
    RewriteFlow.gate(context: ctx, contextPID: contextPID, fieldPID: fieldPID, fieldBundleID: fieldBundleID,
                     policy: policy, paused: paused)
}

@Test func capturableContextAllowsWindowMemoryAndLog() {
    #expect(gate(mail) == .proceed(RewriteAccess(windowContextAllowed: true, memoryAllowed: true, logAllowed: true, cloudAllowed: true)))
}

/// Paused capture: the cloud with the field text only.
private let pausedCloud = RewriteGate.proceed(RewriteAccess(windowContextAllowed: false, memoryAllowed: false, logAllowed: false,
                                                            cloudAllowed: true))
/// Excluded, private or unverifiable: the on-device model only, with the field text only.
private let onDeviceOnly = RewriteGate.proceed(RewriteAccess(windowContextAllowed: false, memoryAllowed: false, logAllowed: false,
                                                             cloudAllowed: false))

@Test func accessPresetsDifferOnlyInCloudUse() {
    #expect(RewriteAccess.fieldOnlyCloud.cloudAllowed && !RewriteAccess.fieldOnlyOnDevice.cloudAllowed)
    #expect(gate(mail) == .proceed(RewriteAccess(windowContextAllowed: true, memoryAllowed: true, logAllowed: true, cloudAllowed: true)))
}

@Test func pausedIsFieldOnlyInTheCloud() {
    // While capture is paused nothing of the window goes out: no title, no window text, no memory, no log.
    #expect(gate(mail, paused: true) == pausedCloud)
    // Paused and excluded: excluded wins.
    #expect(gate(mail, policy: .denyAll, paused: true) == onDeviceOnly)
    let vault = WindowContext(app: "Chrome", bundleID: "com.google.Chrome", url: URL(string: "https://vault.bitwarden.com/x"))
    #expect(gate(vault, fieldBundleID: "com.google.Chrome", paused: true) == .refuse)
}

@Test func excludedOrUncapturedContextsAreOnDeviceOnly() throws {
    let excluded = CapturePolicy(userRules: [try #require(ExclusionRule(pattern: "app:Mail"))])
    #expect(gate(mail, policy: excluded) == onDeviceOnly)
    let privateWindow = WindowContext(app: "Safari", bundleID: "com.apple.Safari", url: URL(string: "https://example.com"),
                                      isPrivateBrowsing: true)
    #expect(gate(privateWindow, fieldBundleID: "com.apple.Safari") == onDeviceOnly)
    let bank = WindowContext(app: "Safari", bundleID: "com.apple.Safari", url: URL(string: "https://www.chase.com/x"))
    #expect(gate(bank, fieldBundleID: "com.apple.Safari") == onDeviceOnly)
    let unknownURL = WindowContext(app: "Safari", bundleID: "com.apple.Safari")
    #expect(gate(unknownURL, fieldBundleID: "com.apple.Safari") == onDeviceOnly)
    #expect(gate(mail, policy: .denyAll) == onDeviceOnly)
}

@Test func unreadableOrForeignNonBrowserContextIsOnDeviceOnly() {
    #expect(gate(nil, contextPID: nil) == onDeviceOnly)
    #expect(gate(mail, contextPID: 11, fieldPID: 10) == onDeviceOnly)
}

@Test(arguments: ["https://vault.bitwarden.com/#/vault", "https://my.1password.com/home", "https://start.1password.com.my.1password.eu/x"])
func passwordVaultSitesAreRefused(url: String) {
    let ctx = WindowContext(app: "Chrome", bundleID: "com.google.Chrome", url: URL(string: url))
    #expect(gate(ctx, fieldBundleID: "com.google.Chrome") == .refuse)
    // Even when rules are unavailable or the context belongs to another process.
    #expect(gate(ctx, fieldBundleID: "com.google.Chrome", policy: .denyAll) == .refuse)
    #expect(gate(ctx, contextPID: 99, fieldBundleID: "com.google.Chrome") == .refuse)
}

@Test func passwordManagerAppsAreRefused() {
    let pm = WindowContext(app: "1Password", bundleID: "com.1password.1password")
    #expect(gate(pm, fieldBundleID: "com.1password.1password") == .refuse)
    #expect(gate(mail, fieldBundleID: "com.bitwarden.desktop") == .refuse)
}

// MARK: - Sign-in

@Test func signInIsRequiredOnlyForCloudTiers() {
    #expect(RewriteFlow.signInNotice(state: .signedOut, tier: .large) == .signIn)
    #expect(RewriteFlow.signInNotice(state: .needsSignIn, tier: .small) == .signIn)
    #expect(RewriteFlow.signInNotice(state: .signedIn(email: nil, planUsageEnabled: false), tier: .large) == .planUnavailable)
    #expect(RewriteFlow.signInNotice(state: .signedIn(email: nil, planUsageEnabled: true), tier: .large) == nil)
    #expect(RewriteFlow.signInNotice(state: .unavailable, tier: .large) == nil)  // the call reports it
    #expect(RewriteFlow.signInNotice(state: .signedOut, tier: .onDevice) == nil)
}

@Test func signInNoticeOffersSettingsAndUsageLimitOffersManageUsage() {
    #expect(RewriteNotice.signIn.text == "Sign in with ChatGPT to use the rewrite key")
    #expect(RewriteNotice.signIn.action == .openSettings && RewriteNotice.signIn.actionTitle == "Open Settings")
    #expect(RewriteNotice.usageLimit.text == "Usage limit reached")
    #expect(RewriteNotice.usageLimit.action == .manageUsage && RewriteNotice.usageLimit.actionTitle == "Manage usage")
}

// MARK: - Errors and outcomes

@Test(arguments: [
    (LLMError.usageLimit as any Error, "Usage limit reached"),
    (LLMError.needsSignIn, "Sign in with ChatGPT to use the rewrite key"),
    (LLMError.notSignedIn, "Sign in with ChatGPT to use the rewrite key"),
    (LLMError.planUsageDisabled, "ChatGPT plan usage isn't available for this account"),
    (LLMError.notEligible, "ChatGPT plan usage isn't available for this account"),
    (LLMError.temporarilyUnavailable(code: nil), "ChatGPT is unavailable right now. Try again."),
    (LLMError.transport(code: -1009), "ChatGPT is unavailable right now. Try again."),
    (LLMError.http(status: 503), "ChatGPT is unavailable right now. Try again."),
    (RewriteError.tooLong, "Too long to rewrite. Select a part."),
    (RewriteError.emptyQuestion, "Type a question after /q"),
    (RewriteError.selectionOutOfBounds, "Field changed, nothing inserted"),
    (RewriteError.emptyResult, "Something went wrong"),
    (LLMError.schemaMismatch, "Something went wrong"),
    (URLError(.badURL), "Something went wrong"),
])
func errorNotices(error: any Error, text: String) {
    #expect(RewriteFlow.notice(for: error)?.text == text)
}

@Test func cancellationIsSilent() {
    #expect(RewriteFlow.notice(for: CancellationError()) == nil)
    #expect(RewriteFlow.notice(for: LLMError.cancelled) == nil)
}

@Test(arguments: [
    (InsertionOutcome.ax, String?.none, true),
    (.paste(verified: true), nil, true),
    (.paste(verified: false), nil, true),
    (.noChange, nil, false),  // success with nothing inserted: no note, nothing logged
    (.fieldChanged, "Field changed, nothing inserted", false),
    (.notFocused, "Field lost focus, nothing inserted", false),
    (.failed, "Couldn't insert here", false),
])
func insertionOutcomes(outcome: InsertionOutcome, text: String?, inserted: Bool) {
    #expect(RewriteFlow.notice(for: outcome)?.text == text)
    #expect(RewriteFlow.didInsert(outcome) == inserted)
}

// MARK: - Edit rounds

@Test func editRoundTargetsTheSessionAndCommitsOnlyAfterTheWrite() throws {
    let session = try EditSession(value: "Hello world", selection: NSRange(location: 6, length: 5))
    let round = try RewriteFlow.editRound(session, currentValue: "Hello world", selection: NSRange(location: 6, length: 5))
    #expect(round.text == "world" && round.range == NSRange(location: 6, length: 5))
    let (next, newValue) = round.applying("there", to: "Hello world")
    #expect(newValue == "Hello there" && next.canUndo)
    #expect(!round.session.canUndo)  // the round's session is untouched until the caller commits `next`
}

@Test func editRoundStartsOverWhenTheUserEditedTheField() throws {
    var session = try EditSession(value: "abc", selection: nil)
    _ = session.didWrite(result: "ABC", into: "abc")
    let round = try RewriteFlow.editRound(session, currentValue: "ABC!!", selection: nil)
    #expect(round.text == "ABC!!" && !round.session.canUndo)
}

@Test func editRoundRejectsAStaleSelection() throws {
    let session = try EditSession(value: "abc", selection: nil)
    #expect(throws: RewriteError.selectionOutOfBounds) {
        try RewriteFlow.editRound(session, currentValue: "xy", selection: NSRange(location: 10, length: 2))
    }
}

@Test func undoRoundRestoresThePreviousValueOnlyWhenTheFieldIsOurs() throws {
    var session = try EditSession(value: "abc", selection: nil)
    _ = session.didWrite(result: "ABC", into: "abc")
    let undo = try #require(RewriteFlow.undoRound(session, currentValue: "ABC", selection: nil))
    #expect(undo.value == "abc" && !undo.session.canUndo)
    // The user typed since our write: undo would clobber their text.
    #expect(RewriteFlow.undoRound(session, currentValue: "ABC and more", selection: nil) == nil)
    #expect(RewriteFlow.undoRound(try EditSession(value: "abc", selection: nil), currentValue: "abc", selection: nil) == nil)
}

// MARK: - Surface

@Test func surfaceIsTheDomainInBrowsersElseTheBundleID() {
    let page = WindowContext(app: "Safari", bundleID: "com.apple.Safari", url: URL(string: "https://www.linkedin.com/feed"))
    #expect(RewriteFlow.surface(app: "Safari", bundleID: "com.apple.Safari", context: page) == "www.linkedin.com")
    #expect(RewriteFlow.surface(app: "Safari", bundleID: "com.apple.Safari", context: nil) == "com.apple.Safari")
    #expect(RewriteFlow.surface(app: "Mail", bundleID: "com.apple.mail", context: mail) == "com.apple.mail")
    #expect(RewriteFlow.surface(app: "Tool", bundleID: nil, context: nil) == "Tool")
}

// MARK: - Fix round 1

@Test func browserFieldWithUnreadableContextIsRefused() {
    // The page could be a password vault: fail closed.
    #expect(gate(nil, contextPID: nil, fieldBundleID: "com.google.Chrome") == .refuse)
    #expect(gate(nil, contextPID: nil, fieldBundleID: "com.apple.Safari") == .refuse)
    #expect(gate(nil, contextPID: nil, fieldBundleID: "com.apple.mail") == onDeviceOnly)
}

@Test func browserFieldWithAnotherProcessContextIsRefused() {
    // The frontmost context belongs to another process: the field's page cannot be verified.
    let page = WindowContext(app: "Chrome", bundleID: "com.google.Chrome", url: URL(string: "https://example.com"))
    #expect(gate(page, contextPID: 11, fieldPID: 10, fieldBundleID: "com.google.Chrome") == .refuse)
    #expect(gate(mail, contextPID: 11, fieldPID: 10, fieldBundleID: "com.apple.Safari") == .refuse)
    // Not a browser: the field text only.
    #expect(gate(mail, contextPID: 11, fieldPID: 10) == onDeviceOnly)
    #expect(gate(page, contextPID: 10, fieldPID: 10, fieldBundleID: "com.google.Chrome")
        == .proceed(RewriteAccess(windowContextAllowed: true, memoryAllowed: true, logAllowed: true, cloudAllowed: true)))
}

private func mayRecord(_ ctx: WindowContext?, contextPID: pid_t? = 10, fieldPID: pid_t = 10, policy: CapturePolicy = open,
                       paused: Bool = false, focused: Bool = true) -> Bool {
    RewriteFlow.mayRecordOutcome(paused: paused, context: ctx, contextPID: contextPID, fieldPID: fieldPID,
                                 policy: policy, fieldFocused: focused)
}

@Test func outcomeIsRecordedOnlyForTheSameCapturableFocusedField() throws {
    #expect(mayRecord(mail))
    #expect(!mayRecord(mail, paused: true))
    #expect(!mayRecord(nil, contextPID: nil))
    #expect(!mayRecord(mail, contextPID: 11))
    #expect(!mayRecord(mail, policy: .denyAll))
    #expect(!mayRecord(mail, policy: CapturePolicy(userRules: [try #require(ExclusionRule(pattern: "app:Mail"))])))
    #expect(!mayRecord(mail, focused: false))
    let privateWindow = WindowContext(app: "Safari", bundleID: "com.apple.Safari", url: URL(string: "https://example.com"),
                                      isPrivateBrowsing: true)
    #expect(!mayRecord(privateWindow))
    let vault = WindowContext(app: "Chrome", bundleID: "com.google.Chrome", url: URL(string: "https://vault.bitwarden.com/x"))
    #expect(!mayRecord(vault))
}

@Test func editRoundRequestIsFieldOnlyWhilePausedAndDropsTheWindowAfterAWrite() {
    let base = RewriteRequest(mode: .full, fieldValue: "a", app: "Mail", bundleID: "com.apple.mail", surface: "com.apple.mail",
                              windowTitle: "Re: x", liveWindowText: "thread", memoryAllowed: true, logAllowed: true,
                              cloudAllowed: true)
    let first = RewriteFlow.roundRequest(base, fieldValue: "b", paused: false, wroteBefore: false)
    #expect(first.fieldValue == "b" && first.mode == .full && first.liveWindowText == "thread" && first.logAllowed)
    let later = RewriteFlow.roundRequest(base, fieldValue: "c", paused: false, wroteBefore: true)
    #expect(later.liveWindowText == nil && later.windowTitle == "Re: x" && later.memoryAllowed && later.logAllowed)
    let paused = RewriteFlow.roundRequest(base, fieldValue: "d", paused: true, wroteBefore: false)
    #expect(paused.windowTitle == nil && paused.liveWindowText == nil && !paused.memoryAllowed && !paused.logAllowed)
}

@Test func unusableChordGetsItsOwnMessage() {
    let shiftOnly = KeyChord(keyCode: 5, command: false, shift: true, option: false, control: false)
    #expect(RewriteFlow.chordError(shiftOnly, name: "⇧G", registered: false) == "⇧G can't be used as a shortcut. Include ⌘, ⌃ or ⌥.")
    #expect(RewriteFlow.chordError(ShortcutSettings().chord, name: "⇧⌘G", registered: false)
        == "⇧⌘G is used by another app. Pick another shortcut.")
    #expect(RewriteFlow.chordError(ShortcutSettings().chord, name: "⇧⌘G", registered: true) == nil)
}

// MARK: - Final fix wave

@Test func refusedFieldNeverShowsSignIn() {
    // The privacy gate runs first: a refused field beeps and never asks to sign in.
    #expect(RewriteFlow.preflight(gate: .refuse, signIn: .signIn) == .refuse)
    #expect(RewriteFlow.preflight(gate: pausedCloud, signIn: .signIn) == .notice(.signIn))
    #expect(RewriteFlow.preflight(gate: pausedCloud, signIn: nil) == .proceed(.fieldOnlyCloud))
    // On-device only needs no ChatGPT account: no sign-in notice.
    #expect(RewriteFlow.preflight(gate: onDeviceOnly, signIn: .signIn) == .proceed(.fieldOnlyOnDevice))
}

private let richNotice = "This field has attachments or formatting Remora can't rewrite whole — select the text to rewrite"

@Test func richFieldsAllowInsertionAndRefuseReplacingAttachments() throws {
    let rich = "Hi \u{FFFC} there"
    let caret = NSRange(location: 2, length: 0)
    let insertion = try #require(try RewriteFlow.plan(value: rich, selection: caret, selectedText: "", placeholder: nil))
    #expect(insertion.mode == .draftAtCaret(2) && insertion.prefersPaste)
    #expect(try RewriteFlow.plan(value: rich, selection: nil, selectedText: nil, placeholder: nil) == nil)
    // `/q` replaces the whole field too.
    #expect(throws: RewriteError.richContent) {
        try RewriteFlow.plan(value: "/q when? \u{FFFC}", selection: nil, selectedText: nil, placeholder: nil)
    }
    // A selection that takes in the attachment would drop it.
    #expect(throws: RewriteError.richContent) {
        try RewriteFlow.plan(value: rich, selection: NSRange(location: 0, length: 6), selectedText: "Hi \u{FFFC} t", placeholder: nil)
    }
    #expect(throws: RewriteError.richContent) {
        try RewriteFlow.plan(value: nil, selection: NSRange(location: 0, length: 3), selectedText: "a\u{FFFC}b", placeholder: nil)
    }
    // Selecting plain text next to it is fine: only the selection is replaced.
    let p = try #require(try RewriteFlow.plan(value: rich, selection: NSRange(location: 5, length: 5), selectedText: "there",
                                              placeholder: nil))
    #expect(p.mode == .selection(NSRange(location: 5, length: 5)))
    #expect(RewriteFlow.notice(for: RewriteError.richContent)?.text == richNotice)
}

@Test func editBarFooterNamesTheRoundsBackend() {
    #expect(RewriteFlow.editBarFooter(backend: .siwc, fieldOnly: false) == "Using ChatGPT plan")
    #expect(RewriteFlow.editBarFooter(backend: .onDevice, fieldOnly: false) == "On-device")
    #expect(RewriteFlow.editBarFooter(backend: .siwc, fieldOnly: true) == "Using ChatGPT plan · Field only")
    #expect(RewriteFlow.editBarFooter(backend: .onDevice, fieldOnly: true) == "On-device · Field only")
    #expect(RewriteFlow.editBarFooter(backend: .onDevice, fieldOnly: true, onDeviceOnly: true) == "On-device (not captured)")
    // Before the first round of an on-device tier, the route can still fall back to ChatGPT.
    #expect(RewriteFlow.editBarFooter(backend: nil, fieldOnly: false) == "On-device or ChatGPT")
    #expect(RewriteFlow.editBarFooter(backend: nil, fieldOnly: true) == "On-device or ChatGPT · Field only")
}

@Test(arguments: [
    "Apple Intelligence is turned off.",
    "The on-device model is not ready yet.",
    "The input is too large for the on-device model.",
])
func onDeviceOnlyFailureLeadsWithTheOutcomeAndPreservesTheReason(reason: String) throws {
    let error = LLMError.onDeviceUnavailable(reason: reason)
    let notice = try #require(RewriteFlow.notice(for: error, onDeviceOnly: true))
    #expect(notice.text == "Couldn't rewrite here")
    #expect(notice.detail == "\(reason) Rewrites here run only on this Mac.")
    #expect(RewriteFlow.notice(for: LLMError.cancelled, onDeviceOnly: true) == nil)
}

@Test(arguments: [RewriteMode.draft, .draftAtCaret(6)])
func onDeviceOnlyDraftFailureNamesInsertion(mode: RewriteMode) throws {
    let error = LLMError.onDeviceUnavailable(reason: "The on-device model is not ready yet.")
    let notice = try #require(RewriteFlow.notice(for: error, onDeviceOnly: true, mode: mode))
    #expect(notice.text == "Couldn't insert here")
    #expect(notice.detail == "The on-device model is not ready yet. Here, this shortcut drafts only on this Mac.")
}

@Test func onDeviceModelFailureShowsTheReason() throws {
    let error = LLMError.onDeviceUnavailable(reason: "Apple Intelligence is turned off.")
    let notice = try #require(RewriteFlow.notice(for: error))
    #expect(notice.text == "On-device model unavailable")
    #expect(notice.detail == "Apple Intelligence is turned off.")
}

@Test func roundRequestKeepsTheCloudRule() {
    let base = RewriteRequest(mode: .full, fieldValue: "a", app: "Mail", bundleID: "com.apple.mail", surface: "com.apple.mail",
                              windowTitle: nil, liveWindowText: nil, memoryAllowed: false, logAllowed: false, cloudAllowed: false)
    #expect(!RewriteFlow.roundRequest(base, fieldValue: "b", paused: false, wroteBefore: true).cloudAllowed)
    #expect(!RewriteFlow.roundRequest(base, fieldValue: "b", paused: true, wroteBefore: false).cloudAllowed)
}

@Test func requestWithoutWindowContextIsFieldOnly() {
    let base = RewriteRequest(mode: .full, fieldValue: "a", app: "Mail", bundleID: "com.apple.mail", surface: "com.apple.mail",
                              windowTitle: "Re: x", liveWindowText: "thread", memoryAllowed: true, logAllowed: true,
                              cloudAllowed: true)
    #expect(!RewriteFlow.isFieldOnly(base))
    #expect(!RewriteFlow.isFieldOnly(RewriteFlow.roundRequest(base, fieldValue: "b", paused: false, wroteBefore: true)))
    #expect(RewriteFlow.isFieldOnly(RewriteFlow.roundRequest(base, fieldValue: "b", paused: true, wroteBefore: false)))
    var withheld = base
    withheld.windowTitle = nil
    withheld.liveWindowText = nil
    #expect(RewriteFlow.isFieldOnly(withheld))
}

// MARK: - Re-review

@Test func editModeRefusesAFieldWithAnAttachment() throws {
    // Edit rounds write the whole value: an attachment (U+FFFC) would be flattened.
    #expect(throws: RewriteError.richContent) { try RewriteFlow.checkEditable("Hi \u{FFFC}") }
    try RewriteFlow.checkEditable("Hi there")
    // An image pasted between rounds: that round is refused.
    let session = try EditSession(value: "Hi there", selection: nil)
    #expect(throws: RewriteError.richContent) {
        try RewriteFlow.editRound(session, currentValue: "Hi there \u{FFFC}", selection: nil)
    }
}

@Test func draftInAnExistingFieldInsertsAtTheCaret() throws {
    let caret = NSRange(location: 6, length: 0)
    let plan = try #require(try RewriteFlow.plan(value: "Hello world", selection: caret,
                                               selectedText: "", placeholder: nil))
    let output = RewriteOutput(replacement: "dear ", range: caret, callID: 1)
    #expect(plan.mode == .draftAtCaret(6))
    #expect(plan.expectedSelection == caret)
    #expect(plan.expectedValue == "Hello world")
    #expect(plan.target(for: output) == .caret)
}

@Test func draftRefusesAnUnknownCaretInAnExistingField() throws {
    #expect(try RewriteFlow.plan(value: "Existing text", selection: nil, selectedText: nil, placeholder: nil) == nil)
}

@Test func draftRefusesAnOutOfBoundsCaret() throws {
    #expect(throws: RewriteError.selectionOutOfBounds) {
        try RewriteFlow.plan(value: "Existing text", selection: NSRange(location: 50, length: 0),
                             selectedText: "", placeholder: nil)
    }
}

@Test func docsCopiesOnlySelectionsWhoseWordsAreMissingFromTheInputProxy() {
    let docs = WindowContext(app: "Chrome", bundleID: "com.google.Chrome",
                             url: URL(string: "https://docs.google.com/document/d/example/edit"))
    let selected = NSRange(location: 0, length: 1)
    #expect(RewriteFlow.needsGoogleDocsSelectionCopy(value: "\u{200B}", selection: selected, context: docs))
    #expect(RewriteFlow.needsGoogleDocsSelectionCopy(value: nil, selection: selected, context: docs))
    #expect(!RewriteFlow.needsGoogleDocsSelectionCopy(value: "words", selection: selected, context: docs))
    #expect(!RewriteFlow.needsGoogleDocsSelectionCopy(value: "", selection: NSRange(location: 0, length: 0), context: docs))
    #expect(!RewriteFlow.needsGoogleDocsSelectionCopy(value: "", selection: selected, context: nil))
}

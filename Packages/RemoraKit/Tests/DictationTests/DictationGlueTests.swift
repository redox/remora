import Capture
import Foundation
import Input
import Testing
@testable import Dictation

// MARK: - How long a notice stays

@Test func noticeDisplayDuration() {
    #expect(DictationNotice.nothingHeard.displayDuration == .seconds(2))
    #expect(DictationNotice.microphoneDenied.displayDuration == .seconds(4))
    #expect(DictationNotice.assetMissing(.fr).displayDuration == .seconds(4))
}

// MARK: - Insertion target at insertion time

@Test(arguments: [
    (FieldRefusal?.none, false, DictationTarget.field),
    (.some(.secureField), false, .refuseSecure),
    (.some(.passwordManager), false, .refuseSecure),
    (.some(.ownApp), false, .nowhere),
    (.some(.noFocusedElement), false, .frontmostPaste),
    // A busy app may handle ⌘V late, after the clipboard is restored: never paste blind into it.
    (.some(.notResponding), false, .nowhere),
    // Secure Input on at insertion time: never paste or write, whatever is focused.
    (FieldRefusal?.none, true, .refuseSecure),
    (.some(.noFocusedElement), true, .refuseSecure),
    (.some(.ownApp), true, .refuseSecure),
    (.some(.notResponding), true, .refuseSecure),
])
func insertionTarget(_ refusal: FieldRefusal?, secureInput: Bool, expected: DictationTarget) {
    #expect(DictationTarget.atInsertion(fieldRefusal: refusal, secureInputOn: secureInput) == expected)
}

// MARK: - The character before the caret

@Test func precedingCharacterBeforeTheSelection() {
    #expect(DictationSpacing.preceding(value: "Hello world", selection: NSRange(location: 5, length: 0)) == "o")
    #expect(DictationSpacing.preceding(value: "Hello world", selection: NSRange(location: 6, length: 5)) == " ")
    #expect(DictationSpacing.preceding(value: "Hello", selection: NSRange(location: 5, length: 0)) == "o")
}

@Test func precedingCharacterUnknownOrNone() {
    #expect(DictationSpacing.preceding(value: "Hello", selection: NSRange(location: 0, length: 0)) == nil)
    #expect(DictationSpacing.preceding(value: nil, selection: NSRange(location: 3, length: 0)) == nil)
    #expect(DictationSpacing.preceding(value: "Hello", selection: nil) == nil)
    // A selection outside the value (stale read): unknown.
    #expect(DictationSpacing.preceding(value: "Hi", selection: NSRange(location: 9, length: 0)) == nil)
    #expect(DictationSpacing.preceding(value: "Hi", selection: NSRange(location: NSNotFound, length: 0)) == nil)
}

/// Ranges are UTF-16: the character before an emoji's end is the whole emoji, not half a surrogate.
@Test func precedingCharacterIsAWholeCharacter() {
    let value = "ok 👍"
    let end = (value as NSString).length
    #expect(DictationSpacing.preceding(value: value, selection: NSRange(location: end, length: 0)) == "👍")
    // Inside a surrogate pair: unknown rather than a broken character.
    #expect(DictationSpacing.preceding(value: value, selection: NSRange(location: end - 1, length: 0)) == nil)
}

// MARK: - Rewrite key while dictation may run (spoken Edit-mode instructions)

private func state(dictationActive: Bool = false, voiceHold: Bool = false, canDictate: Bool = true,
                   rewriteWorking: Bool = false, barOpen: Bool = false,
                   holdOpenedBar: Bool = false) -> EditVoiceRoute.State {
    EditVoiceRoute.State(dictationActive: dictationActive, voiceHold: voiceHold,
                         canDictateInstruction: canDictate, rewriteWorking: rewriteWorking,
                         barOpen: barOpen, holdOpenedBar: holdOpenedBar)
}

@Test(arguments: [
    // Gestures with the popover closed.
    (TapDetector.Output.singleTap, state(), EditVoiceRoute.Action.openPopover),
    (.doubleTap, state(), .rewrite),
    (.doubleTap, state(barOpen: true), .ignore),
    (.holdReleased, state(), .openPopover),
    (.holdCancelled, state(), .hideHoldHint),
    // The hold arms: provisional listening, opening the bar when it is not open yet.
    (.holdArmed, state(), .beginInstruction(openBar: true)),
    (.holdArmed, state(barOpen: true), .beginInstruction(openBar: false)),
    // Dictation can't take an instruction: Plan 2's hint, and the release opens the bar as today.
    (.holdArmed, state(canDictate: false), .showHoldHint),
    (.holdReleased, state(canDictate: false), .openPopover),
    // A rewrite or an Edit round is working: no listening.
    (.holdArmed, state(rewriteWorking: true), .ignore),
    (.holdArmed, state(rewriteWorking: true, barOpen: true), .ignore),
])
func routesWritingGestures(_ o: TapDetector.Output, _ s: EditVoiceRoute.State, expected: EditVoiceRoute.Action) {
    #expect(EditVoiceRoute.decide(o, s) == expected)
}

@Test(arguments: [
    (TapDetector.Output.holdReleased, state(dictationActive: true, voiceHold: true), EditVoiceRoute.Action.finishInstruction),
    // The session may have failed to start or ended: the release still ends the hold.
    (.holdReleased, state(voiceHold: true), .finishInstruction),
    (.holdCancelled, state(dictationActive: true, voiceHold: true, holdOpenedBar: true), .cancelInstruction(closeBar: true)),
    (.holdCancelled, state(dictationActive: true, voiceHold: true, barOpen: true), .cancelInstruction(closeBar: false)),
    (.singleTap, state(dictationActive: true, voiceHold: true), .ignore),
    (.doubleTap, state(dictationActive: true, voiceHold: true), .ignore),
    (.holdArmed, state(dictationActive: true, voiceHold: true), .ignore),
    // Released before the first partial arrived (a short one-word instruction): still finished, so
    // the final text is awaited rather than dropped.
    (.holdReleased, state(dictationActive: true, voiceHold: true, holdOpenedBar: true), .finishInstruction),
    (.holdReleased, state(dictationActive: true, voiceHold: true, barOpen: true), .finishInstruction),
])
func voiceHoldEnds(_ o: TapDetector.Output, _ s: EditVoiceRoute.State, expected: EditVoiceRoute.Action) {
    #expect(EditVoiceRoute.decide(o, s) == expected)
}

/// The bar takes the keyboard whenever it is open, except while the rewrite key is still held for an
/// instruction that opened it (an ⌥ character typed meanwhile must still reach the user's app).
@Test(arguments: [
    (true, false, false, true),
    (true, true, false, true),   // a hold over a bar that was already open: it was key already
    (true, true, true, false),   // the hold opened it and is still down
    (true, false, true, true),
    (false, false, false, false),
    (false, true, true, false),
])
func barTakesFocus(barOpen: Bool, voiceHold: Bool, holdOpenedBar: Bool, expected: Bool) {
    #expect(EditVoiceRoute.barTakesFocus(barOpen: barOpen, voiceHold: voiceHold, holdOpenedBar: holdOpenedBar) == expected)
}

// MARK: - Cleanup route for dictation (fix round 1)

private let safari = "com.apple.Safari"
private let notes = "com.apple.Notes"
private func ctx(_ bundle: String, url: String? = nil, isPrivate: Bool = false) -> WindowContext {
    WindowContext(app: "App", bundleID: bundle, windowTitle: "T", url: url.flatMap(URL.init(string:)),
                  isPrivateBrowsing: isPrivate)
}

/// Only secure fields, password managers and vaults refuse; an unverifiable browser page (no
/// context, or another process's) is cleaned on-device instead of losing the words.
@Test(arguments: [
    // Unverifiable browser contexts: on-device only.
    (WindowContext?.none, pid_t?.some(10), pid_t?.some(10), String?.some(safari), false, CleanupRoute.onDeviceOnly),
    (ctx(safari, url: "https://example.com"), 11, 10, safari, false, .onDeviceOnly),
    // Vaults and password managers: refuse, whatever the PIDs.
    (ctx(safari, url: "https://vault.bitwarden.com/#/vault"), 10, 10, safari, false, .refuse),
    (ctx(safari, url: "https://my.1password.com"), 11, 10, safari, false, .refuse),
    (ctx("com.1password.1password"), 10, 10, "com.1password.1password", false, .refuse),
    (nil, nil, 10, "com.bitwarden.desktop", false, .refuse),
    (ctx("com.apple.Passwords"), 10, nil, nil, false, .refuse),
    // Capturable context: cloud (paused too: transcript only).
    (ctx(notes), 10, 10, notes, false, .cloud),
    (ctx(notes), 10, 10, notes, true, .cloud),
    (ctx(safari, url: "https://example.com"), 10, 10, safari, true, .cloud),
    // Excluded or private: on-device only.
    (ctx(safari, url: "https://example.com", isPrivate: true), 10, 10, safari, false, .onDeviceOnly),
    (ctx(safari, url: "https://excluded.test/page"), 10, 10, safari, false, .onDeviceOnly),
    // Nothing known about the target: on-device only.
    (nil, nil, nil, nil, false, .onDeviceOnly),
])
func dictationCleanupRoute(_ context: WindowContext?, contextPID: pid_t?, fieldPID: pid_t?, fieldBundleID: String?,
                           paused: Bool, expected: CleanupRoute) {
    let policy = CapturePolicy(userRules: [ExclusionRule(pattern: "excluded.test")!])
    #expect(CleanupRoute.forDictation(context: context, contextPID: contextPID, fieldPID: fieldPID,
                                      fieldBundleID: fieldBundleID, policy: policy, paused: paused) == expected)
}

@Test func dictationRouteWithUnreadableRulesStaysOnDevice() {
    #expect(CleanupRoute.forDictation(context: ctx(notes), contextPID: 10, fieldPID: 10, fieldBundleID: notes,
                                      policy: .denyAll, paused: false) == .onDeviceOnly)
}

@Test func cleanTapSwitchesTheOpenPopoverMode() {
    #expect(EditVoiceRoute.decide(.singleTap, state(barOpen: true)) == .switchMode)
    #expect(EditVoiceRoute.decide(.singleTap, state(dictationActive: true, barOpen: true)) == .switchMode)
}

@Test func finalTranscriptWaitsForAnExplicitAction() {
    #expect(EditVoiceRoute.settleFinal("Make it shorter.") == "Make it shorter.")
    #expect(EditVoiceRoute.settleFinal("  ") == nil)
}

@Test func writingPopoverPrefersInsertAtTheCaretAndEditForASelection() {
    let caret = EditVoiceRoute.Mode.preferred(replacesSelection: false)
    let selection = EditVoiceRoute.Mode.preferred(replacesSelection: true)
    #expect(caret == .insert && caret.actionTitle(replacesSelection: false) == "Insert at caret")
    #expect(selection == .edit && selection.actionTitle(replacesSelection: true) == "Rewrite selection")
}

import Capture
import Foundation
import Rewrite
import Testing
@testable import Dictation

private func cond(enabled: Bool = true, active: Bool = false, busy: Bool = false, available: Bool = true,
                  mic: MicrophoneStatus = .granted, asset: AssetState = .installed) -> StartConditions {
    StartConditions(enabled: enabled, sessionActive: active, rewriteBusy: busy, transcriberAvailable: available,
                    microphone: mic, asset: asset)
}

@Test(arguments: [
    (cond(enabled: false), StartDecision.ignore),
    (cond(active: true), .ignore),
    (cond(busy: true), .ignore),
    (cond(available: false), .refuse(.unsupported)),
    (cond(mic: .notDetermined), .requestMicrophone),
    (cond(mic: .denied), .refuse(.microphoneDenied)),
    (cond(mic: .restricted), .refuse(.microphoneDenied)),
    (cond(asset: .installing(0.42)), .refuse(.assetDownloading(.fr, 0.42))),
    (cond(asset: .unsupported), .refuse(.localeUnsupported(.fr))),
    (cond(asset: .failed("x")), .refuse(.assetMissing(.fr))),
    (cond(asset: .notInstalled), .refuse(.assetMissing(.fr))),
    (cond(asset: .unknown), .refuse(.assetMissing(.fr))),
    (cond(), .start),
])
func startCheck(_ c: StartConditions, expected: StartDecision) {
    #expect(StartCheck.evaluate(c, locale: .fr) == expected)
}

@Test func noticeCopy() {
    #expect(DictationNotice.assetDownloading(.fr, 0.42).text == "Downloading the French speech model… 42%")
    #expect(DictationNotice.microphoneDenied.action == .openMicrophoneSettings)
    #expect(DictationNotice.assetMissing(.fr).text == "The French speech model isn't installed yet. Downloading…")
    #expect(DictationNotice.assetMissing(.fr).action == .openDictationSettings)
    #expect(DictationNotice.localeUnsupported(.fr).text == "French dictation isn't supported on this Mac.")
    #expect(DictationNotice.localeUnsupported(.en).text == "English dictation isn't supported on this Mac.")
    let expected: [(DictationNotice, String)] = [
        (.microphoneDenied, "Microphone access is off for Remora."),
        (.microphoneRequested, "Allow microphone access to dictate."),
        (.unsupported, "Speech recognition isn't available on this Mac."),
        (.microphoneNotReady, "No audio received. Wait for Listening, then speak."),
        (.nothingHeard, "No speech recognized. Check the language and try again."),
        (.cleanupSkipped, "Using the original transcript."),
        (.secureField, "Can't dictate into a password field."),
        (.copiedInstead, "Couldn't insert here. Copied to the clipboard."),
        (.limitReached, "Stopped after 5 minutes."),
        (.microphoneLost, "Microphone disconnected. Stopped listening."),
        (.failed, "Dictation stopped unexpectedly."),
    ]
    for (n, t) in expected { #expect(n.text == t) }
}

@Test(arguments: [(true, true, false, DictationTarget.refuseSecure), (true, false, false, .field),
                  (false, false, true, .nowhere), (false, false, false, .frontmostPaste), (false, true, false, .refuseSecure)])
func decidesTarget(field: Bool, secure: Bool, selfFront: Bool, expected: DictationTarget) {
    #expect(DictationTarget.decide(fieldPresent: field, isSecure: secure, frontmostIsSelf: selfFront) == expected)
}

@Test func cleanupRouteFollowsRewriteGate() {
    #expect(CleanupRoute(gate: .refuse) == .refuse)
    #expect(CleanupRoute(gate: .proceed(.fieldOnlyOnDevice)) == .onDeviceOnly)
    #expect(CleanupRoute(gate: .proceed(.fieldOnlyCloud)) == .cloud)
    #expect(CleanupRoute(gate: .proceed(RewriteAccess(windowContextAllowed: true, memoryAllowed: true, logAllowed: true, cloudAllowed: true))) == .cloud)
    #expect(CleanupRoute(gate: nil) == .onDeviceOnly)  // unverifiable: fail closed to on-device
    #expect(CleanupRoute.cloud.cloudAllowed); #expect(!CleanupRoute.onDeviceOnly.cloudAllowed)
}

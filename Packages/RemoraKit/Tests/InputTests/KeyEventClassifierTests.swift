import AppKit
import Testing
@testable import Input

@Test(arguments: [
    (61, 0x80140, TapDetector.Input.triggerDown),  // ⌥ + right-alt bit
    (61, 0x100, .triggerUp),
    (58, 0x80120, .otherModifier),  // left ⌥
    (61, 0x180140, .otherModifier),  // ⌘ held + right ⌥
    (61, 0x80160, .otherModifier),  // left ⌥ already held, then right ⌥
    (61, 0xA0140, .otherModifier),  // ⇧ held + right ⌥
    (61, 0x90140, .triggerDown),  // caps lock on: ignored
    (61, 0x880140, .triggerDown),  // fn: ignored
    (61, 0x80120, .triggerUp),  // right ⌥ released while left ⌥ stays down
    (56, 0x20102, .otherModifier),  // left ⇧
])
func classifiesFlags(code: UInt16, flags: UInt, expected: TapDetector.Input) {
    #expect(KeyEventClassifier.classify(type: .flagsChanged, keyCode: code, flags: flags, trigger: .rightOption) == expected)
}

@Test func otherTriggers() {
    #expect(KeyEventClassifier.classify(type: .flagsChanged, keyCode: 54, flags: 0x100110, trigger: .rightCommand) == .triggerDown)
    #expect(KeyEventClassifier.classify(type: .flagsChanged, keyCode: 54, flags: 0x100118, trigger: .rightCommand) == .otherModifier)
    #expect(KeyEventClassifier.classify(type: .flagsChanged, keyCode: 62, flags: 0x42100, trigger: .rightControl) == .triggerDown)
    #expect(KeyEventClassifier.classify(type: .flagsChanged, keyCode: 60, flags: 0x20104, trigger: .rightShift) == .triggerDown)
    #expect(KeyEventClassifier.classify(type: .flagsChanged, keyCode: 60, flags: 0x100, trigger: .rightShift) == .triggerUp)
}

@Test func triggerDuringClickIsAModifier() {
    #expect(KeyEventClassifier.classify(type: .flagsChanged, keyCode: 61, flags: 0x80140, trigger: .rightOption, mouseButtonsDown: true) == .otherModifier)
    #expect(KeyEventClassifier.classify(type: .flagsChanged, keyCode: 61, flags: 0x100, trigger: .rightOption, mouseButtonsDown: true) == .triggerUp)
}

@Test func keysAndMouse() {
    #expect(KeyEventClassifier.classify(type: .keyDown, keyCode: 14, flags: 0x80140, trigger: .rightOption) == .otherKey)
    #expect(KeyEventClassifier.classify(type: .systemDefined, keyCode: 0, flags: 0, trigger: .rightOption) == .otherKey)
    for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
                                    .leftMouseDragged, .scrollWheel] {
        #expect(KeyEventClassifier.classify(type: type, keyCode: 0, flags: 0x80140, trigger: .rightOption) == .mouse)
    }
    #expect(KeyEventClassifier.classify(type: .mouseMoved, keyCode: 0, flags: 0, trigger: .rightOption) == nil)
}

@Test func triggerConstants() {
    #expect(TriggerKey.allCases.map(\.keyCode) == [61, 54, 62, 60])
    #expect(TriggerKey.allCases.map(\.deviceMask) == [0x40, 0x10, 0x2000, 0x04])
}

@Test func shortcutDefaultsAndForwardCompatibleDecoding() throws {
    let s = ShortcutSettings()
    #expect(s.rewriteKeyEnabled && s.trigger == .rightOption && s.doubleTapRewrites && s.holdOpensEdit && s.soundsEnabled)
    // A system-wide ⇧⌘G swallows Find Previous and Go to Folder in every app: off unless turned on.
    #expect(!s.chordEnabled)
    #expect(try !JSONDecoder().decode(ShortcutSettings.self, from: Data("{}".utf8)).chordEnabled)
    #expect(s.chord == KeyChord(keyCode: 5, command: true, shift: true, option: false, control: false))
    #expect(ShortcutSettings.settingsKey == "input.shortcuts")
    let partial = try JSONDecoder().decode(ShortcutSettings.self, from: Data(#"{"trigger":"rightCommand","holdOpensEdit":false}"#.utf8))
    #expect(partial.trigger == .rightCommand && !partial.holdOpensEdit && partial.doubleTapRewrites)
    let round = try JSONDecoder().decode(ShortcutSettings.self, from: JSONEncoder().encode(partial))
    #expect(round == partial)
}

@Test func fnPressDirtiesRewriteTap() {
    #expect(KeyEventClassifier.classify(type: .flagsChanged, keyCode: 63, flags: 0x800100, trigger: .rightOption) == .otherModifier)
    #expect(KeyEventClassifier.classify(type: .flagsChanged, keyCode: 63, flags: 0x100, trigger: .rightOption) == .otherModifier)
}

@Test func savedDoubleTapOptOutSurvivesGestureChange() throws {
    let json = Data(#"{"doubleTapOpensEdit":false}"#.utf8)
    let settings = try JSONDecoder().decode(ShortcutSettings.self, from: json)
    #expect(!settings.doubleTapRewrites)
    let restored = try JSONDecoder().decode(ShortcutSettings.self, from: JSONEncoder().encode(settings))
    #expect(!restored.doubleTapRewrites)
}

import Testing
@testable import Input

@Test func modifierSymbolsUseApplesOrder() {
    #expect(ShortcutSettings().chord.modifierSymbols == "⇧⌘")
    let all = KeyChord(keyCode: 5, command: true, shift: true, option: true, control: true)
    #expect(all.modifierSymbols == "⌃⌥⇧⌘")
}

@Test func hotKeyNeedsCommandControlOrOption() {
    #expect(ShortcutSettings().chord.isUsableHotKey)
    #expect(KeyChord(keyCode: 5, command: false, shift: false, option: true, control: false).isUsableHotKey)
    #expect(!KeyChord(keyCode: 5, command: false, shift: true, option: false, control: false).isUsableHotKey)
    #expect(!KeyChord(keyCode: 5, command: false, shift: false, option: false, control: false).isUsableHotKey)
}

@Test(arguments: [UInt32(53), 54, 55, 56, 57, 58, 59, 60, 61, 62, 63])
func escapeAndModifierKeysAreNotChordKeys(code: UInt32) {
    #expect(!KeyChord(keyCode: code, command: true, shift: false, option: false, control: false).isUsableHotKey)
}

@Test func triggerTitles() {
    #expect(TriggerKey.allCases.map(\.title) == ["Right ⌥", "Right ⌘", "Right ⌃", "Right ⇧"])
}

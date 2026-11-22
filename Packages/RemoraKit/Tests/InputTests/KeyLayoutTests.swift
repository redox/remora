import Testing
@testable import Input

/// What each layout types with ⌘ held, for the keys that matter (ANSI key codes).
private let qwerty: [UInt16: String] = [0: "a", 9: "v", 11: "b", 12: "q", 13: "w", 47: ".", 40: "k"]
private let azerty: [UInt16: String] = [0: "q", 12: "a", 13: "z", 6: "w", 9: "v", 11: "b", 46: ","]
private let dvorak: [UInt16: String] = [0: "a", 9: "k", 47: "v", 12: "'", 40: "t"]
/// "Dvorak – QWERTY ⌘": Dvorak normally, QWERTY while ⌘ is down (the table is the ⌘ translation).
private let dvorakQwertyCommand = qwerty

@Test(arguments: [(qwerty, UInt16(0), UInt16(9)), (azerty, 12, 9), (dvorak, 0, 47), (dvorakQwertyCommand, 0, 9)])
func resolvesCommandKeysPerLayout(table: [UInt16: String], a: UInt16, v: UInt16) {
    #expect(KeyLayout.keyCode(typing: "a") { table[$0] } == a)
    #expect(KeyLayout.keyCode(typing: "v") { table[$0] } == v)
}

@Test func unresolvableLetterGivesNoKey() {
    let cyrillic: [UInt16: String] = [0: "ф", 9: "м"]
    #expect(KeyLayout.keyCode(typing: "v") { cyrillic[$0] } == nil)
    #expect(KeyLayout.keyCode(typing: "a") { _ in "A" } == nil)  // only an exact match counts
}

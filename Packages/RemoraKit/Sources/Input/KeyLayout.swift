/// Finds the virtual key code that types a character with ⌘ held, on the current layout.
/// Positional ANSI codes are wrong on other layouts (key code 0 is "q" on AZERTY: ⌘Q would quit
/// the app); translating with ⌘ also covers layouts such as "Dvorak – QWERTY ⌘" that switch to
/// QWERTY while ⌘ is down.
public enum KeyLayout {
    /// `translate` maps a key code to what it types with ⌘ held (nil when it types nothing).
    /// Returns the lowest key code whose output is exactly `character`, or nil (then no key must
    /// be synthesized).
    public static func keyCode(typing character: Character, translate: (UInt16) -> String?) -> UInt16? {
        (UInt16(0)..<128).first { translate($0) == String(character) }
    }
}

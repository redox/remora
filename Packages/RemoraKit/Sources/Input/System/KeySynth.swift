import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Posts ⌘V / ⌘A to the HID event tap. The key code is resolved from the current ASCII-capable
/// keyboard layout with ⌘ held (`KeyLayout`), never assumed positional: on AZERTY the ANSI "A"
/// key types "q", and ⌘Q would quit the app. When no key types the letter, nothing is posted.
/// A private event source keeps the user's physically held modifiers (e.g. the rewrite key
/// itself) from merging into the synthesized events.
public struct KeySynth: KeySynthesizing {
    public init() {}

    public func commandV() async -> Bool { await press("v") }
    public func commandA() async -> Bool { await press("a") }

    private func press(_ character: Character) async -> Bool {
        // Text Input Sources must be queried on the main thread.
        let code = await MainActor.run { Self.resolve(character) }
        guard let code else { return false }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    @MainActor private static func resolve(_ character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return KeyLayout.keyCode(typing: character) { code in
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), commandState, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, chars.count,
                                            &length, &chars)
                return status == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length) : nil
            }
        }
    }
}

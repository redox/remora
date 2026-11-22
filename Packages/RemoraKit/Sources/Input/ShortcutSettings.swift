import Foundation

/// The modifier key that acts as the rewrite key. Only right-hand keys: the left ones are
/// everyday modifiers.
public enum TriggerKey: String, Codable, Sendable, CaseIterable {
    case rightOption, rightCommand, rightControl, rightShift

    /// Virtual key code (`kVK_RightOption` etc.).
    public var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .rightShift: 60
        }
    }

    /// The device-dependent `NX_DEVICER*KEYMASK` bit in `modifierFlags.rawValue`.
    public var deviceMask: UInt {
        switch self {
        case .rightOption: 0x40
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        case .rightShift: 0x04
        }
    }

    /// The left-hand key of the same family (`NX_DEVICEL*KEYMASK`).
    var leftDeviceMask: UInt {
        switch self {
        case .rightOption: 0x20
        case .rightCommand: 0x08
        case .rightControl: 0x01
        case .rightShift: 0x02
        }
    }

    /// The device-independent flag of the family (`NSEvent.ModifierFlags` raw value).
    var familyFlag: UInt {
        switch self {
        case .rightOption: 0x80000
        case .rightCommand: 0x100000
        case .rightControl: 0x40000
        case .rightShift: 0x20000
        }
    }
}

/// A key plus modifiers, for a Carbon hot key.
public struct KeyChord: Codable, Sendable, Equatable {
    public var keyCode: UInt32
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool
    public init(keyCode: UInt32, command: Bool, shift: Bool, option: Bool, control: Bool) {
        self.keyCode = keyCode; self.command = command; self.shift = shift; self.option = option; self.control = control
    }
}

/// Settings › Shortcuts. Stored as JSON under `settingsKey`; missing keys decode to defaults.
public struct ShortcutSettings: Codable, Sendable, Equatable {
    public var rewriteKeyEnabled = true
    public var trigger: TriggerKey = .rightOption
    public var doubleTapRewrites = true
    public var holdOpensEdit = true
    /// Off by default: a system-wide Carbon hot key takes ⇧⌘G (Find Previous, Go to Folder) from every app.
    public var chordEnabled = false
    public var chord = KeyChord(keyCode: 5 /* kVK_ANSI_G */, command: true, shift: true, option: false, control: false)
    public var soundsEnabled = true

    public static let settingsKey = "input.shortcuts"

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case rewriteKeyEnabled, trigger, holdOpensEdit, chordEnabled, chord, soundsEnabled
        // Keep the existing on/off preference when the double-tap action changes.
        case doubleTapRewrites = "doubleTapOpensEdit"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShortcutSettings()
        rewriteKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .rewriteKeyEnabled) ?? d.rewriteKeyEnabled
        trigger = try c.decodeIfPresent(TriggerKey.self, forKey: .trigger) ?? d.trigger
        doubleTapRewrites = try c.decodeIfPresent(Bool.self, forKey: .doubleTapRewrites) ?? d.doubleTapRewrites
        holdOpensEdit = try c.decodeIfPresent(Bool.self, forKey: .holdOpensEdit) ?? d.holdOpensEdit
        chordEnabled = try c.decodeIfPresent(Bool.self, forKey: .chordEnabled) ?? d.chordEnabled
        chord = try c.decodeIfPresent(KeyChord.self, forKey: .chord) ?? d.chord
        soundsEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundsEnabled) ?? d.soundsEnabled
    }
}

public extension TriggerKey {
    /// The label Settings › Shortcuts shows for the key.
    var title: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .rightControl: "Right ⌃"
        case .rightShift: "Right ⇧"
        }
    }
}

public extension KeyChord {
    /// The modifiers as glyphs in Apple's menu order (⌃⌥⇧⌘).
    var modifierSymbols: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
    }

    /// Esc (kVK_Escape) and the modifier keys themselves (kVK_RightCommand … kVK_Function).
    private static let reservedKeyCodes: Set<UInt32> = [53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// A chord worth registering system-wide: it has ⌘, ⌃ or ⌥ (⇧ alone would eat typed
    /// capitals) and its key is neither Esc nor a modifier.
    var isUsableHotKey: Bool {
        (command || control || option) && !Self.reservedKeyCodes.contains(keyCode)
    }
}

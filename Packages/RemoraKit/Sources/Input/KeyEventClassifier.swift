import AppKit

/// Maps a monitored `NSEvent` to a `TapDetector.Input`. Pure (takes the event's fields).
public enum KeyEventClassifier {
    /// Device-independent modifier families that make a trigger press a chord.
    private static let families: [UInt] = [0x100000 /* ⌘ */, 0x40000 /* ⌃ */, 0x20000 /* ⇧ */, 0x80000 /* ⌥ */]

    /// `flags` is `modifierFlags.rawValue`. Caps Lock, Fn and numeric-pad flags are ignored.
    /// `mouseButtonsDown` (`NSEvent.pressedMouseButtons != 0`): a trigger pressed during a click or
    /// drag is a modifier (⌥-click, ⌥-drag). nil for events the detector does not care about.
    public static func classify(type: NSEvent.EventType, keyCode: UInt16, flags: UInt,
                                trigger: TriggerKey, mouseButtonsDown: Bool = false) -> TapDetector.Input? {
        switch type {
        case .flagsChanged:
            guard keyCode == trigger.keyCode else { return .otherModifier }
            guard flags & trigger.deviceMask != 0 else { return .triggerUp }
            let others = families.filter { $0 != trigger.familyFlag }.contains { flags & $0 != 0 }
            let leftHeld = flags & trigger.leftDeviceMask != 0
            return others || leftHeld || mouseButtonsDown ? .otherModifier : .triggerDown
        case .keyDown, .systemDefined:  // system-defined: media, brightness and volume keys
            return .otherKey
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            return .mouse
        default:
            return nil
        }
    }
}

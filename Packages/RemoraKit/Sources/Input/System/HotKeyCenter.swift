import AppKit
import Carbon.HIToolbox

/// System-wide hot keys through Carbon `RegisterEventHotKey` on the application event target.
/// A registered chord is consumed (the frontmost app never sees it) and needs no permission.
/// Used for the ⌘⇧G chord and for a transient Esc (keyCode 53, no modifiers) registered only while
/// a rewrite is working, so Esc cancels it without reaching the app.
@MainActor public final class HotKeyCenter {
    nonisolated static let signature: OSType = 0x524D_5241  // 'RMRA'

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var chords: [UInt32: KeyChord] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    public init() {}

    isolated deinit {
        for id in Array(refs.keys) { unregister(id: id) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Registers (or replaces) the hot key `id`. The new chord is registered before the old one is
    /// released, so on failure (e.g. the chord is taken by another app) the previous binding stays
    /// and this returns false.
    @discardableResult
    public func register(_ c: KeyChord, id: UInt32, handler: @escaping @MainActor () -> Void) -> Bool {
        guard installHandler() else { return false }
        if refs[id] != nil, chords[id] == c {
            handlers[id] = handler
            return true
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(c.keyCode, Self.carbonModifiers(c), EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        if let old = refs[id] { UnregisterEventHotKey(old) }
        refs[id] = ref
        chords[id] = c
        handlers[id] = handler
        return true
    }

    public func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        chords[id] = nil
        handlers[id] = nil
    }

    private static func carbonModifiers(_ c: KeyChord) -> UInt32 {
        var m = 0
        if c.command { m |= cmdKey }
        if c.shift { m |= shiftKey }
        if c.option { m |= optionKey }
        if c.control { m |= controlKey }
        return UInt32(m)
    }

    private func fire(_ id: UInt32) -> Bool {
        guard let handler = handlers[id] else { return false }
        handler()
        return true
    }

    private func installHandler() -> Bool {
        if eventHandler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard read == noErr, hotKey.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            // Carbon dispatches application-target events on the main thread.
            let handled = MainActor.assumeIsolated { center.fire(hotKey.id) }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        return status == noErr
    }
}

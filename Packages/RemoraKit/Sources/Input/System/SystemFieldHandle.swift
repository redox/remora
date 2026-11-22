import ApplicationServices
import Capture
import Foundation

/// `FieldHandle` over a live AX element. Every call runs with a fresh session, bounded by the
/// per-element messaging timeout set when the element was obtained: on the shared AX queue for
/// another app's field, on the main thread for Remora's own (see `FieldAXRoute`).
///
/// `@unchecked Sendable`: `AXUIElement` is an immutable CF reference to a remote element; all IPC
/// through it happens on the AX queue.
struct SystemFieldHandle: FieldHandle, @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let canSetValue: Bool
    let canSetSelectedText: Bool

    func value() -> String? {
        perform { $0.copyAttribute(element, kAXValueAttribute) as? String }
    }

    func selectedRange() -> NSRange? {
        perform { Self.selectedRange(element, $0) }
    }

    func setValue(_ s: String) -> Bool {
        perform { $0.setAttribute(element, kAXValueAttribute, s as CFString) }
    }

    func setSelectedRange(_ r: NSRange) -> Bool {
        var cf = CFRange(location: r.location, length: r.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return perform { $0.setAttribute(element, kAXSelectedTextRangeAttribute, value) }
    }

    func setSelectedText(_ s: String) -> Bool {
        perform { $0.setAttribute(element, kAXSelectedTextAttribute, s as CFString) }
    }

    func isFocused() -> Bool {
        perform { session in
            guard let focused = FocusedFieldReader.focusedElement(session) else { return false }
            return CFEqual(focused, element)
        }
    }

    func isFocusedInApp() -> Bool {
        perform { session in
            let app = AXUIElementCreateApplication(pid)
            AXReadSession.bound(app)
            guard let ref = session.copyAttribute(app, kAXFocusedUIElementAttribute),
                  CFGetTypeID(ref) == AXUIElementGetTypeID(), CFEqual(ref, element),
                  let role = session.copyAttribute(element, kAXRoleAttribute) as? String else { return false }
            let subrole = session.copyAttribute(element, kAXSubroleAttribute) as? String
            return !session.isUnresponsive && role != FieldRefusal.secureRole && subrole != FieldRefusal.secureRole
        }
    }

    private func perform<T>(_ work: (AXReadSession) -> T) -> T {
        switch FieldAXRoute.route(fieldPID: pid, ownPID: getpid()) {
        case .axQueue: AXQueue.sync(work)
        case .mainThread: MainThreadRunner.sync { work(AXReadSession()) }
        }
    }

    static func selectedRange(_ element: AXUIElement, _ session: AXReadSession) -> NSRange? {
        guard let ref = session.copyAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var cf = CFRange()
        // type id checked above
        guard AXValueGetValue(ref as! AXValue, .cfRange, &cf) else { return nil }
        return NSRange(location: cf.location, length: cf.length)
    }
}

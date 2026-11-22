import ApplicationServices
import Foundation
import Synchronization

/// Per-element IPC timeout. Keeps every AX call bounded, so a read abandoned by the engine
/// (hung target app) always returns eventually and clears the engine's in-flight guard.
public let axMessagingTimeout: Float = 0.25

/// Shared state for one read of the AX tree.
///
/// Once the read is cancelled (the engine gave up on it) or any call reports that the target
/// app is not responding, every further call short-circuits, so an abandoned or hung traversal
/// winds down in at most one more messaging timeout instead of one per remaining attribute.
public final class AXReadSession: Sendable {
    private struct State {
        var cancelled = false
        var unresponsive = false
    }
    private let state = Mutex(State())

    public init() {}

    public var isCancelled: Bool { state.withLock { $0.cancelled } }
    public var isUnresponsive: Bool { state.withLock { $0.unresponsive } }
    private var isStopped: Bool { state.withLock { $0.cancelled || $0.unresponsive } }

    public func cancel() { state.withLock { $0.cancelled = true } }

    /// Applies the project's per-element messaging timeout. Call it on every element before use.
    public static func bound(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
    }

    public func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard !isStopped else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return check(error) ? value : nil
    }

    func copyChildren(_ element: AXUIElement, max: Int) -> [AXUIElement] {
        guard !isStopped else { return [] }
        var values: CFArray?
        let error = AXUIElementCopyAttributeValues(
            element, kAXChildrenAttribute as CFString, 0, max, &values)
        guard check(error), let values else { return [] }
        return (values as? [AXUIElement]) ?? []
    }

    public func copyParameterizedAttribute(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        guard !isStopped else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value)
        return check(error) ? value : nil
    }

    public func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        guard !isStopped else { return false }
        var settable: DarwinBoolean = false
        return check(AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)) && settable.boolValue
    }

    /// True when the app reported the write as successful (which is not proof it took effect).
    public func setAttribute(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        guard !isStopped else { return false }
        return check(AXUIElementSetAttributeValue(element, attribute as CFString, value))
    }

    func setFlag(_ element: AXUIElement, _ attribute: String) {
        guard !isStopped else { return }
        _ = check(AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue))
    }

    /// `.cannotComplete` is what AX returns when the messaging timeout expires.
    private func check(_ error: AXError) -> Bool {
        if error == .cannotComplete { state.withLock { $0.unresponsive = true } }
        return error == .success
    }
}

/// Live `AXNode` backed by an `AXUIElement`.
///
/// Every attribute (and `children`) is fetched over IPC only when the property is read, so
/// the extractor never reads the value of a secure field it decided to skip, nor the children
/// of a node it will not descend into. Nothing is cached: the extractor reads each property
/// at most once per node.
///
/// `@unchecked Sendable`: `AXUIElement` is an immutable CF reference to a remote element and
/// is safe to pass between threads; all IPC through it happens on the reader's serial AX
/// queue, never on the Swift cooperative pool.
public struct SystemAXNode: AXNode, @unchecked Sendable {
    /// Upper bound on children fetched per node; the extractor's own node cap stays the
    /// real limit, this only stops a pathological list from being copied whole.
    static let maxChildren = 2_000

    let element: AXUIElement
    let session: AXReadSession

    public init(_ element: AXUIElement) {
        self.init(element, session: AXReadSession())
    }

    init(_ element: AXUIElement, session: AXReadSession) {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        self.element = element
        self.session = session
    }

    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
    public var value: String? { string(kAXValueAttribute) }
    public var title: String? { string(kAXTitleAttribute) }
    public var nodeDescription: String? { string(kAXDescriptionAttribute) }

    public var children: [any AXNode] { childNodes }

    var childNodes: [SystemAXNode] {
        session.copyChildren(element, max: Self.maxChildren).map { SystemAXNode($0, session: session) }
    }

    func string(_ attribute: String) -> String? {
        session.copyAttribute(element, attribute) as? String
    }

    func url(_ attribute: String) -> URL? {
        switch session.copyAttribute(element, attribute) {
        case let url as URL: url
        case let string as String: URL(string: string)
        default: nil
        }
    }

    func bool(_ attribute: String) -> Bool? {
        (session.copyAttribute(element, attribute) as? NSNumber)?.boolValue
    }

    func point(_ attribute: String) -> CGPoint? {
        guard let ref = session.copyAttribute(element, attribute),
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        // type id checked above
        return AXValueGetValue(ref as! AXValue, .cgPoint, &point) ? point : nil
    }

    func size(_ attribute: String) -> CGSize? {
        guard let ref = session.copyAttribute(element, attribute),
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(ref as! AXValue, .cgSize, &size) ? size : nil  // type id checked above
    }

    func element(_ attribute: String) -> SystemAXNode? {
        guard let ref = session.copyAttribute(element, attribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return SystemAXNode(ref as! AXUIElement, session: session)  // type id checked above
    }
}

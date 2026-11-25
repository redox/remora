import AppKit
import ApplicationServices
import Capture
import os

/// Reads the system-wide focused element for the rewrite key.
///
/// All AX IPC runs on the shared AX queue (`AXQueue`), each call bounded by the 0.25 s messaging
/// timeout. Refusals are decided from the element's identity before any of its text is read:
/// Remora's own UI, password managers and secure (password) fields are never read. Field text is
/// never logged.
public struct FocusedFieldReader: Sendable {
    private static let log = Logger(subsystem: "dev.remora", category: "input")
    private let ownBundleID: String?

    public init() { ownBundleID = Bundle.main.bundleIdentifier }

    /// Remora's own focused field is read only when this holds: the onboarding practice box
    /// (`FieldRefusal.practiceFieldIdentifier`).
    public static func allowsOwnApp(identifier: String?) -> Bool { FieldRefusal.allowsOwnApp(identifier: identifier) }

    /// The focused field, or nil when nothing usable is focused or it is refused.
    public func read() async -> FocusedField? { await readField().field }

    /// The focused field or why it was refused.
    public func readField(includeWindowIdentity: Bool = false, includeSelectionBounds: Bool = false) async -> FocusedFieldRead {
        let own = ownBundleID
        let result = try? await AXQueue.run(qos: .userInitiated) { session in
            Self.read(session, ownBundleID: own, includeWindowIdentity: includeWindowIdentity,
                      includeSelectionBounds: includeSelectionBounds)
        }
        let read = result ?? .refused(.notResponding)
        if case .refused(let reason) = read { Self.log.info("focused field refused: \(String(describing: reason), privacy: .public)") }
        return read
    }

    /// The system-wide focused element, with the messaging timeout applied (AX queue only).
    /// Applying it to the system-wide element sets the process-wide default to the same 0.25 s.
    static func focusedElement(_ session: AXReadSession) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXReadSession.bound(systemWide)
        guard let ref = session.copyAttribute(systemWide, kAXFocusedUIElementAttribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement  // type id checked above
        AXReadSession.bound(element)
        return element
    }

    // MARK: - AX queue only

    private static func read(_ s: AXReadSession, ownBundleID: String?, includeWindowIdentity: Bool,
                             includeSelectionBounds: Bool) -> FocusedFieldRead {
        let frontmost = NSWorkspace.shared.frontmostApplication
        // A freshly launched Electron/Chromium app has no AX tree (so no focused field) until its
        // flags are set; capture may be paused and never have set them.
        if let frontmost, frontmost.processIdentifier != getpid() { AppAccessibility.enable(frontmost, session: s) }
        guard let element = focusedElement(s) else {
            return .refused(s.isUnresponsive ? .notResponding : .noFocusedElement)
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return .refused(.noFocusedElement) }
        // Remora's own field is read in-process, where AppKit requires the main thread.
        switch FieldAXRoute.route(fieldPID: pid, ownPID: getpid()) {
        case .axQueue:
            return describe(element, pid: pid, frontmost: frontmost, ownBundleID: ownBundleID,
                            includeWindowIdentity: includeWindowIdentity, includeSelectionBounds: includeSelectionBounds, s)
        case .mainThread:
            return MainThreadRunner.sync {
                describe(element, pid: pid, frontmost: frontmost, ownBundleID: ownBundleID,
                         includeWindowIdentity: false, includeSelectionBounds: includeSelectionBounds, s)
            }
        }
    }

    private static func describe(_ element: AXUIElement, pid: pid_t, frontmost: NSRunningApplication?,
                                 ownBundleID: String?, includeWindowIdentity: Bool, includeSelectionBounds: Bool,
                                 _ s: AXReadSession) -> FocusedFieldRead {
        let app = NSRunningApplication(processIdentifier: pid)
        // Only Remora's own elements need their identifier (the practice field exception); it is
        // an attribute name, not text.
        let identifier = pid == getpid() ? s.copyAttribute(element, kAXIdentifierAttribute) as? String : nil
        func refusal(role: String?, subrole: String?) -> FieldRefusal? {
            FieldRefusal.check(fieldBundleID: app?.bundleIdentifier, fieldPID: pid,
                               frontmostBundleID: frontmost?.bundleIdentifier, ownPID: getpid(),
                               ownBundleID: ownBundleID, role: role, subrole: subrole, identifier: identifier)
        }
        if let r = refusal(role: nil, subrole: nil) { return .refused(r) }
        let role = s.copyAttribute(element, kAXRoleAttribute) as? String
        let subrole = s.copyAttribute(element, kAXSubroleAttribute) as? String
        if let r = refusal(role: role, subrole: subrole) { return .refused(r) }

        let value = s.copyAttribute(element, kAXValueAttribute) as? String
        let selection = SystemFieldHandle.selectedRange(element, s)
        let selectedText = s.copyAttribute(element, kAXSelectedTextAttribute) as? String
        let placeholder = s.copyAttribute(element, kAXPlaceholderValueAttribute) as? String
        let frame = frame(element, s)
        let caret = selection.flatMap { caretRect(element, $0, value, s) }
        let canSetValue = s.isSettable(element, kAXValueAttribute)
        let canSetSelectedText = s.isSettable(element, kAXSelectedTextAttribute)
        if s.isUnresponsive || s.isCancelled { return .refused(.notResponding) }
        guard value != nil || selectedText != nil || selection != nil else { return .refused(.noFocusedElement) }

        let bundleID = app?.bundleIdentifier, bundleURL = app?.bundleURL
        let source: (window: Int, page: URL?)?
        if includeWindowIdentity, role != nil, (selection?.length ?? 0) > 0 || selectedText?.isEmpty == false {
            source = selectionSource(for: element, browser: BrowserCatalog.isBrowser(bundleID), session: s)
        } else {
            source = nil
        }
        let localized = app?.localizedName.map(AppName.normalize) ?? ""
        let handle = SystemFieldHandle(element: element, pid: pid, canSetValue: canSetValue,
                                       canSetSelectedText: canSetSelectedText)
        let hasSelectedText = selectedText?.isEmpty == false
        let hasSelection = (selection?.length ?? 0) > 0 || hasSelectedText
        let tryWebMarkers = role == "AXWebArea" || hasSelectedText || (caret == nil && BrowserCatalog.isBrowser(bundleID))
        let bounds = includeSelectionBounds ? textBounds(element, range: selection, tryWebMarkers: tryWebMarkers, s) : nil
        // A browser's marker range can describe the insertion point even when the focused
        // element provides no range-based caret. Collapsed bounds can be zero pixels wide.
        let markerCaret: CGRect? = if !hasSelection, let bounds, bounds.width <= CaretGeometry.caretWidth {
            CaretGeometry.caret(beforeRect: nil, beforeChar: nil, atRect: nil, atChar: nil, zeroRect: bounds)
        } else {
            nil
        }
        let canHaveSelectionBounds = hasSelection || (selection == nil && role == "AXWebArea")
        let selectionBounds = canHaveSelectionBounds && markerCaret == nil && bounds?.isEmpty == false ? bounds : nil
        if s.isUnresponsive || s.isCancelled { return .refused(.notResponding) }
        return .field(FocusedField(
            handle: handle, value: value, selection: selection, selectedText: selectedText, placeholder: placeholder,
            role: role, isSecure: false, frame: frame, caretRect: caret ?? markerCaret,
            app: localized.isEmpty ? (bundleID ?? "Unknown") : localized, bundleID: bundleID, bundleURL: bundleURL,
            isWebBacked: AppKind.isWebBacked(bundleID: bundleID, bundleURL: bundleURL), windowIdentity: source?.window,
            selectionPageURL: source?.page, selectionBounds: selectionBounds))
    }

    private static func relatedElement(_ element: AXUIElement, _ attribute: String, _ s: AXReadSession) -> AXUIElement? {
        guard let ref = s.copyAttribute(element, attribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let related = ref as! AXUIElement  // type id checked above
        AXReadSession.bound(related)
        return related
    }

    /// Read-only elements sometimes expose their window only through their parents. In browsers,
    /// also verify the web area so a frame or sidebar cannot inherit the main page's permissions.
    private static func selectionSource(for field: AXUIElement, browser: Bool,
                                        session: AXReadSession) -> (window: Int, page: URL?)? {
        let window = relatedElement(field, kAXWindowAttribute, session)
        if !browser, let window, !session.isUnresponsive, !session.isCancelled {
            return (Int(bitPattern: CFHash(window)), nil)
        }
        var node = field
        var page: URL?
        for _ in 0..<24 {
            guard let role = session.copyAttribute(node, kAXRoleAttribute) as? String else { return nil }
            if role == kAXWindowRole {
                guard !browser || page != nil, window.map({ CFEqual(node, $0) }) ?? true else { return nil }
                return (Int(bitPattern: CFHash(node)), page)
            }
            if browser, role == "AXWebArea" {
                let value = session.copyAttribute(node, kAXURLAttribute)
                let url = value as? URL ?? (value as? String).flatMap { URL(string: $0) }
                guard let url, page == nil || page == url else { return nil }
                page = url
            }
            guard let parent = relatedElement(node, kAXParentAttribute, session) else { return nil }
            node = parent
        }
        return nil
    }

    private static func frame(_ element: AXUIElement, _ s: AXReadSession) -> CGRect? {
        guard let origin = axValue(s.copyAttribute(element, kAXPositionAttribute), .cgPoint, CGPoint.zero),
              let size = axValue(s.copyAttribute(element, kAXSizeAttribute), .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func textBounds(_ element: AXUIElement, range: NSRange?, tryWebMarkers: Bool,
                                   _ s: AXReadSession) -> CGRect? {
        if let range, range.length > 0, let rect = bounds(element, range: range, s), !rect.isEmpty {
            return rect
        }
        // Chromium and WebKit can expose the document selection as opaque text markers.
        guard tryWebMarkers, let markers = s.copyAttribute(element, "AXSelectedTextMarkerRange") else { return nil }
        return axValue(s.copyParameterizedAttribute(element, "AXBoundsForTextMarkerRange", markers), .cgRect, CGRect.zero)
    }

    private static func bounds(_ element: AXUIElement, range: NSRange, _ s: AXReadSession) -> CGRect? {
        guard range.location >= 0, range.location != NSNotFound else { return nil }
        var cf = CFRange(location: range.location, length: range.length)
        guard let param = AXValueCreate(.cfRange, &cf) else { return nil }
        return axValue(s.copyParameterizedAttribute(element, kAXBoundsForRangeParameterizedAttribute, param),
                       .cgRect, CGRect.zero)
    }

    /// A thin rect at the insertion point (see `CaretGeometry`); nil when the app reports no usable
    /// bounds (the caller falls back to the field's frame).
    private static func caretRect(_ element: AXUIElement, _ selection: NSRange, _ value: String?,
                                  _ s: AXReadSession) -> CGRect? {
        let text = value as NSString?
        let loc = selection.location
        func char(_ r: NSRange) -> Character? {
            guard let text, r.length > 0, r.location >= 0, NSMaxRange(r) <= text.length else { return nil }
            return text.substring(with: r).first
        }
        func bounds(_ location: Int, _ length: Int) -> CGRect? {
            guard let rect = Self.bounds(element, range: NSRange(location: location, length: length), s),
                  rect.width > 0 || rect.height > 0 else { return nil }
            return rect
        }
        var beforeRange = NSRange(location: max(loc - 1, 0), length: loc > 0 ? 1 : 0)
        if loc > 0, let text, loc <= text.length { beforeRange = text.rangeOfComposedCharacterSequence(at: loc - 1) }
        let beforeChar = loc > 0 ? char(beforeRange) : nil
        let atChar = char(NSRange(location: loc, length: 1))
        let beforeRect = beforeChar != nil ? bounds(beforeRange.location, beforeRange.length) : nil
        let atRect = atChar != nil ? bounds(loc, 1) : nil
        if let r = CaretGeometry.caret(beforeRect: beforeRect, beforeChar: beforeChar, atRect: atRect, atChar: atChar) {
            return r
        }
        let zero = bounds(loc, 0)
        if let r = CaretGeometry.caret(beforeRect: nil, beforeChar: nil, atRect: nil, atChar: nil, zeroRect: zero) {
            return r
        }
        // A non-nil zero-range rect can still be unusably wide. Try the line in that case too.
        return CaretGeometry.caret(beforeRect: nil, beforeChar: nil, atRect: nil, atChar: nil,
                                   lineRect: lineRect(element, loc, s))
    }

    private static func lineRect(_ element: AXUIElement, _ location: Int, _ s: AXReadSession) -> CGRect? {
        guard let n = s.copyParameterizedAttribute(element, kAXLineForIndexParameterizedAttribute, location as CFNumber),
              let line = (n as? NSNumber)?.intValue,
              let rangeRef = s.copyParameterizedAttribute(element, kAXRangeForLineParameterizedAttribute, line as CFNumber),
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var cf = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &cf),  // type id checked above
              let param = AXValueCreate(.cfRange, &cf),
              let rect = axValue(s.copyParameterizedAttribute(element, kAXBoundsForRangeParameterizedAttribute, param),
                                 .cgRect, CGRect.zero), rect.height > 0 else { return nil }
        return rect
    }

    private static func axValue<T: BitwiseCopyable>(_ ref: CFTypeRef?, _ type: AXValueType, _ initial: T) -> T? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var out = initial
        return AXValueGetValue(ref as! AXValue, type, &out) ? out : nil  // type id checked above
    }
}

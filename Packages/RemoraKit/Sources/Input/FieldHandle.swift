import Capture
import CoreGraphics
import Foundation

/// A focused text element. Calls are synchronous AX IPC (bounded by the messaging timeout): call
/// them off the main thread. Ranges are UTF-16.
public protocol FieldHandle: Sendable {
    var pid: pid_t { get }
    func value() -> String?
    func selectedRange() -> NSRange?
    func setValue(_ s: String) -> Bool
    func setSelectedRange(_ r: NSRange) -> Bool
    func setSelectedText(_ s: String) -> Bool
    var canSetValue: Bool { get }
    var canSetSelectedText: Bool { get }
    /// Still the system-wide focused element.
    func isFocused() -> Bool
    /// Still the app's focused, non-secure element while a non-activating panel owns the keyboard.
    func isFocusedInApp() -> Bool
}

extension FieldHandle {
    public func isFocusedInApp() -> Bool { isFocused() }
}

/// A snapshot of the focused field when the rewrite key fired.
public struct FocusedField: Sendable {
    public var handle: any FieldHandle
    public var value: String?
    public var selection: NSRange?
    public var selectedText: String?
    public var placeholder: String?
    public var role: String?
    public var isSecure: Bool
    /// AX coordinates (top-left origin); see `ScreenGeometry`.
    public var frame: CGRect?
    /// Bounds of the insertion point in AX screen coordinates, when available.
    public var caretRect: CGRect?
    /// Bounds of the highlighted text, in AX screen coordinates, when available.
    public var selectionBounds: CGRect?
    public var app: String
    public var bundleID: String?
    public var bundleURL: URL?
    public var isWebBacked: Bool
    /// Used to tie a manual note to the exact window whose capture policy was checked.
    public var windowIdentity: Int?
    /// The verified web area containing a selection in a browser.
    public var selectionPageURL: URL?

    public init(handle: any FieldHandle, value: String?, selection: NSRange?, selectedText: String?, placeholder: String?,
                role: String?, isSecure: Bool, frame: CGRect?, caretRect: CGRect?, app: String, bundleID: String?,
                bundleURL: URL?, isWebBacked: Bool, windowIdentity: Int? = nil, selectionPageURL: URL? = nil,
                selectionBounds: CGRect? = nil) {
        self.handle = handle; self.value = value; self.selection = selection; self.selectedText = selectedText
        self.placeholder = placeholder; self.role = role; self.isSecure = isSecure; self.frame = frame
        self.caretRect = caretRect; self.app = app; self.bundleID = bundleID; self.bundleURL = bundleURL
        self.isWebBacked = isWebBacked
        self.windowIdentity = windowIdentity
        self.selectionPageURL = selectionPageURL
        self.selectionBounds = selectionBounds
    }

    /// Some editors expose only a selected UTF-16 range, others only AXSelectedText.
    private var selectedExcerpt: String? {
        // A read-only document can expose selected text without an editable range.
        if role == "AXWebArea" || role == "AXStaticText", let selectedText, !selectedText.isEmpty {
            return selectedText
        }
        if selection?.length == 0 { return nil }
        if let selectedText, !selectedText.isEmpty { return selectedText }
        guard let selection, selection.length > 0, let value, let range = Range(selection, in: value)
        else { return nil }
        return String(value[range])
    }

    public func verifiedExcerpt(in source: FrontmostWindowReader.ContextSample) -> String? {
        guard !isSecure, let windowIdentity, source.identity.window == windowIdentity,
              source.identity.pid == handle.pid, source.context.bundleID == bundleID else { return nil }
        if BrowserCatalog.isBrowser(bundleID) {
            guard let selectionPageURL, selectionPageURL == source.context.url else { return nil }
        }
        return selectedExcerpt
    }
}

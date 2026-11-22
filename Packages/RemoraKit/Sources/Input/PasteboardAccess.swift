import Foundation

/// One type of a pasteboard item and its raw data.
public struct PasteboardEntry: Sendable, Equatable {
    public var type: String
    public var data: Data
    public init(type: String, data: Data) { self.type = type; self.data = data }
}

/// Every item of a pasteboard with every type's raw data, items and types in order (apps pick the
/// first type they understand, so order is part of the contents).
public struct PasteboardContents: Sendable, Equatable {
    public var items: [[PasteboardEntry]]
    public init(items: [[PasteboardEntry]]) { self.items = items }
}

public protocol PasteboardAccess: Sendable {
    var changeCount: Int { get }
    func snapshot() -> PasteboardContents
    /// Replaces the contents with `text`; returns the new change count.
    func write(text: String) -> Int
    /// Replaces the contents with `c`; returns the new change count.
    func restore(_ c: PasteboardContents) -> Int
}

/// ⌘V / ⌘A as keystrokes. False when the key could not be resolved for the current layout (then
/// nothing was posted).
public protocol KeySynthesizing: Sendable {
    func commandV() async -> Bool
    func commandA() async -> Bool
}

public protocol AppActivating: Sendable {
    func frontmostPID() -> pid_t?
    /// Activates the app and waits up to 500 ms for it to become frontmost.
    func activate(pid: pid_t) async -> Bool
}

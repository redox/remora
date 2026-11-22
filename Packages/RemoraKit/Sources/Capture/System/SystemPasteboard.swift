import AppKit

/// `PasteboardReading` over the general pasteboard. Stateless: each call reads
/// `NSPasteboard.general` afresh, so the value itself is trivially `Sendable`.
public struct SystemPasteboard: PasteboardReading {
    public init() {}

    public var changeCount: Int { NSPasteboard.general.changeCount }

    public func string() -> String? { NSPasteboard.general.string(forType: .string) }

    public func types() -> [String] { NSPasteboard.general.types?.map(\.rawValue) ?? [] }
}

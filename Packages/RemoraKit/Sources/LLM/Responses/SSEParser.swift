import Foundation

public struct SSEMessage: Sendable, Equatable {
    public var event: String?
    public var data: String
    public init(event: String?, data: String) { self.event = event; self.data = data }
}

public struct SSEParser: Sendable {
    private var event: String?
    private var dataLines: [String] = []
    private var dataBytes = 0

    /// An event's accumulated `data` may not exceed this; past it the parser sets `overflowed`.
    public static let maxEventBytes = 8 * 1024 * 1024
    /// Set once a single event outgrew `maxEventBytes`. The caller must stop reading the stream.
    public private(set) var overflowed = false

    public init() {}

    public mutating func feed(line rawLine: String) -> [SSEMessage] {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return [] }
        let field: String, value: String
        if let i = line.firstIndex(of: ":") {
            field = String(line[..<i])
            var v = line[line.index(after: i)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            value = String(v)
        } else { field = line; value = "" }
        switch field {
        case "data":
            dataBytes += value.utf8.count + 1
            if dataBytes > Self.maxEventBytes {
                overflowed = true
                dataLines = []
            } else if !overflowed {
                dataLines.append(value)
            }
        case "event": event = value
        default: break
        }
        return []
    }

    public mutating func finish() -> [SSEMessage] { flush() }

    private mutating func flush() -> [SSEMessage] {
        defer { event = nil; dataLines = []; dataBytes = 0 }
        guard !overflowed, !dataLines.isEmpty else { return [] }
        return [SSEMessage(event: event, data: dataLines.joined(separator: "\n"))]
    }
}

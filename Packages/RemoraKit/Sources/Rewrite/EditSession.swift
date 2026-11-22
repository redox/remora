import Foundation

/// Tracks which part of a field an Edit-mode conversation is rewriting across rounds. All ranges are UTF-16.
public struct EditSession: Sendable, Equatable {
    public private(set) var target: NSRange
    public private(set) var lastWritten: String
    private var history: [(value: String, target: NSRange)] = []

    /// `target` is the selection (clamped to the value), or the whole value when there is no
    /// selection or it is empty. Throws `.selectionOutOfBounds` for a non-empty selection that
    /// lies wholly outside the value.
    public init(value: String, selection: NSRange?) throws(RewriteError) {
        lastWritten = value
        target = try Self.initialTarget(value, selection)
    }

    public var canUndo: Bool { !history.isEmpty }

    public static func == (a: EditSession, b: EditSession) -> Bool {
        a.target == b.target && a.lastWritten == b.lastWritten
            && a.history.map(\.value) == b.history.map(\.value) && a.history.map(\.target) == b.history.map(\.target)
    }

    public func targetText(in currentValue: String) -> String {
        let ns = currentValue as NSString
        return ns.substring(with: Self.clamp(target, to: ns.length))
    }

    /// Replaces the target with `result` and returns the new whole value.
    public mutating func didWrite(result: String, into currentValue: String) -> String {
        let ns = currentValue as NSString
        let range = Self.clamp(target, to: ns.length)
        history.append((currentValue, target))
        let newValue = ns.replacingCharacters(in: range, with: result)
        target = NSRange(location: range.location, length: result.utf16.count)
        lastWritten = newValue
        return newValue
    }

    /// The whole value before the last write, or nil when there is nothing to undo.
    public mutating func undo() -> String? {
        guard let last = history.popLast() else { return nil }
        target = last.target
        lastWritten = last.value
        return last.value
    }

    /// Called at each round: when the user edited the field since our last write, start over.
    /// Line-ending (CRLF/CR → LF) and trailing-whitespace differences are the app normalising our
    /// write, not a user edit: the target is carried over into the app's code units instead.
    public mutating func resync(currentValue: String, selection: NSRange?) throws(RewriteError) {
        guard currentValue != lastWritten else { return }
        let before = NormalizedText(lastWritten), now = NormalizedText(currentValue)
        if before.units == now.units {
            target = now.rawRange(normalized: before.normalizedRange(raw: target))
            lastWritten = currentValue
            return
        }
        target = try Self.initialTarget(currentValue, selection)
        history.removeAll()
        lastWritten = currentValue
    }

    private static func initialTarget(_ value: String, _ selection: NSRange?) throws(RewriteError) -> NSRange {
        try SelectionRange.nonEmpty(selection, in: value) ?? NSRange(location: 0, length: value.utf16.count)
    }

    private static func clamp(_ r: NSRange, to length: Int) -> NSRange { SelectionRange.clamp(r, to: length) }
}

/// A value with line endings folded to LF and trailing spaces/tabs removed from each line, plus
/// the raw UTF-16 span each kept unit came from (to map ranges between the two forms).
struct NormalizedText {
    private(set) var units: [UInt16] = []
    private var rawStart: [Int] = []
    private var rawEnd: [Int] = []
    private let rawCount: Int

    init(_ s: String) {
        let raw = Array(s.utf16)
        rawCount = raw.count
        let lf: UInt16 = 0x0A, cr: UInt16 = 0x0D
        var lineStart = 0
        var i = 0
        while i < raw.count {
            let u = raw[i]
            if u == lf || u == cr {
                trimTrailing(after: lineStart)
                let end = (u == cr && i + 1 < raw.count && raw[i + 1] == lf) ? i + 2 : i + 1
                append(lf, start: i, end: end)
                lineStart = units.count
                i = end
            } else {
                append(u, start: i, end: i + 1)
                i += 1
            }
        }
        trimTrailing(after: lineStart)
    }

    private mutating func append(_ u: UInt16, start: Int, end: Int) {
        units.append(u); rawStart.append(start); rawEnd.append(end)
    }

    private mutating func trimTrailing(after lineStart: Int) {
        while units.count > lineStart, let last = units.last, last == 0x20 || last == 0x09 {
            units.removeLast(); rawStart.removeLast(); rawEnd.removeLast()
        }
    }

    /// Raw range → normalized range (units whose raw span starts inside the range).
    func normalizedRange(raw r: NSRange) -> NSRange {
        let lower = rawStart.partitioningIndex { $0 >= r.location }
        let upper = rawStart.partitioningIndex { $0 >= r.location + r.length }
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    /// Normalized range → raw range covering exactly the kept units.
    func rawRange(normalized r: NSRange) -> NSRange {
        let start = r.location < units.count ? rawStart[r.location] : rawCount
        guard r.length > 0 else { return NSRange(location: start, length: 0) }
        return NSRange(location: start, length: rawEnd[r.location + r.length - 1] - start)
    }
}

private extension Array where Element == Int {
    /// First index whose element satisfies `p` (elements are ascending), or `count`.
    func partitioningIndex(where p: (Int) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if p(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

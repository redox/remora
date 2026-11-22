import Foundation

/// UTF-16 range helpers shared by the engine, the prompt and the Edit session.
enum SelectionRange {
    /// The intersection of `r` with `0..<length`, overflow-safe (an `NSNotFound` location clamps to the end).
    static func clamp(_ r: NSRange, to length: Int) -> NSRange {
        let lower = min(max(r.location, 0), length)
        let (end, overflow) = r.location.addingReportingOverflow(max(r.length, 0))
        let upper = overflow ? length : min(max(end, lower), length)
        return NSRange(location: lower, length: upper - lower)
    }

    /// A non-empty selection clamped to the value. nil for no selection or an empty one (a caret).
    /// Throws `.selectionOutOfBounds` when a non-empty selection lies wholly outside the value, so a
    /// stale selection is never silently turned into an insertion or widened to the whole field.
    static func nonEmpty(_ selection: NSRange?, in value: String) throws(RewriteError) -> NSRange? {
        guard let selection, selection.length > 0 else { return nil }
        let clamped = clamp(selection, to: value.utf16.count)
        guard clamped.length > 0 else { throw .selectionOutOfBounds }
        return clamped
    }
}

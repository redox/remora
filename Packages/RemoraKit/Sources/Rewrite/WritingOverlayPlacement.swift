import Capture
import CoreGraphics
import Input
import os

/// Screen-space geometry shared by the writing popover, progress badge and notices.
/// All stored rectangles use Cocoa coordinates. A document proxy may be smaller than its caret.
public struct WritingOverlayPlacement {
    enum Surface: String {
        case composer, selection, googleDocs, terminal

        init(bundleID: String?, role: String?, hasSelection: Bool, context: WindowContext?) {
            if FocusedField.isGhosttySurface(bundleID: bundleID, role: role) { self = .terminal }
            else if RewriteFlow.isGoogleDocsEditor(context) { self = .googleDocs }
            else if hasSelection || role == "AXWebArea" { self = .selection }
            else { self = .composer }
        }
    }

    enum AnchorSource: String { case selection, documentCaret, caret, pointer, paneCentre, field }

    private let surface: Surface
    private let field: CGRect?
    private let selection: CGRect?
    private let caret: (rect: CGRect, source: AnchorSource)?

    public init(field focused: FocusedField?, context: WindowContext? = nil, googleDocsCaret: CGRect? = nil,
                primaryScreenHeight: CGFloat) {
        func cocoa(_ rect: CGRect?) -> CGRect? {
            rect.map { ScreenGeometry.cocoaRect(fromAX: $0, primaryScreenHeight: primaryScreenHeight) }
        }
        let hasSelection = (focused?.selection?.length ?? 0) > 0 || focused?.selectedText?.isEmpty == false
        let surface = Surface(bundleID: focused?.bundleID, role: focused?.role, hasSelection: hasSelection, context: context)
        self.init(surface: surface, field: cocoa(focused?.frame), selection: cocoa(focused?.selectionBounds),
                  caret: cocoa(focused?.caretRect), verifiedCaret: cocoa(googleDocsCaret))
    }

    init(surface: Surface, field: CGRect?, selection: CGRect?, caret: CGRect?, verifiedCaret: CGRect? = nil) {
        let field = Self.usable(field)
        func textBounds(_ rect: CGRect?) -> CGRect? {
            guard let rect = Self.usable(rect),
                  field.map({ $0.intersects(rect) && !rect.contains($0) }) ?? true else { return nil }
            return rect
        }
        self.surface = surface
        self.field = field
        self.selection = textBounds(selection)
        if surface == .googleDocs, let verified = Self.usable(verifiedCaret) {
            self.caret = (verified, .documentCaret)
        } else {
            self.caret = textBounds(caret).map { ($0, .caret) }
        }
    }

    private static func usable(_ rect: CGRect?) -> CGRect? {
        guard let rect, !rect.isEmpty, !rect.isInfinite, rect.midX.isFinite, rect.midY.isFinite else { return nil }
        return rect
    }

    private func fallbackPoint(_ pointer: CGPoint, within pane: CGRect?) -> CGPoint {
        guard let pane, !pane.contains(pointer) else { return pointer }
        return CGPoint(x: pane.midX, y: pane.midY)
    }

    func resolveAnchor(pointer: CGPoint, fitsBesideField: (CGRect) -> Bool = { _ in true })
        -> (rect: CGRect, source: AnchorSource) {
        if let selection { return (selection, .selection) }
        func near(_ point: CGPoint, source: AnchorSource) -> (CGRect, AnchorSource) {
            let width = Self.minimumBarWidth
            return (CGRect(x: point.x - width / 2, y: point.y - 12, width: width, height: 24), source)
        }
        switch surface {
        case .terminal, .googleDocs:
            break
        case .selection where field?.contains(pointer) == true:
            return near(pointer, source: .pointer)
        case .selection where caret != nil:
            break
        case .composer, .selection:
            if let field, fitsBesideField(field) { return (field, .field) }
        }
        if let caret { return caret }
        if surface != .googleDocs, let field, !field.contains(pointer) {
            return near(CGPoint(x: field.midX, y: field.midY), source: .paneCentre)
        }
        return near(pointer, source: .pointer)
    }

    #if DEBUG
    private static let log = Logger(subsystem: "dev.remora", category: "rewrite")
    #endif

    public static let minimumBarWidth: CGFloat = 480

    /// The same measured height determines both whether a composer can serve as an anchor
    /// and which side of the final anchor has room. A panel may grow after the user types.
    public func editBarFrame(pointer: CGPoint, height: CGFloat, visibleFrame: (CGRect) -> CGRect) -> CGRect {
        func frame(at anchor: CGRect) -> CGRect {
            RewriteFlow.editBarFrame(field: anchor, height: height, visible: visibleFrame(anchor))
        }
        let anchor = resolveAnchor(pointer: pointer) { field in !frame(at: field).intersects(field) }
        #if DEBUG
        Self.log.notice("writing placement surface=\(surface.rawValue, privacy: .public) anchor=\(anchor.source.rawValue, privacy: .public)")
        #endif
        return frame(at: anchor.rect)
    }

    /// Without a caret, place small overlays at the leading edge of an ordinary field.
    /// A terminal pane covers many rows, so its fallback follows the same point as the popover.
    public func indicatorAnchor(pointer: CGPoint) -> CGRect {
        if let caret { return caret.rect }
        if let bounds = selection ?? (surface == .terminal ? nil : field) {
            let height = min(bounds.height, 20)
            return CGRect(x: bounds.minX, y: bounds.maxY - height, width: 0, height: height)
        }
        let point = fallbackPoint(pointer, within: surface == .terminal ? field : nil)
        return CGRect(origin: point, size: CGSize(width: 1, height: 16))
    }
}

extension RewriteFlow {
    public static func editBarAnchor(field: CGRect?, selection: CGRect?, caret: CGRect?,
                                     preferNearbyPointer: Bool, pointer: CGPoint, context: WindowContext? = nil,
                                     googleDocsCaret: CGRect? = nil) -> CGRect {
        let surface = WritingOverlayPlacement.Surface(bundleID: context?.bundleID, role: "AXTextArea",
                                                      hasSelection: preferNearbyPointer, context: context)
        return WritingOverlayPlacement(surface: surface, field: field, selection: selection, caret: caret,
                                       verifiedCaret: googleDocsCaret).resolveAnchor(pointer: pointer).rect
    }

    /// The Edit bar: 8 pt from its anchor, preferring above when it fits, kept on screen.
    public static func editBarFrame(field: CGRect, height: CGFloat, visible: CGRect) -> CGRect {
        let height = min(height, visible.height)
        let width = min(max(field.width, WritingOverlayPlacement.minimumBarWidth), 560, visible.width)
        let gap: CGFloat = 8
        let above = visible.maxY - field.maxY - gap
        let below = field.minY - visible.minY - gap
        let useAbove = above >= height || (below < height && above > below)
        let y = useAbove ? field.maxY + gap : field.minY - gap - height
        let x = clamp(field.minX, visible.minX, visible.maxX - width)
        return CGRect(x: x, y: clamp(y, visible.minY, visible.maxY - height), width: width, height: height)
    }

    /// Keep the indicator above and to the right of the caret. At the top of the screen, move it
    /// below the line so clamping at either horizontal edge cannot cover the caret.
    public static func indicatorFrame(caret: CGRect, size: CGSize, visible: CGRect) -> CGRect {
        let gap: CGFloat = 3
        let x = clamp(caret.maxX + gap, visible.minX, visible.maxX - size.width)
        var y = caret.maxY + gap
        if y + size.height > visible.maxY { y = caret.minY - gap - size.height }
        y = clamp(y, visible.minY, visible.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(v, max(lo, hi))) }
}

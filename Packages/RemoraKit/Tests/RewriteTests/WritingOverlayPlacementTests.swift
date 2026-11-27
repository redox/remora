import Capture
import CoreGraphics
import Foundation
import Testing
@testable import Rewrite

// MARK: - Layout (Cocoa coordinates)

private let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)

@Test func editBarSitsAboveHighlightedTextInsideAFullHeightDocument() {
    let document = CGRect(x: 250, y: 0, width: 1100, height: 900)
    let selection = CGRect(x: 540, y: 350, width: 420, height: 28)
    let anchor = RewriteFlow.editBarAnchor(field: document, selection: selection, caret: nil,
                                          preferNearbyPointer: true, pointer: CGPoint(x: 960, y: 351))
    let frame = RewriteFlow.editBarFrame(field: anchor, height: 88, visible: visible)
    #expect(frame.minX == selection.minX)
    #expect(frame.minY == selection.maxY + 8)
}

@Test func editBarUsesNearbyPointerWhenAXReportsTheDocumentAsSelectionBounds() {
    let document = CGRect(x: 250, y: 0, width: 1100, height: 900)
    let pointer = CGPoint(x: 935, y: 350)
    let anchor = RewriteFlow.editBarAnchor(field: document, selection: document, caret: nil,
                                          preferNearbyPointer: true, pointer: pointer)
    let frame = RewriteFlow.editBarFrame(field: anchor, height: 88, visible: visible)
    #expect(frame.midX == pointer.x)
    #expect(frame.minY == pointer.y + 20)
}

@Test func editBarKeepsKeyboardSelectionOnItsScreenWhenPointerIsElsewhere() {
    let field = CGRect(x: 140, y: 300, width: 500, height: 100)
    let caret = CGRect(x: 220, y: 352, width: 2, height: 16)
    let anchor = RewriteFlow.editBarAnchor(field: field, selection: nil, caret: caret,
                                          preferNearbyPointer: true, pointer: CGPoint(x: -200, y: 300))
    #expect(anchor == caret)
}

@Test func googleDocsEditBarFollowsTheCaretWithThePointerElsewhereInTheDocument() {
    let context = WindowContext(app: "Chrome", bundleID: "com.google.Chrome",
                                url: URL(string: "https://docs.google.com/document/d/example/edit"))
    let document = CGRect(x: 0, y: 0, width: 1_400, height: 720)
    let caret = CGRect(x: 510, y: 570, width: 2, height: 16)
    let anchor = RewriteFlow.editBarAnchor(field: document, selection: nil, caret: caret,
                                          preferNearbyPointer: true, pointer: CGPoint(x: 850, y: 490), context: context)
    let frame = RewriteFlow.editBarFrame(field: anchor, height: 88, visible: visible)
    #expect(frame.minX == caret.minX)
    #expect(frame.minY == caret.maxY + 8)
}

@Test func googleDocsEditBarFallsBackToThePointerWhenOnlyTheEditorFrameIsAvailable() {
    let context = WindowContext(app: "Chrome", bundleID: "com.google.Chrome",
                                url: URL(string: "https://docs.google.com/document/u/0/d/example/edit?tab=t.0"))
    let document = CGRect(x: 0, y: 0, width: 1_400, height: 720)
    let pointer = CGPoint(x: 520, y: 570)
    let anchor = RewriteFlow.editBarAnchor(field: document, selection: nil, caret: nil,
                                          preferNearbyPointer: false, pointer: pointer, context: context)
    let frame = RewriteFlow.editBarFrame(field: anchor, height: 88, visible: visible)
    #expect(frame.midX == pointer.x)
    #expect(frame.minY == pointer.y + 20)
}

@Test func googleDocsEditBarPrefersTheMagnifierCaretToTheInputFieldBounds() {
    let context = WindowContext(app: "Chrome", bundleID: "com.google.Chrome",
                                url: URL(string: "https://docs.google.com/document/d/example/edit"))
    let input = CGRect(x: 0, y: 700, width: 625, height: 1)
    let caret = CGRect(x: 510, y: 570, width: 2, height: 16)
    let anchor = RewriteFlow.editBarAnchor(field: input, selection: nil, caret: input,
                                          preferNearbyPointer: false, pointer: CGPoint(x: 200, y: 220),
                                          context: context, googleDocsCaret: caret)
    let frame = RewriteFlow.editBarFrame(field: anchor, height: 88, visible: visible)
    #expect(frame.minX == caret.minX)
    #expect(frame.minY == caret.maxY + 8)
}

@Test func ghosttyInsertBarFollowsTheCursorInsideAFullHeightPane() {
    let pane = CGRect(x: 28, y: 0, width: 1000, height: 880)
    let cursor = CGRect(x: 148, y: 190, width: 2, height: 16)
    let placement = WritingOverlayPlacement(surface: .terminal, field: pane, selection: nil, caret: cursor)
    let anchor = placement.resolveAnchor(pointer: .zero).rect
    #expect(placement.indicatorAnchor(pointer: .zero) == cursor)
    let frame = RewriteFlow.editBarFrame(field: anchor, height: 128, visible: visible)
    #expect(frame.minX == cursor.minX)
    #expect(frame.minY == cursor.maxY + 8)
}

@Test func ghosttyWithoutCursorBoundsUsesThePointerOrTheFocusedPaneCentre() {
    let pane = CGRect(x: -1100, y: 20, width: 500, height: 800)
    for point in [CGPoint(x: -850, y: 610), CGPoint(x: 400, y: 300)] {
        let placement = WritingOverlayPlacement(surface: .terminal, field: pane, selection: nil, caret: nil)
        let anchor = placement.resolveAnchor(pointer: point).rect
        let expected = pane.contains(point) ? point : CGPoint(x: pane.midX, y: pane.midY)
        #expect(placement.indicatorAnchor(pointer: point).origin == expected)
        #expect(anchor.midX == expected.x)
        #expect(anchor.midY == expected.y)
        #expect(anchor.height < pane.height)
    }
}

@Test func editBarStillAnchorsToTheFieldForAnUnselectedComposer() {
    let field = CGRect(x: 140, y: 300, width: 500, height: 100)
    let caret = CGRect(x: 220, y: 352, width: 2, height: 16)
    let anchor = RewriteFlow.editBarAnchor(field: field, selection: nil, caret: caret,
                                          preferNearbyPointer: false, pointer: CGPoint(x: 600, y: 360))
    #expect(anchor == field)
}

@Test func editBarSitsAboveTheFieldWithClampedWidth() {
    let field = CGRect(x: 100, y: 300, width: 200, height: 40)
    let f = RewriteFlow.editBarFrame(field: field, height: 80, visible: visible)
    #expect(f == CGRect(x: 100, y: 348, width: 480, height: 80))
    let wide = RewriteFlow.editBarFrame(field: CGRect(x: 0, y: 300, width: 1000, height: 40), height: 80, visible: visible)
    #expect(wide.width == 560)
}

@Test func editBarGoesBelowWhenAboveWouldLeaveTheScreen() {
    let field = CGRect(x: 100, y: 820, width: 400, height: 40)
    let f = RewriteFlow.editBarFrame(field: field, height: 80, visible: visible)
    #expect(f == CGRect(x: 100, y: 732, width: 480, height: 80))
}

@Test func expandedEditBarStaysClearOfASelectionNearTheTopOfASecondScreen() {
    let screen = CGRect(x: -1200, y: 100, width: 1200, height: 800)
    let document = screen
    let selection = CGRect(x: -870, y: 830, width: 550, height: 30)
    let anchor = RewriteFlow.editBarAnchor(field: document, selection: selection, caret: nil,
                                          preferNearbyPointer: true, pointer: CGPoint(x: 200, y: 300))
    let frame = RewriteFlow.editBarFrame(field: anchor, height: 240, visible: screen)
    #expect(screen.contains(frame))
    #expect(frame.minX == selection.minX)
    #expect(frame.maxY == selection.minY - 8)
}

@Test func editBarStaysOnScreenForAFullScreenField() {
    let f = RewriteFlow.editBarFrame(field: CGRect(x: 1300, y: 0, width: 140, height: 900), height: 80, visible: visible)
    #expect(visible.contains(f) && f.width == 480)
}

@Test func expandedEditBarFitsASmallVisibleScreen() {
    let screen = CGRect(x: 200, y: 100, width: 320, height: 180)
    let frame = RewriteFlow.editBarFrame(field: CGRect(x: 500, y: 220, width: 500, height: 40),
                                        height: 400, visible: screen)
    #expect(frame == screen)
}

@Test func indicatorSitsAboveAndRightOfTheCaret() {
    let caret = CGRect(x: 200, y: 400, width: 2, height: 16)
    let frame = RewriteFlow.indicatorFrame(caret: caret, size: CGSize(width: 18, height: 18), visible: visible)
    #expect(frame.minX > caret.maxX && frame.minY > caret.maxY)
}

@Test func indicatorSitsAboveATallCaretOnAnOffsetScreen() {
    let screen = CGRect(x: -1000, y: 100, width: 1000, height: 800)
    let caret = CGRect(x: -200, y: 400, width: 2, height: 48)
    let frame = RewriteFlow.indicatorFrame(caret: caret, size: CGSize(width: 18, height: 18), visible: screen)
    #expect(screen.contains(frame))
    #expect(frame.minY > caret.maxY)
}

@Test func indicatorStaysAboveTheLineAtTheRightEdge() {
    let caret = CGRect(x: visible.maxX - 1, y: 400, width: 1, height: 16)
    let frame = RewriteFlow.indicatorFrame(caret: caret, size: CGSize(width: 18, height: 18), visible: visible)
    #expect(visible.contains(frame))
    #expect(frame.minY > caret.maxY)
}

@Test func indicatorMovesBelowTheLineAtTheTopRightCorner() {
    let caret = CGRect(x: visible.maxX - 1, y: visible.maxY - 16, width: 1, height: 16)
    let frame = RewriteFlow.indicatorFrame(caret: caret, size: CGSize(width: 18, height: 18), visible: visible)
    #expect(visible.contains(frame))
    #expect(frame.maxY < caret.minY)
}

@Test func writingBadgeFitsBelowTheCaretAtTheTopRightCorner() {
    let caret = CGRect(x: visible.maxX - 1, y: visible.maxY - 16, width: 1, height: 16)
    let size = CGSize(width: 86, height: 28)
    let frame = RewriteFlow.indicatorFrame(caret: caret, size: size, visible: visible)
    #expect(frame.size == size)
    #expect(visible.contains(frame))
    #expect(frame.maxY < caret.minY)
}

@Test func ghosttySearchFieldKeepsComposerPlacement() {
    let context = WindowContext(app: "Ghostty", bundleID: "com.mitchellh.ghostty")
    #expect(WritingOverlayPlacement.Surface(bundleID: context.bundleID, role: "AXTextArea", hasSelection: false,
                                            context: nil) == .terminal)
    #expect(WritingOverlayPlacement.Surface(bundleID: context.bundleID, role: "AXTextField", hasSelection: false,
                                            context: context) == .composer)
}

@Test func ghosttySelectionTakesPrecedenceOverCursorAndPane() {
    let pane = CGRect(x: -1100, y: 20, width: 500, height: 800)
    let text = CGRect(x: -900, y: 400, width: 80, height: 15)
    let placement = WritingOverlayPlacement(surface: .terminal, field: pane, selection: text, caret: nil)
    #expect(placement.resolveAnchor(pointer: .zero).rect == text)
}

@Test func ghosttyIgnoresTextBoundsOutsideTheFocusedPane() {
    let pane = CGRect(x: -1100, y: 20, width: 500, height: 800)
    let offscreen = CGRect(x: 100, y: 200, width: 2, height: 16)
    let placement = WritingOverlayPlacement(surface: .terminal, field: pane, selection: pane, caret: offscreen)
    let anchor = placement.resolveAnchor(pointer: .zero).rect
    #expect(anchor.midX == pane.midX && anchor.midY == pane.midY)
}

@Test func fullHeightEditorUsesItsCaretWhenTheBarWouldCoverTheField() {
    let editor = CGRect(x: 28, y: 0, width: 1000, height: 880)
    let cursor = CGRect(x: 148, y: 190, width: 2, height: 16)
    let placement = WritingOverlayPlacement(surface: .composer, field: editor, selection: nil, caret: cursor)
    let frame = placement.editBarFrame(pointer: .zero, height: 128) { _ in visible }
    #expect(frame.minX == cursor.minX && frame.minY == cursor.maxY + 8)
}

@Test func expandedPopoverRechecksWhetherItFitsBesideTheComposer() {
    let field = CGRect(x: 200, y: 140, width: 600, height: 600)
    let cursor = CGRect(x: 310, y: 300, width: 2, height: 16)
    let placement = WritingOverlayPlacement(surface: .composer, field: field, selection: nil, caret: cursor)
    let compact = placement.editBarFrame(pointer: .zero, height: 88) { _ in visible }
    let expanded = placement.editBarFrame(pointer: .zero, height: 240) { _ in visible }
    #expect(compact.minY == field.maxY + 8)
    #expect(expanded.minY == cursor.maxY + 8)
    #expect(expanded.minX == cursor.minX)
}

@Test func reportsWhichGeometryActuallyPositionedThePopover() {
    let field = CGRect(x: 100, y: 100, width: 500, height: 300)
    let caret = CGRect(x: 140, y: 240, width: 2, height: 16)
    let pointer = CGPoint(x: 180, y: 150)
    let cases: [(WritingOverlayPlacement.Surface, CGRect?, CGRect?, CGPoint, String)] = [
        (.googleDocs, caret, caret, pointer, "documentCaret"),
        (.googleDocs, caret, nil, pointer, "caret"),
        (.googleDocs, nil, nil, pointer, "pointer"),
        (.terminal, nil, nil, pointer, "pointer"),
        (.terminal, nil, nil, .zero, "paneCentre"),
        (.composer, caret, nil, pointer, "field")
    ]
    for (surface, ordinary, verified, point, expected) in cases {
        let placement = WritingOverlayPlacement(surface: surface, field: field, selection: nil,
                                                caret: ordinary, verifiedCaret: verified)
        #expect(placement.resolveAnchor(pointer: point).source.rawValue == expected)
    }
}

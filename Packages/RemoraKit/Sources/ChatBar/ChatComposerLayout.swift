import SwiftUI

/// Expects a multiline text field followed by its controls. Moving the controls beneath the
/// same editor preserves the selection and marked text while the draft grows.
public struct ChatComposerLayout: Layout {
    public init() {}

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(width: proposal.width, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = frames(width: bounds.width, subviews: subviews)
        for (view, frame) in zip(subviews, [layout.field, layout.controls]) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width proposedWidth: CGFloat?, subviews: Subviews) -> (size: CGSize, field: CGRect, controls: CGRect) {
        let field = subviews[0]
        let controls = subviews[1].sizeThatFits(.unspecified)
        let gap: CGFloat = 8
        let width = proposedWidth.flatMap { $0.isFinite ? $0 : nil }
            ?? (field.sizeThatFits(.unspecified).width + gap + controls.width)
        let inlineWidth = max(0, width - gap - controls.width)
        let inline = field.dimensions(in: ProposedViewSize(width: inlineWidth, height: nil))
        // AppKit can round the two baselines of a single line a point apart at larger font sizes.
        let fieldFrame: CGRect
        let height: CGFloat
        if inline[.lastTextBaseline] - inline[.firstTextBaseline] > 1 {
            let fieldWidth = max(0, width - gap)
            let full = field.sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil))
            fieldFrame = CGRect(x: 0, y: gap, width: fieldWidth, height: full.height)
            height = fieldFrame.maxY + gap + controls.height
        } else {
            height = max(inline.height, controls.height)
            fieldFrame = CGRect(x: 0, y: (height - inline.height) / 2, width: inlineWidth, height: inline.height)
        }
        let controlsFrame = CGRect(origin: CGPoint(x: width - controls.width, y: height - controls.height), size: controls)
        return (CGSize(width: width, height: height), fieldFrame, controlsFrame)
    }
}

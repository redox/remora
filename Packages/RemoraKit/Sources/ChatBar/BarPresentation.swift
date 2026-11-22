import CoreGraphics
import Foundation

/// How the collapsed bar looks.
public enum BarAppearance {
    /// 0.01 while auto-hidden (invisible, but not click-through: fully transparent pixels let
    /// clicks fall through), 0.45 while dimmed, else 1. Hovering always shows it fully.
    public static func collapsedAlpha(_ s: BarSettings, hovered: Bool) -> Double {
        if hovered { return 1 }
        if s.autoHide { return 0.01 }
        if s.dimWhenUnfocused { return 0.45 }
        return 1
    }

    public enum CapsuleStyle: Sendable, Equatable { case plain, streaming, awaitingAnswer }

    /// A card waiting for the user's answer outranks streaming: it needs them.
    public static func capsule(streaming: Bool, awaitingAnswer: Bool) -> CapsuleStyle {
        awaitingAnswer ? .awaitingAnswer : streaming ? .streaming : .plain
    }

    /// Losing key focus collapses an open, unpinned bar, except while a confirmation card waits
    /// (it must stay visible) or the bar's own details popover took the focus.
    public static func collapsesOnResignKey(cardPending: Bool, detailsOpen: Bool) -> Bool {
        !cardPending && !detailsOpen
    }
}

/// The expanded panel's frame (Cocoa coordinates) and where its card sits inside it.
public enum BarLayout {
    /// With `bar` (peeking from hover), the panel also covers the collapsed bar, so the pointer
    /// moving from the bar to the card never leaves the panel. Without it (open), the panel is the
    /// card. `card` in the result is panel-local with a top-left origin (SwiftUI).
    public static func panel(card: CGRect, bar: CGRect?) -> (frame: CGRect, card: CGRect) {
        let frame = bar.map { card.union($0) } ?? card
        let local = CGRect(x: card.minX - frame.minX, y: frame.maxY - card.maxY, width: card.width, height: card.height)
        return (frame, local)
    }
}

extension MarkdownBlocks {
    /// Where the links of an `inline(_:)` result go, in order and without repeats: the host for
    /// web links, the address for `mailto`. Shown on hover, so link text can't hide its target.
    public static func linkHosts(_ s: AttributedString) -> [String] {
        var out: [String] = []
        for run in s.runs {
            guard let url = run.link else { continue }
            let target: String?
            if url.scheme?.lowercased() == "mailto" {
                let path = url.absoluteString.dropFirst("mailto:".count)
                target = path.split(separator: "?").first.map(String.init)
            } else {
                target = url.host(percentEncoded: false)
            }
            if let target, !target.isEmpty, !out.contains(target) { out.append(target) }
        }
        return out
    }
}

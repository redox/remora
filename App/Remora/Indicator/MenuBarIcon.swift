import AppKit
import Indicator

/// The menu-bar image: the status symbol plus an optional capture dot.
///
/// Default (D3): a non-template image, Remora mark tinted with `labelColor` and a 6 pt dot (orange
/// = capturing, ring = not capturing), colours resolved at draw time.
/// Fallback (D3): set `useTemplateFallback` to true for a template image (system tints it),
/// with a filled dot vs. a ring and no colour.
@MainActor
enum MenuBarIcon {
    static let useTemplateFallback = false

    private static let height: CGFloat = 18
    private static let dotSize: CGFloat = 6
    private static let dotGap: CGFloat = 3
    private static var cache: [String: NSImage] = [:]

    static func image(symbol: String, dot: IndicatorDot?) -> NSImage {
        let key = "\(symbol)|\(dot.map { "\($0)" } ?? "none")|\(useTemplateFallback)"
        if let hit = cache[key] { return hit }
        let image = make(symbol: symbol, dot: dot)
        cache[key] = image
        return image
    }

    private static func make(symbol: String, dot: IndicatorDot?) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        // Preserve the pause and permission symbols; only the ordinary fish becomes our mark.
        let base = symbol == "fish" ? RemoraBrand.menuImage()
            : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) ?? NSImage()
        guard let dot else {
            base.isTemplate = true
            return base
        }
        let symbolSize = base.size
        // Copied to locals: AppKit may run the handler off the main actor.
        let template = useTemplateFallback
        let (height, dotSize, dotGap) = (Self.height, Self.dotSize, Self.dotGap)
        let width = symbolSize.width + dotGap + dotSize
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { @Sendable rect in
            let symbolRect = NSRect(x: 0, y: (rect.height - symbolSize.height) / 2,
                                    width: symbolSize.width, height: symbolSize.height)
            base.draw(in: symbolRect)
            // Tint only the symbol's pixels (sourceAtop), before the dot is drawn.
            (template ? NSColor.black : NSColor.labelColor).set()
            symbolRect.fill(using: .sourceAtop)
            let dotRect = NSRect(x: symbolSize.width + dotGap, y: (rect.height - dotSize) / 2,
                                 width: dotSize, height: dotSize)
            switch dot {
            case .capturing:
                (template ? NSColor.black : NSColor.systemOrange).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            case .notCapturing:
                (template ? NSColor.black : NSColor.secondaryLabelColor).setStroke()
                let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
            }
            return true
        }
        image.isTemplate = template
        return image
    }
}

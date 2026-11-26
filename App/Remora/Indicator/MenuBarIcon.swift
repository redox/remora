import AppKit
import Indicator

/// The menu-bar mark, window-capture dot, and optional recording waveform.
///
/// Default (D3): a non-template image with a `labelColor` Remora mark and a 6 pt capture dot.
/// The dot is sea-glass when capturing and a gray ring otherwise. Colours are resolved at draw time.
/// Fallback (D3): set `useTemplateFallback` to true for a template image (system tints it),
/// with a filled dot vs. a ring and no colour.
@MainActor
enum MenuBarIcon {
    enum RecordingPhase: Sendable { case off, bright, dim }

    static let useTemplateFallback = false

    private static let height: CGFloat = 18
    private static let dotSize: CGFloat = 6
    private static let dotGap: CGFloat = 3
    private static var cache: [String: NSImage] = [:]

    static func image(symbol: String, dot: IndicatorDot?, recording: RecordingPhase) -> NSImage {
        let key = "\(symbol)|\(dot.map { "\($0)" } ?? "none")|\(recording)|\(useTemplateFallback)"
        if let hit = cache[key] { return hit }
        let image = make(symbol: symbol, dot: dot, recording: recording)
        cache[key] = image
        return image
    }

    private static func make(symbol: String, dot: IndicatorDot?, recording: RecordingPhase) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let base = symbol == RemoraBrand.glyphName ? RemoraBrand.glyphImage(size: height)
            : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) ?? NSImage()
        guard dot != nil || recording != .off else {
            base.isTemplate = true
            return base
        }
        let symbolSize = base.size
        // Copied to locals: AppKit may run the handler off the main actor.
        let template = useTemplateFallback
        let captureColor = template ? NSColor.black : RemoraBrand.accentColor
        let (height, dotSize, dotGap) = (Self.height, Self.dotSize, Self.dotGap)
        let waveformWidth: CGFloat = 14
        let columnWidth = recording == .off ? dotSize : waveformWidth
        let width = symbolSize.width + dotGap + columnWidth
        let ink = template ? NSColor.black : NSColor.systemRed
        let waveform = recording == .off ? nil : NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [ink]))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { @Sendable rect in
            let symbolRect = NSRect(x: 0, y: (rect.height - symbolSize.height) / 2,
                                    width: symbolSize.width, height: symbolSize.height)
            base.draw(in: symbolRect)
            // Tint only the symbol's pixels (sourceAtop), before the dot is drawn.
            (template ? NSColor.black : NSColor.labelColor).set()
            symbolRect.fill(using: .sourceAtop)
            let columnCenter = symbolSize.width + dotGap + columnWidth / 2
            if let waveform {
                let height: CGFloat = dot == nil ? 12 : 9
                let y = dot == nil ? (rect.height - height) / 2 : 0
                let frame = NSRect(x: columnCenter - waveformWidth / 2, y: y, width: waveformWidth, height: height)
                waveform.draw(in: frame, from: .zero, operation: .sourceOver, fraction: recording == .dim ? 0.55 : 1)
            }
            guard let dot else { return true }
            let dotY = recording == .off ? (rect.height - dotSize) / 2 : rect.height - dotSize
            let dotRect = NSRect(x: columnCenter - dotSize / 2, y: dotY, width: dotSize, height: dotSize)
            switch dot {
            case .capturing:
                captureColor.setFill()
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

import AppKit
import SwiftUI

/// Shared artwork and ink for Remora's small surfaces. The monochrome asset stays readable
/// at menu-bar size; the full-color app tile is reserved for Finder and system app lists.
@MainActor
enum RemoraBrand {
    static let glyphName = "RemoraGlyph"

    // Match the website's accent in both appearances.
    private static let lightAccent = NSColor(srgbRed: 52.0 / 255, green: 100.0 / 255, blue: 93.0 / 255, alpha: 1)
    private static let darkAccent = NSColor(srgbRed: 164.0 / 255, green: 203.0 / 255, blue: 191.0 / 255, alpha: 1)

    static let accentColor: NSColor = {
        let (light, dark) = (lightAccent, darkAccent)
        return NSColor(name: nil) { @Sendable appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }()

    static func accent(_ scheme: ColorScheme) -> Color {
        Color(nsColor: scheme == .dark ? darkAccent : lightAccent)
    }

    static func glyphImage(size: CGFloat) -> NSImage {
        // Copy before assigning the logical size: named images are shared by AppKit.
        let image = (NSImage(named: glyphName)?.copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}

struct RemoraGlyph: View {
    var body: some View {
        Image(RemoraBrand.glyphName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
    }
}

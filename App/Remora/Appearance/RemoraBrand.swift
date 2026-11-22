import AppKit
import SwiftUI

/// Shared artwork and ink for Remora's small surfaces. The monochrome asset stays readable
/// at menu-bar size; the full-color app tile is reserved for Finder and system app lists.
@MainActor
enum RemoraBrand {
    static let glyphName = "RemoraGlyph"

    // Match the website's accent and apply it to individual controls or decorative elements.
    // This lets text selection and standard controls follow the user's macOS appearance.
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 164.0 / 255, green: 203.0 / 255, blue: 191.0 / 255)
            : Color(red: 52.0 / 255, green: 100.0 / 255, blue: 93.0 / 255)
    }

    static func menuImage() -> NSImage {
        // Copy before assigning the logical size: named images are shared by AppKit.
        let image = (NSImage(named: glyphName)?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "fish.fill", accessibilityDescription: nil)
            ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
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

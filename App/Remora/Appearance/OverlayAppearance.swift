import SwiftUI

/// An opaque backing keeps the host app from competing with the overlay's text.
struct OverlaySurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(Color(nsColor: .textBackgroundColor))
                    .overlay { shape.fill(RemoraBrand.accent(scheme).opacity(0.025)) }
                    .overlay {
                        shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : 0.06))
                    }
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
    }
}

struct OverlayComposerBackground: View {
    let focused: Bool
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let borderOpacity = contrast == .increased
            ? (focused ? 0.80 : 0.52)
            : (focused ? 0.38 : 0.10)
        shape.fill(Color.primary.opacity(focused ? 0.07 : 0.045))
            .overlay {
                shape.strokeBorder(Color.primary.opacity(borderOpacity))
            }
            .allowsHitTesting(false)
    }
}

/// Quiet controls gain a fill on hover or when they represent an active choice.
struct QuietButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, selected: selected, accent: RemoraBrand.accent(scheme), enabled: enabled)
    }

    private struct Surface: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let accent: Color
        let enabled: Bool
        @State private var hovered = false

        var body: some View {
            let pressed = enabled && configuration.isPressed
            let highlighted = enabled && hovered
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            let ink = selected ? accent : Color.primary.opacity(0.9)
            let fill = selected ? accent.opacity(pressed ? 0.17 : highlighted ? 0.16 : 0.13)
                : Color.primary.opacity(pressed ? 0.10 : highlighted ? 0.06 : 0)
            configuration.label
                .foregroundStyle(ink.opacity(enabled ? 1 : 0.55))
                .background(fill, in: shape)
                .contentShape(shape)
                .onHover { hovered = $0 }
        }
    }
}

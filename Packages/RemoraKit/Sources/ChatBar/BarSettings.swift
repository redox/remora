import Foundation
import CoreGraphics

public enum BarPosition: String, Codable, Sendable, CaseIterable {
    case top, left, right, bottom
    case bottomLeft = "bottom_left"
    case bottomRight = "bottom_right"

    public var title: String {
        switch self {
        case .top: "Top (under the notch)"
        case .left: "Left edge"
        case .right: "Right edge"
        case .bottom: "Bottom edge"
        case .bottomLeft: "Bottom-left corner"
        case .bottomRight: "Bottom-right corner"
        }
    }
}

public struct BarSettings: Codable, Sendable, Equatable {
    public static let key = "chat.bar"

    public var position: BarPosition = .top
    public var openOnHover = true
    public var autoHide = false
    public var dimWhenUnfocused = false
    /// Clamped to 1.0...1.5 and rounded to a 0.1 step.
    public var textScale: Double = 1.0 { didSet { textScale = Self.clamp(textScale) } }
    public var pinned = false
    /// Keyed by `BarPosition.rawValue`.
    public var expandedSizes: [String: CGSize] = [:]

    /// A nil size lets this position open at the current default.
    public var savedExpandedSize: CGSize? {
        get { expandedSizes[position.rawValue] }
        set { expandedSizes[position.rawValue] = newValue }
    }

    public init() {}

    static func clamp(_ v: Double) -> Double {
        let c = min(1.5, max(1.0, v))
        return (c * 10).rounded() / 10
    }

    private enum CodingKeys: String, CodingKey {
        case position, openOnHover, autoHide, dimWhenUnfocused, textScale, pinned, expandedSizes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = (try? c.decodeIfPresent(BarPosition.self, forKey: .position)) ?? .top
        openOnHover = (try? c.decodeIfPresent(Bool.self, forKey: .openOnHover)) ?? true
        autoHide = (try? c.decodeIfPresent(Bool.self, forKey: .autoHide)) ?? false
        dimWhenUnfocused = (try? c.decodeIfPresent(Bool.self, forKey: .dimWhenUnfocused)) ?? false
        textScale = Self.clamp((try? c.decodeIfPresent(Double.self, forKey: .textScale)) ?? 1.0)
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        expandedSizes = (try? c.decodeIfPresent([String: CGSize].self, forKey: .expandedSizes)) ?? [:]
    }
}

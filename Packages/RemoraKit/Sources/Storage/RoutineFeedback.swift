/// User feedback keyed by the fingerprint of a detected routine. The observations themselves
/// are read from live captures on demand. Forget and delete-all clear this setting.
public enum RoutineFeedback: Codable, Sendable, Equatable {
    case label(String)
    case dismissed

    public static let settingsKey = "routines.feedback"
}

import Capture
import Foundation

/// An unreadable call window cannot prove the user left a manually stopped meeting.
public struct MeetingStartPolicy: Sendable {
    private var stoppedID: String?
    private var retry: (id: String, after: ContinuousClock.Instant, delay: Duration)?
    public var retryingID: String? { retry?.id }

    public init() {}

    public mutating func suppress(_ id: String) {
        stoppedID = id
        retry = nil
    }

    public mutating func left() { stoppedID = nil }

    /// A recoverable failure closes both inputs. Only a new joined observation may open them again.
    public mutating func retryAfterInterruption(_ id: String, now: ContinuousClock.Instant = .now) {
        guard id != stoppedID else { return }
        let delay: Duration
        if let retry, retry.id == id, now < retry.after + .seconds(60) {
            delay = min(retry.delay * 2, .seconds(30))
        } else {
            delay = .seconds(2)
        }
        retry = (id, now + delay, delay)
    }

    public func mayStart(_ id: String, now: ContinuousClock.Instant = .now) -> Bool {
        guard id != stoppedID else { return false }
        guard let retry, retry.id == id else { return true }
        return now >= retry.after
    }

    /// Only an explicitly suppressed recording needs the detector to keep watching for departure.
    /// A closed or hidden tab otherwise releases its token as soon as recording stops.
    public mutating func continuityAfterAbsence(_ previous: MeetingContinuity?, departureConfirmed: Bool) -> MeetingContinuity? {
        if let previous, previous.id == retry?.id { retry = nil }
        guard let previous, stoppedID == previous.id else { return nil }
        if departureConfirmed {
            left()
            return nil
        }
        return previous
    }
}

/// The window provides observations on the audio clock, rather than per-person audio tracks.
public struct TimedMeetingCaptions: Sendable {
    private struct Entry: Sendable {
        let speaker: String
        let observed: TimeInterval
    }
    private var entries: [String: [Entry]] = [:]
    public init() {}

    public mutating func observe(text: String, speaker: String, at seconds: TimeInterval) {
        let words = Self.words(text)
        guard !speaker.isEmpty, !words.isEmpty else { return }
        entries[words, default: []].append(Entry(speaker: speaker, observed: seconds))
    }

    public func speaker(for text: String, start: TimeInterval, end: TimeInterval) -> String? {
        let words = Self.words(text)
        // Short acknowledgements frequently coincide across speakers.
        guard words.split(separator: " ").count >= 3 else { return nil }
        guard let matches = entries[words] else { return nil }
        let names = Set(matches.lazy.filter {
            $0.observed >= start && $0.observed <= end + 3
        }.map(\.speaker))
        return names.count == 1 ? names.first : nil
    }

    static func words(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}

/// Every utterance in a local recording is stored under one exclusion context.
public enum MeetingSourceCheck: Equatable, Sendable {
    case verified, changed, denied

    public static func evaluate(original: WindowContext, current: WindowContext, policy: CapturePolicy) -> Self {
        guard policy.shouldCapture(original), policy.shouldCapture(current) else { return .denied }
        return original == current ? .verified : .changed
    }
}

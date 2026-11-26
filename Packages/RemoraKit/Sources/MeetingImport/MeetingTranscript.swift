import Foundation

/// Speech analysis finishes independently on each channel. Use the audio clock to merge the
/// results and withhold remote names wherever overlapping audio makes attribution ambiguous.
public struct MeetingTranscript: Sendable {
    private struct Utterance: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let microphone: Bool
    }

    private var unverifiedMicrophone: [Range<TimeInterval>] = []
    private var utterances: [Utterance] = []
    public var captions = TimedMeetingCaptions()
    public init() {}

    public mutating func append(text: String, start: TimeInterval, end: TimeInterval, microphone: Bool) {
        guard start.isFinite, start >= 0, start < Double(Int.max), end.isFinite, end >= start else { return }
        utterances.append(Utterance(text: text, start: start, end: end, microphone: microphone))
    }

    /// The app may learn of mute after the actual click. Drop speech spanning the uncertain
    /// interval, including recognition results that arrive during the final drain.
    public mutating func withholdMicrophone(after start: TimeInterval, until end: TimeInterval) {
        if end > start { unverifiedMicrophone.append(start..<end) }
    }

    public func rendered(through cutoff: TimeInterval = .infinity) -> String {
        let eligible = utterances.filter { $0.end <= cutoff }
        let remote = Dictionary(grouping: eligible.filter { !$0.microphone }) { TimedMeetingCaptions.words($0.text) }
        let ordered = eligible.filter { part in
            guard part.microphone else { return true }
            guard !unverifiedMicrophone.contains(where: { part.start < $0.upperBound && $0.lowerBound < part.end }) else {
                return false
            }
            // Laptop speakers can feed the same sentence back through an open microphone.
            let matches = remote[TimedMeetingCaptions.words(part.text)] ?? []
            return !matches.contains { abs($0.start - part.start) <= 0.4 && abs($0.end - part.end) <= 0.4 }
        }.sorted { $0.start < $1.start }
        var lastEnd: TimeInterval = 0
        return ordered.enumerated().map { index, part in
            let seconds = Int(part.start)
            let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
            let overlaps = lastEnd > part.start || (index + 1 < ordered.count && ordered[index + 1].start < part.end)
            lastEnd = max(lastEnd, part.end)
            var name: String?
            if part.microphone {
                name = "You"
            } else if !overlaps {
                name = captions.speaker(for: part.text, start: part.start, end: part.end)
            }
            return "[\(time)] " + (name.map { "\($0): " } ?? "") + part.text
        }.joined(separator: "\n")
    }
}

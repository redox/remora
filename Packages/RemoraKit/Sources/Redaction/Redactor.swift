import Foundation

/// A single detection strategy. Returns the ranges of `text` that must be redacted.
protocol Detector: Sendable {
    func ranges(in text: String) -> [Range<String.Index>]
}

/// Replaces secrets and sensitive identifiers in captured text with `[redacted]`.
/// Runs on every captured string before it is written to disk.
public struct Redactor: Sendable {
    public static let placeholder = "[redacted]"

    private let detectors: [any Detector]

    public init() {
        detectors = [PaymentCardDetector(), IBANDetector(), NationalIDDetector(), SecretsDetector()]
    }

    public func redact(_ text: String) -> String {
        var found: [Range<String.Index>] = []
        for detector in detectors { found.append(contentsOf: detector.ranges(in: text)) }
        guard !found.isEmpty else { return text }

        found.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                if range.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<range.upperBound
                }
            } else {
                merged.append(range)
            }
        }

        var result = ""
        var cursor = text.startIndex
        for range in merged {
            result += text[cursor..<range.lowerBound]
            result += Self.placeholder
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }
}

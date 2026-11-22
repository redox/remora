import CryptoKit
import Foundation
import Redaction
import Storage

/// Which interface the clutter belongs to: a site for browsers, an app otherwise.
public enum BoilerplateSurface {
    public static func key(bundleID: String?, app: String, domain: String?) -> String {
        if BrowserCatalog.isBrowser(bundleID), let domain, !domain.isEmpty { return "web:" + domain }
        return "app:" + (bundleID ?? app)
    }

    /// Whether `policy` still allows the surface: a site (`web:`) as `https://<domain>`; an app
    /// (`app:`, a bundle id or name) at the app level under each of `appNames` (the names seen for
    /// it) and its own key. An unknown form is kept.
    public static func allows(_ surface: String, appNames: [String], policy: CapturePolicy) -> Bool {
        if surface.hasPrefix("web:") {
            let domain = String(surface.dropFirst(4))
            guard let url = URL(string: "https://\(domain)"), url.host() != nil else { return true }
            return policy.shouldCapture(WindowContext(app: "", url: url))
        }
        guard surface.hasPrefix("app:") else { return true }
        let key = String(surface.dropFirst(4))
        return ([key] + appNames).allSatisfy {
            policy.appVerdict(WindowContext(app: $0, bundleID: key)) == .allowed
        }
    }
}

public enum BoilerplateLine {
    public static let maxWords = 8
    public static let maxChars = 80

    /// The trimmed, whitespace-collapsed line, or nil unless it can be interface clutter:
    /// 1-8 words, at most 80 characters, no digit.
    public static func normalize(_ line: Substring) -> String? {
        let words = line.split(whereSeparator: \.isWhitespace)
        guard (1...maxWords).contains(words.count) else { return nil }
        let collapsed = words.joined(separator: " ")
        guard collapsed.count <= maxChars, !collapsed.contains(where: \.isNumber) else { return nil }
        return collapsed
    }

    /// The one line rule shared by sampler and stripper (any Unicode newline).
    static func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// First 16 hex digits of the SHA-256 of the lowercased line.
    public static func hash(_ normalized: String) -> String {
        SHA256.hash(data: Data(normalized.lowercased().utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }
}

extension BoilerplateSample {
    /// Samples candidate lines of `text`. A line counts only if it appears unchanged in the
    /// redaction of the WHOLE text, so lines of multi-line secrets (a PEM body) are never kept.
    public static func sample(surface: String, text: String, redactor: Redactor) -> BoilerplateSample {
        sample(surface: surface, text: text, redacted: redactor.redact(text))
    }

    /// Same, when the caller already holds `redactor.redact(text)`.
    /// More than `maxInputLines` lines of input yields an empty sample (huge documents).
    public static func sample(surface: String, text: String, redacted: String,
                              maxInputLines: Int = .max) -> BoilerplateSample {
        let rawLines = BoilerplateLine.lines(text)
        guard rawLines.count <= maxInputLines else { return BoilerplateSample(surface: surface, lines: [:]) }
        let safe = Set(BoilerplateLine.lines(redacted).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        var lines: [String: String] = [:]
        for line in rawLines {
            guard lines.count < maxLines,
                  let normalized = BoilerplateLine.normalize(line),
                  safe.contains(line.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            lines[BoilerplateLine.hash(normalized)] = normalized
        }
        return BoilerplateSample(surface: surface, lines: lines)
    }
}

public enum BoilerplateStripper {
    /// Removes candidate lines whose hash is learned. Everything else is untouched.
    public static func strip(_ text: String, learned: Set<String>) -> String {
        guard !learned.isEmpty else { return text }
        var kept: [Substring] = []
        var removed = false
        for line in BoilerplateLine.lines(text) {
            if let n = BoilerplateLine.normalize(line), learned.contains(BoilerplateLine.hash(n)) {
                removed = true
            } else {
                kept.append(line)
            }
        }
        return removed ? kept.joined(separator: "\n") : text
    }
}

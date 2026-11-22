import Foundation
import Redaction
import Storage
import Testing
@testable import Capture

@Test(arguments: [("Hide sidebar", true), ("Inbox (3)", false), ("New chat", true),
                  ("This line has far more than eight words in it", false), ("", false),
                  ("   Back  ", true)])
func candidateLines(line: String, candidate: Bool) {
    #expect((BoilerplateLine.normalize(line[...]) != nil) == candidate)
}

@Test func candidateLengthBound() {
    #expect(BoilerplateLine.normalize(String(repeating: "a", count: 80)[...]) != nil)
    #expect(BoilerplateLine.normalize(String(repeating: "a", count: 81)[...]) == nil)
    #expect(BoilerplateLine.normalize("  Hide \t  sidebar ".dropFirst(0)) == "Hide sidebar")
}

@Test func hashIsCaseInsensitiveSixteenHex() {
    let h = BoilerplateLine.hash("Hide sidebar")
    #expect(h.count == 16 && h.allSatisfy(\.isHexDigit))
    #expect(h == BoilerplateLine.hash("hide SIDEBAR"))
    #expect(h != BoilerplateLine.hash("New chat"))
}

@Test func surfaceKeys() {
    #expect(BoilerplateSurface.key(bundleID: "com.apple.Safari", app: "Safari", domain: "mail.google.com")
            == "web:mail.google.com")
    #expect(BoilerplateSurface.key(bundleID: "com.tinyspeck.slackmacgap", app: "Slack", domain: nil)
            == "app:com.tinyspeck.slackmacgap")
    #expect(BoilerplateSurface.key(bundleID: nil, app: "Notes", domain: nil) == "app:Notes")
    // A non-browser never gets a web surface, even with a domain.
    #expect(BoilerplateSurface.key(bundleID: "com.tinyspeck.slackmacgap", app: "Slack", domain: "x.com")
            == "app:com.tinyspeck.slackmacgap")
    // A browser without a domain falls back to the app surface.
    #expect(BoilerplateSurface.key(bundleID: "com.apple.Safari", app: "Safari", domain: nil)
            == "app:com.apple.Safari")
}

@Test func stripRemovesOnlyLearnedCandidates() {
    let text = "Hide sidebar\nRéunion lundi 10h\nNew chat\nMerci Marc"
    let learned: Set<String> = [BoilerplateLine.hash("Hide sidebar"), BoilerplateLine.hash("New chat")]
    #expect(BoilerplateStripper.strip(text, learned: learned) == "Réunion lundi 10h\nMerci Marc")
    // Nothing learned: byte-identical. Non-candidates are never removed even if hashed.
    #expect(BoilerplateStripper.strip(text, learned: []) == text)
    let withBlank = "Keep one\n\nHide sidebar\n\nKeep two"
    #expect(BoilerplateStripper.strip(withBlank, learned: learned) == "Keep one\n\n\nKeep two")
    let digitLine = "Inbox (3)"
    #expect(BoilerplateStripper.strip(digitLine, learned: [BoilerplateLine.hash(digitLine)]) == digitLine)
}

@Test func sampleCollectsCandidatesOnly() {
    let s = BoilerplateSample.sample(
        surface: "app:x", text: "Hide sidebar\nHide sidebar\nInbox (3)\nA long real sentence about the Oslo trip budget review",
        redactor: Redactor())
    #expect(s.surface == "app:x")
    #expect(s.lines == [BoilerplateLine.hash("Hide sidebar"): "Hide sidebar"])
}

@Test func linesWithSecretsAreNeverSampled() {
    precondition(Redactor().redact("password: correcthorse") != "password: correcthorse")
    let s = BoilerplateSample.sample(
        surface: "app:x", text: "Hide sidebar\npassword: correcthorse", redactor: Redactor())
    #expect(s.lines.count == 1 && s.lines.values.first == "Hide sidebar")
}

@Test func linesInsideMultiLineSecretsAreNeverSampled() {
    let pem = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEAsecretbodyline
    AbCdEfGhIjKlMnOpQrStUvWxYzNoDigits
    -----END RSA PRIVATE KEY-----
    """
    let text = "Hide sidebar\n" + pem + "\nNew chat"
    let redacted = Redactor().redact(text)
    precondition(!redacted.contains("secretbodyline"), "fixture must be redacted by the real Redactor")
    let s = BoilerplateSample.sample(surface: "app:x", text: text, redactor: Redactor())
    #expect(Set(s.lines.values) == ["Hide sidebar", "New chat"])
}

@Test func sampleIsCappedAt300Lines() {
    let text = (0..<400).map { "Line " + String(UnicodeScalar(UInt8(97 + $0 % 26))) + String(repeating: "z", count: $0 / 26) }
        .joined(separator: "\n")
    let s = BoilerplateSample.sample(surface: "app:x", text: text, redactor: Redactor())
    #expect(s.lines.count == 300)
}

@Test func samplingAndStrippingWorkOnLargeText() {
    let text = (0..<2_000).map { "Row \($0) of a long conversation with some words in it, ok" }.joined(separator: "\n")
        + "\n" + (0..<50).map { "Menu item \(String(repeating: "x", count: $0 % 5 + 1))" }.joined(separator: "\n")
    let s = BoilerplateSample.sample(surface: "app:x", text: text, redactor: Redactor())
    #expect(s.lines.count == 5)
    let stripped = BoilerplateStripper.strip(text, learned: Set(s.lines.keys))
    #expect(!stripped.contains("Menu item") && stripped.contains("Row 1999 of"))
}

@Test func hugeInputsAreNotSampled() {
    let text = (0..<30).map { _ in "Hide sidebar" }.joined(separator: "\n")
    #expect(BoilerplateSample.sample(surface: "s", text: text, redacted: text, maxInputLines: 10).lines.isEmpty)
}

@Test func samplerAndStripperShareTheLineRule() {
    let text = "Hide sidebar\r\nKeep this real line 42\u{2028}New chat"
    let s = BoilerplateSample.sample(surface: "s", text: text, redactor: Redactor())
    #expect(Set(s.lines.values) == ["Hide sidebar", "New chat"] || s.lines.count >= 2)
    let out = BoilerplateStripper.strip(text, learned: Set(s.lines.keys))
    #expect(!out.contains("Hide sidebar") && !out.contains("New chat") && out.contains("Keep this real line 42"))
}

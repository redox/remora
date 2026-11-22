import Foundation
import Testing
@testable import Redaction

private let r = Redactor()

@Test(arguments: [
    ("Card 4111 1111 1111 1111 exp", "Card [redacted] exp"),
    ("Card 4111-1111-1111-1111.", "Card [redacted]."),
    ("Total 12 4111 1111 1111 1111", "Total 12 [redacted]"),
    ("Card 4111\u{00A0}1111\u{00A0}1111\u{00A0}1111 x", "Card [redacted] x"),
    ("Sécu : 1\u{202F}85\u{202F}05\u{202F}78\u{202F}006\u{202F}084\u{202F}91", "Sécu : [redacted]"),
    ("https://x.com/cb?access_token=abc123&state=xyz&next=/home", "https://x.com/cb?access_token=[redacted]&state=xyz&next=/home"),
    ("Server=db;Password=abc;Database=x;", "Server=db;Password=[redacted];Database=x;"),
    ("Card 4111 1111 1111 1111 123", "Card [redacted] 123"),
    ("Total 12 4111 1111 1111 1111 99", "Total 12 [redacted] 99"),
    ("IBAN FR76\u{00A0}3000\u{00A0}6000\u{00A0}0112\u{00A0}3456\u{00A0}7890\u{00A0}189.", "IBAN [redacted]."),
    ("CVV: 123", "CVV: [redacted]"),
    ("cryptogramme 4567", "cryptogramme [redacted]"),
    ("IBAN FR76 3000 6000 0112 3456 7890 189.", "IBAN [redacted]."),
    ("GB82 WEST 1234 5698 7654 32", "[redacted]"),
    ("SSN 123-45-6789", "SSN [redacted]"),
    ("Sécu : 1 85 05 78 006 084 91", "Sécu : [redacted]"),
    ("Numéro fiscal : 1234567890123", "Numéro fiscal : [redacted]"),
    ("SPI 12 34 567 890 123", "SPI [redacted]"),
    ("export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx", "export OPENAI_API_KEY=[redacted]"),
    ("Authorization: Bearer abc.def.ghi", "Authorization: Bearer [redacted]"),
    ("postgres://app:s3cr3t@db.internal:5432/prod", "postgres://app:[redacted]@db.internal:5432/prod"),
    ("https://x.com/cb?code=1&token=abcd1234", "https://x.com/cb?code=[redacted]&token=[redacted]"),
    ("mysql -u root -p hunter2", "mysql -u root -p [redacted]"),
    ("run --password=hunter2 now", "run --password=[redacted] now"),
    ("DB_PASSWORD=hunter2", "DB_PASSWORD=[redacted]"),
    ("AKIAIOSFODNN7EXAMPLE", "[redacted]"),
    ("ghp_abcdefghijklmnopqrstuvwxyz0123456789", "[redacted]"),
    ("xoxb-1234567890-abcdefghij", "[redacted]"),
    ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.abc_def-123", "[redacted]"),
])
func redactsSecrets(input: String, expected: String) {
    #expect(r.redact(input) == expected)
}

@Test func redactsPEMBlockEntirely() {
    let pem = "key:\n-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nabcd\n-----END RSA PRIVATE KEY-----\nafter"
    #expect(r.redact(pem) == "key:\n[redacted]\nafter")
}

@Test(arguments: [
    "Appelle-moi au 06 12 34 56 78", "+33 6 12 34 56 78", "Le 2026-11-20 à 14:30",
    "Commande #123456789", "4111 1111 1111 1112", "FR76 3000 6000 0112 3456 7890 188",
    "Sécu : 1 85 05 78 006 084 36", "1234567890123", "alice@example.com",
    "Version 10.15.7 build 19H2", "Total: 1 234 567,89 €",
    "06 12 34 56 78 07 98 76 54 32", "12 34 56 78 90 12 34 56 78 90",
    "see task-abcdefghijklmnopqrstuvwxyz", "Hello world, nothing secret here.",
])
func keepsFalsePositives(input: String) {
    #expect(r.redact(input) == input)
}

@Test func fiftyThousandCharsRedactsFast() {
    let chunk = "Meeting at 14:30 with Alice, total 1 234,56 EUR, call 06 12 34 56 78, v10.15.7. "
        + "Card 4111 1111 1111 1111 and token=abc123 https://x.com/a?b=c "
    let text = String(repeating: chunk, count: 50_000 / chunk.count + 1)
    let clock = ContinuousClock()
    var out = ""
    let elapsed = clock.measure { out = r.redact(text) }
    #expect(!out.contains("4111"))
    #expect(elapsed < .milliseconds(500), "took \(elapsed)")
}

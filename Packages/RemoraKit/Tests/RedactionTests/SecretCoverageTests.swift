import Foundation
import Testing
@testable import Redaction

private let r = Redactor()

// MARK: - Leaks from the final review: every one must be redacted

@Test(arguments: [
    ("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "AWS_SECRET_ACCESS_KEY=[redacted]"),
    ("STRIPE_SECRET_KEY=example-value", "STRIPE_SECRET_KEY=[redacted]"),
    ("ANTHROPIC_API_KEY=abcdefghij0123456789abcdefghij0123456789", "ANTHROPIC_API_KEY=[redacted]"),
    (#"{"password": "p;a,s)s", "user": "ana"}"#, #"{"password": "[redacted]", "user": "ana"}"#),
    (#"{"client_secret":"x\"y;z"}"#, #"{"client_secret":"[redacted]"}"#),
    ("password: hunter2!", "password: [redacted]"),
    ("DB_PASSWORD = x9y8z7", "DB_PASSWORD = [redacted]"),
    ("db:\n  Password: 'p;a s'\n  host: x", "db:\n  Password: '[redacted]'\n  host: x"),
    ("export GITLAB_TOKEN='abc def'", "export GITLAB_TOKEN='[redacted]'"),
    ("private_key = abc123", "private_key = [redacted]"),
    ("ACCESSKEY: zz9", "ACCESSKEY: [redacted]"),
    ("passwd=letmein", "passwd=[redacted]"),
    ("key AIzaSyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q here", "key [redacted] here"),
    ("glpat-abcdefghij0123456789xyz", "[redacted]"),
    ("hf_abcdefghijklmnopqrstuvwxyz0123456", "[redacted]"),
    ("npm_abcdefghijklmnopqrstuvwxyz0123456789", "[redacted]"),
    ("use sk_test_FAKEONLY01 now", "use [redacted] now"),
    ("rk_live_abcdefghij0123456789", "[redacted]"),
    ("sk-ant-api03-abcdefghij0123456789", "[redacted]"),
    ("https://b.s3.amazonaws.com/f?X-Amz-Credential=AKIAX%2F20261120&X-Amz-Signature=9f8e7d6c5b4a&X-Amz-Security-Token=FQoG",
     "https://b.s3.amazonaws.com/f?X-Amz-Credential=[redacted]&X-Amz-Signature=[redacted]&X-Amz-Security-Token=[redacted]"),
    ("https://zoom.us/j/123?pwd=SeCrEt123", "https://zoom.us/j/123?pwd=[redacted]"),
    ("https://x.com/cb?code=abc&state=keep", "https://x.com/cb?code=[redacted]&state=keep"),
    ("https://x.com/cb?sig=abc&signature=def", "https://x.com/cb?sig=[redacted]&signature=[redacted]"),
    ("https://x.com/cb#access_token=abc.def&token_type=bearer", "https://x.com/cb#access_token=[redacted]&token_type=bearer"),
    ("https://x.com/cb#id_token=eyJabc&state=s", "https://x.com/cb#id_token=[redacted]&state=s"),
    ("credential near: Zx9Qw3Er7Ty1Ui5Op2As6Df0Gh4Jk8Lm", "credential near: [redacted]"),
    ("Sécu : 1 85 05 2A 006 084 35", "Sécu : [redacted]"),
    ("NIR 293032B12345671", "NIR [redacted]"),
])
func redactsReviewLeaks(input: String, expected: String) {
    #expect(r.redact(input) == expected)
}

// MARK: - Non-leaks that must be kept

@Test(arguments: [
    "commit 3f9fb9d0a1b2c3d4e5f60718293a4b5c6d7e8f90 fix things",
    "key 3f9fb9d0a1b2c3d4e5f60718293a4b5c6d7e8f90",  // labeled git SHA: entropy ≤ 4
    "request id 123e4567-e89b-12d3-a456-426614174000",
    "token count: 1234",
    "if (token == null) return",
    "let t = Token::new()",
    "Sécu : 1 85 05 2A 006 084 36",  // wrong key
    "img src=data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk",
    "Forgot your password? Reset it here.",
])
func keepsNonSecrets(input: String) {
    #expect(r.redact(input) == input)
}

@Test func entropyHeuristicNeedsLabelLettersAndDigits() {
    let tok = "Zx9Qw3Er7Ty1Ui5Op2As6Df0Gh4Jk8Lm"
    #expect(r.redact("auth \(tok)") == "auth [redacted]")
    // Far from any label: kept.
    let far = "Some prose without any label words at all, padded out to be long \(tok)"
    #expect(r.redact(far) == far)
    // Letters only (no digits): kept even when labeled.
    let letters = "secret is ZxQwErTyUiOpAsDfGhJkLmNbVcXzPoIuYt"
    #expect(r.redact(letters).contains("ZxQwErTyUiOpAsDfGhJkLmNbVcXzPoIuYt"))
    #expect(SecretsDetector.shannonEntropy("aaaa") == 0)
    #expect(SecretsDetector.shannonEntropy("3f9fb9d0a1b2c3d4e5f60718293a4b5c6d7e8f90") <= 4.0)
}

@Test func labeledRuleIsBoundedOnPathologicalInput() {
    let text = String(repeating: "tokentokentoken", count: 4_000) + " = x"
    let clock = ContinuousClock()
    let elapsed = clock.measure { _ = r.redact(text) }
    #expect(elapsed < .milliseconds(500), "took \(elapsed)")
}

// MARK: - Unquoted labeled values run to end of line (re-review minor)

@Test(arguments: [
    ("password: correct horse battery staple", "password: [redacted]"),
    ("PASSWORD=ab,cd", "PASSWORD=[redacted]"),
    ("api_key = a b; c) d", "api_key = [redacted]"),
    ("db_password: s3cr3t pass\nhost: db.internal", "db_password: [redacted]\nhost: db.internal"),
    ("SECRET=x y  \r\nNEXT=1", "SECRET=[redacted]  \r\nNEXT=1"),  // trailing spaces are not secret
    // Quoted values still stop at the closing quote.
    (#"password: "a b" # note"#, #"password: "[redacted]" # note"#),
    // URL query context: stops at & / # / whitespace.
    ("see https://x.com/?api_key=abc&page=2 then", "see https://x.com/?api_key=[redacted]&page=2 then"),
    // Connection-string context: stops at ;.
    ("Server=db;Password=a b,c;Database=x;", "Server=db;Password=[redacted];Database=x;"),
    // An exempt key never hides a real secret later on the same line.
    ("tokens: 5 password=hunter2 x", "tokens: 5 password=[redacted]"),
    ("PWD=/tmp DB_PASSWORD=x y", "PWD=/tmp DB_PASSWORD=[redacted]"),
    // CLI flag: stops at whitespace.
    ("run --password=hunter2 now", "run --password=[redacted] now"),
])
func unquotedLabeledValuesRunToEndOfLine(input: String, expected: String) {
    #expect(r.redact(input) == expected)
}

@Test(arguments: [
    "token count: 1234", "input_tokens: 1234, output_tokens: 99", "token_type: bearer",
    "if (token == null) return", "let t = Token::new()", "PWD=/Users/me/dev",
])
func labeledRuleNonLeaksKept(input: String) {
    #expect(r.redact(input) == input)
}

@Test func repeatedExemptKeysOnOneLineStayFast() {
    let text = String(repeating: "tokens: ", count: 6_250)  // 50,000 chars, one line
    let clock = ContinuousClock()
    let elapsed = clock.measure { _ = r.redact(text) }
    #expect(elapsed < .milliseconds(500), "took \(elapsed)")
}

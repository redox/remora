import Foundation

/// API keys, tokens, private keys, credentials in URLs/CLIs/env/JSON/YAML assignments, plus a
/// bounded high-entropy heuristic near key-like labels. Labeled forms redact the value
/// while preserving the label.
struct SecretsDetector: Detector {
    private static let patterns: [Pattern] = [
        Pattern(#"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}"#),  // OpenAI, also sk-ant- (Anthropic)
        Pattern(#"(?<![A-Za-z0-9])sk-ant-[A-Za-z0-9_-]{20,}"#),
        Pattern(#"(?<![A-Za-z0-9])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{10,}"#),  // Stripe secret/restricted
        Pattern(#"(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35,}"#),  // Google API key
        Pattern(#"(?<![A-Za-z0-9])glpat-[0-9A-Za-z_-]{20,}"#),  // GitLab PAT
        Pattern(#"(?<![A-Za-z0-9])hf_[A-Za-z0-9]{30,}"#),  // Hugging Face
        Pattern(#"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{36,}"#),  // npm
        Pattern(#"(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#),
        Pattern(#"(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}(?![A-Za-z0-9])"#),
        Pattern(#"(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}"#),
        Pattern(#"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"#),
        // Whole PEM block; an unterminated block (truncated capture) is redacted to the end.
        Pattern(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)"#),
        Pattern(#"Authorization:[ \t]*(?:Bearer|Basic)[ \t]+(\S+)"#, group: 1, options: [.caseInsensitive]),
        // scheme://user:PASSWORD@host
        Pattern(#"(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]{0,30}://[^\s/:@]{1,100}:([^\s/@]{1,200})@"#, group: 1),
        // URL query (and OAuth implicit-flow fragment) parameters.
        Pattern(#"(?<=[?&#])(?:token|access_token|id_token|refresh_token|api_key|apikey|key|secret|client_secret|password|pwd|code|sig|signature|x-amz-signature|x-amz-credential|x-amz-security-token)=([^\s&;,)\]"'#]+)"#,
                group: 1, options: [.caseInsensitive]),
        Pattern(#"--password(?:=|[ \t]+)(\S+)"#, group: 1, options: [.caseInsensitive]),
        Pattern(#"\b(?:mysql|psql)\b[^\n]{0,200}?[ \t]-p[ \t]*(\S+)"#, group: 1),
    ]

    /// Labeled assignments in env, shell, JSON and YAML: `DB_PASSWORD = x`, `"password": "p;a,s"`,
    /// `api_key: 'x'`. Groups: 1 = key, 2/3 = quoted value (inside the quotes, escapes
    /// honoured, so `;,)` inside quotes are covered), 4 = unquoted value, which runs to the end
    /// of the line (`password: correct horse battery staple`, `PASSWORD=ab,cd`) and is then
    /// cut by context in `unquotedValueEnd`. The separator must not be followed by `=`, `:` or
    /// `>` (code: `token == x`, `Token::new`, `token => x`). Labels are bounded (≤ 40 chars
    /// each side) and unquoted values to 2,000 chars, to keep matching linear even on a line
    /// of repeated exempt keys.
    private static let labeled = try! NSRegularExpression(pattern: #"""
        (?<![A-Za-z0-9_-])["']?([A-Za-z0-9_-]{0,40}(?:PASSWORD|PASSWD|PWD|SECRET|TOKEN|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CLIENT_?SECRET)[A-Za-z0-9_-]{0,40})["']?\s*[=:](?![=:>])\s*(?:"((?:[^"\\\n]|\\.)*)"|'((?:[^'\\\n]|\\.)*)'|([^\s"'][^\r\n]{0,2000}))
        """#, options: [.caseInsensitive])

    /// Keys that contain a keyword but name non-secret values.
    private static let nonSecretKeys: Set<String> = [
        "token_type", "tokentype", "tokens", "max_tokens", "input_tokens", "output_tokens",
        "total_tokens", "prompt_tokens", "completion_tokens",
    ]

    /// Candidate for the entropy heuristic: a run of ≥ 32 base64/url-safe characters.
    private static let entropyCandidate = Pattern(
        #"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/=_-]{32,}(?![A-Za-z0-9+/=_-])"#)
    private static let entropyLabels = ["key", "token", "secret", "password", "credential", "auth"]
    static let entropyLabelWindow = 40
    static let entropyThreshold = 4.0

    func ranges(in text: String) -> [Range<String.Index>] {
        Self.patterns.flatMap { $0.ranges(in: text) } + Self.labeledRanges(in: text)
            + Self.entropyRanges(in: text)
    }

    private static func labeledRanges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        let ns = text as NSString
        var location = 0
        while location < ns.length,
              let match = labeled.firstMatch(in: text, options: [],
                                             range: NSRange(location: location, length: ns.length - location)) {
            location = NSMaxRange(match.range)
            guard let keyRange = Range(match.range(at: 1), in: text),
                  let group = [2, 3, 4].first(where: { match.range(at: $0).location != NSNotFound }),
                  var value = Range(match.range(at: group), in: text), !value.isEmpty else { continue }
            let key = text[keyRange].lowercased()
            // Exempt keys: resume right after the key, so a value running to the end of the
            // line never hides a real secret later on it.
            let isShellDirectory = (key == "pwd" || key == "oldpwd")
                && (text[value].first == "/" || text[value].first == "~")
            if nonSecretKeys.contains(key) || isShellDirectory {
                location = NSMaxRange(match.range(at: 1))
                continue
            }
            if group == 4 {
                let before = match.range.location > 0 ? ns.character(at: match.range.location - 1) : 0
                value = value.lowerBound..<unquotedValueEnd(in: text, value: value, key: key,
                                                            contextBefore: Character(UnicodeScalar(before) ?? " "))
                guard !value.isEmpty else { continue }
            }
            out.append(value)
        }
        return out
    }

    /// End of an unquoted value: the end of the line, except in a URL query/fragment
    /// (`?k=v&…`: stops at `&`, `#` or whitespace), a connection string (`;k=v;…`: stops at
    /// `;`) and a CLI flag (`--password=x next`: stops at whitespace). Trailing whitespace is
    /// excluded.
    private static func unquotedValueEnd(in text: String, value: Range<String.Index>, key: String,
                                         contextBefore: Character) -> String.Index {
        let stop: (Character) -> Bool
        if key.hasPrefix("-") {
            stop = { $0.isWhitespace }
        } else if "?&#".contains(contextBefore) {
            stop = { $0 == "&" || $0 == "#" || $0.isWhitespace }
        } else if contextBefore == ";" {
            stop = { $0 == ";" }
        } else {
            stop = { _ in false }
        }
        var end = text[value].firstIndex(where: stop) ?? value.upperBound
        while end > value.lowerBound, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return end
    }

    /// A token of ≥ 32 chars with Shannon entropy > 4 bits/char, containing letters and
    /// digits, whose preceding 40 chars contain a key-like label. Hex (git SHAs) maxes out at
    /// 4 bits/char, so SHAs never qualify; unlabeled UUIDs/base64 blobs are left alone.
    private static func entropyRanges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        entropyCandidate.forEachMatch(in: text) { range, token in
            guard token.contains(where: { $0.isASCII && $0.isLetter }),
                  token.contains(where: { $0.isASCII && $0.isNumber }) else { return }
            let windowStart = text.index(range.lowerBound, offsetBy: -entropyLabelWindow,
                                         limitedBy: text.startIndex) ?? text.startIndex
            let window = text[windowStart..<range.lowerBound]
            guard entropyLabels.contains(where: { window.range(of: $0, options: .caseInsensitive) != nil }),
                  shannonEntropy(token) > entropyThreshold else { return }
            out.append(range)
        }
        return out
    }

    /// Shannon entropy in bits per character.
    static func shannonEntropy(_ s: some StringProtocol) -> Double {
        var counts: [Character: Int] = [:]
        for ch in s { counts[ch, default: 0] += 1 }
        let n = Double(s.count)
        guard n > 0 else { return 0 }
        return counts.values.reduce(0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }
}

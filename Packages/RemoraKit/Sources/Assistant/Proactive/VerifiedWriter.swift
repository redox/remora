import Foundation
import LLM
import Memory
import Redaction
import Storage
import os

// MARK: - Evidence

/// One titled part of the evidence ("Yesterday", "Due today"…). Lines are captured or derived
/// text: never log them.
public struct EvidenceSection: Sendable, Equatable {
    public var title: String
    public var lines: [String]
    public init(title: String, lines: [String]) { self.title = title; self.lines = lines }
}

/// A derived row the evidence was built from, with the snapshot ids it cited when read. Delivery
/// re-reads it inside its write: a row forgotten or rewritten meanwhile (forget does not bump the
/// data generation) discards the message.
public struct EvidenceSource: Sendable, Equatable {
    /// `chronicle`, `salient_flags` or `working_memory` (each has `snapshot_ids`).
    public var table: String
    public var id: Int64
    public var snapshotIDs: [Int64]
    public init(table: String, id: Int64, snapshotIDs: [Int64]) {
        self.table = table; self.id = id; self.snapshotIDs = snapshotIDs
    }
}

/// What a proactive message may say, already filtered by the current exclusions.
public struct ProactiveEvidence: Sendable, Equatable {
    public var sections: [EvidenceSection]
    public var sources: [EvidenceSource]

    public init(sections: [EvidenceSection], sources: [EvidenceSource] = []) {
        self.sections = sections; self.sources = sources
    }

    public var isEmpty: Bool { sections.allSatisfy(\.lines.isEmpty) }

    static let open = "<evidence>\n", close = "</evidence>"

    /// `<evidence>…</evidence>` with every title and line escaped and put on one line, at most
    /// `maxChars` characters in all. Each section gets an equal share of what is left, so one long
    /// section never crowds out the rest; a share a section does not use passes to the next ones.
    public func block(maxChars: Int) -> String {
        var remaining = maxChars - Self.open.count - Self.close.count
        var out = Self.open
        let shown = sections.filter { !$0.lines.isEmpty }
        for (i, s) in shown.enumerated() where remaining > 0 {
            let share = remaining / (shown.count - i)
            let header = "## " + Self.clean(s.title, max: 200) + "\n"
            guard header.count + 8 <= share else { continue }
            var chunk = header
            for raw in s.lines {
                let line = Self.clean(raw, max: share)
                if chunk.count + line.count + 3 <= share {
                    chunk += "- " + line + "\n"
                } else {
                    let room = share - chunk.count - 4   // "- " + "…" + "\n"
                    if room >= 20 { chunk += "- " + line.prefix(room) + "…\n" }
                    break
                }
            }
            out += chunk
            remaining -= chunk.count
        }
        return out + Self.close
    }

    /// One line, cut to `max` characters, escaped (escaping keeps the length).
    static func clean(_ s: String, max: Int) -> String {
        ProactivePrompt.escape(String(s.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(max)))
    }
}

// MARK: - Check schema

/// The checker's verdict: `supported` and the claims the evidence or the clock does not support.
public struct ProactiveCheckOutput: PipelineOutput, Equatable {
    public var supported: Bool
    public var unsupported: [String]

    public static let schemaName = "proactive_check"
    public static let schema = JSONSchema.object([
        "supported": JSONSchema.boolean,
        "unsupported": JSONSchema.array(JSONSchema.string()),
    ])
}

// MARK: - Writer

public enum WriterResult: Sendable, Equatable {
    case accepted(text: String, callIDs: [Int64])
    case rejected(unsupported: [String], callIDs: [Int64])
}

/// Generation and verification happen in separate passes:
/// a draft (the job's tier), a deterministic length check, then a small-model check of every claim
/// against the evidence and the clock. A failed check gets **one** rewrite, checked again; a draft
/// that still fails is rejected and never sent. The accepted text is redacted. Nothing here is
/// logged but counts.
public struct VerifiedWriter: Sendable {
    /// The evidence block's cap (pinned value).
    public static let evidenceChars = 16_000
    static let maxClaims = 10
    static let maxClaimChars = 200

    private let llm: LLMService
    private let redactor: Redactor
    private static let log = Logger(subsystem: "dev.remora", category: "proactive")

    public init(llm: LLMService, redactor: Redactor = .init()) {
        self.llm = llm; self.redactor = redactor
    }

    public func write(job: JobType, kind: InboxKind, evidence: ProactiveEvidence, task: String, maxChars: Int,
                      context: JobContext) async throws -> WriterResult {
        let block = evidence.block(maxChars: Self.evidenceChars)
        let instructions = ProactivePrompt.writer(kind, language: context.language, now: context.now,
                                                  calendar: context.calendar)
        var callIDs: [Int64] = []
        func complete(_ input: [InputItem]) async throws -> String {
            let r = try await llm.complete(job, instructions: instructions, input: input, cloudAllowed: context.cloudAllowed)
            if r.callID > 0 { callIDs.append(r.callID) }
            return r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func check(_ draft: String) async throws -> [String] {
            if draft.isEmpty || draft.count > maxChars { return [Self.lengthClaim] }
            let r = try await llm.complete(
                .evidenceCheck, instructions: ProactivePrompt.checker(now: context.now, calendar: context.calendar),
                input: [.user(block), .user(Self.draftSection(draft))],
                format: ProactiveCheckOutput.format, cloudAllowed: context.cloudAllowed)
            if r.callID > 0 { callIDs.append(r.callID) }
            let out = try ProactiveCheckOutput.decode(r.text)
            let claims = out.unsupported
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxClaimChars)) }
                .filter { !$0.isEmpty }
                .prefix(Self.maxClaims)
            if out.supported, claims.isEmpty { return [] }
            return claims.isEmpty ? ["unsupported"] : Array(claims)
        }

        let base: [InputItem] = [.user(block), .user(task)]
        var draft = try await complete(base)
        var unsupported = try await check(draft)
        if !unsupported.isEmpty {
            draft = try await complete(base + [.user(Self.draftSection(draft)),
                                               .user(Self.rewriteSection(unsupported, maxChars: maxChars))])
            unsupported = try await check(draft)
        }
        Self.log.info("proactive \(job.rawValue, privacy: .public): \(unsupported.isEmpty ? "accepted" : "rejected", privacy: .public), \(callIDs.count, privacy: .public) calls")
        guard unsupported.isEmpty else { return .rejected(unsupported: unsupported, callIDs: callIDs) }
        return .accepted(text: String(redactor.redact(draft).prefix(maxChars)), callIDs: callIDs)
    }

    static func draftSection(_ draft: String) -> String {
        "<draft>\n\(ProactivePrompt.escape(draft))\n</draft>"
    }

    /// The failed claims and the rewrite request; a failed length check (`"length"`) also asks
    /// for at most `maxChars` characters.
    static func rewriteSection(_ claims: [String], maxChars: Int) -> String {
        let lines = claims.map { "- " + ProactiveEvidence.clean($0, max: maxClaimChars) }.joined(separator: "\n")
        var request = ProactivePrompt.rewriteRequest
        if claims.contains(Self.lengthClaim) { request = ProactivePrompt.shorten(maxChars: maxChars) + " " + request }
        return "<unsupported>\n\(lines)\n</unsupported>\n\(request)"
    }

    static let lengthClaim = "length"
}

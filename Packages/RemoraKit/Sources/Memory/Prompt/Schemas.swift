import Foundation
import LLM
import Storage

/// A pipeline failure the scheduler retries. `code` (the case name) is what `jobs.last_error`
/// stores, never the model output (F-60).
public enum MemoryError: Error, Sendable, Equatable, CodedError {
    /// The model's answer did not decode as the requested schema.
    case invalidOutput(schema: String)

    public var code: String {
        switch self {
        case .invalidOutput: "invalid_output"
        }
    }
}

/// A structured-output schema and its `Decodable` mirror. Schemas follow the plan's rules (all
/// properties required, no nullable types, no `maxItems`: counts are capped in code, F-50).
public protocol PipelineOutput: Decodable, Sendable {
    /// The `jsonSchema` name.
    static var schemaName: String { get }
    static var schema: JSONValue { get }
}

extension PipelineOutput {
    public static var format: TextFormat { .jsonSchema(name: schemaName, schema: schema, strict: true) }

    /// Decodes the model's text; throws `MemoryError.invalidOutput` (no content) on any mismatch.
    public static func decode(_ text: String) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: Data(text.utf8)) } catch {
            throw MemoryError.invalidOutput(schema: schemaName)
        }
    }
}

// MARK: - hour_chronicle (hour call A)

public struct HourChronicleOutput: PipelineOutput, Equatable {
    public struct Project: Decodable, Sendable, Equatable {
        public var name: String
        public var apps: [String]
        public var domains: [String]
        public var share: Double
    }

    public var summary: String
    public var projects: [Project]
    public var highlights: [String]

    public static let schemaName = "hour_chronicle"
    public static let schema = JSONSchema.object([
        "summary": JSONSchema.string(),
        "projects": JSONSchema.array(JSONSchema.object([
            "name": JSONSchema.string(),
            "apps": JSONSchema.array(JSONSchema.string()),
            "domains": JSONSchema.array(JSONSchema.string()),
            "share": JSONSchema.number,
        ])),
        "highlights": JSONSchema.array(JSONSchema.string()),
    ])

    /// Output caps (plan pinned values; enforced here, not in the schema).
    public static let maxSummaryWords = 120
    public static let maxProjects = 8
    public static let maxHighlights = 5
    public static let maxNamesPerProject = 5
    public static let maxHighlightChars = 200
    /// Project names and each app or domain string in chronicle metadata.
    public static let maxNameChars = 80
}

// MARK: - hour_entities (hour call B)

/// Fact worth as the model reports it; `noise` facts are dropped before storage.
public enum FactWorthOutput: String, Decodable, Sendable, CaseIterable { case core, detail, noise }

public struct HourEntitiesOutput: PipelineOutput, Equatable {
    public struct Entity: Decodable, Sendable, Equatable {
        public var name: String
        public var type: WikiPageType
        public var aliases: [String]
        public var related: [String]
        public var evidence: [Int]
    }

    public struct Fact: Decodable, Sendable, Equatable {
        public var entity: String
        public var text: String
        public var subject: FactSubject
        public var basis: FactBasis
        public var worth: FactWorthOutput
        public var asOf: String
        public var supersedes: [Int64]
        public var evidence: [Int]

        enum CodingKeys: String, CodingKey {
            case entity, text, subject, basis, worth, supersedes, evidence
            case asOf = "as_of"
        }
    }

    public struct Flag: Decodable, Sendable, Equatable {
        public var kind: FlagKind
        public var owner: FlagOwner
        public var text: String
        public var person: String
        public var project: String
        public var due: String
        public var evidence: [Int]
        public var quote: String
    }

    public var entities: [Entity]
    public var facts: [Fact]
    public var flags: [Flag]

    public static let schemaName = "hour_entities"
    public static let schema = JSONSchema.object([
        "entities": JSONSchema.array(JSONSchema.object([
            "name": JSONSchema.string(),
            "type": JSONSchema.string(enum: WikiPageType.allCases.map(\.rawValue)),
            "aliases": JSONSchema.array(JSONSchema.string()),
            "related": JSONSchema.array(JSONSchema.string()),
            "evidence": JSONSchema.array(JSONSchema.integer),
        ])),
        "facts": JSONSchema.array(JSONSchema.object([
            "entity": JSONSchema.string(),
            "text": JSONSchema.string(),
            "subject": JSONSchema.string(enum: FactSubject.allCases.map(\.rawValue)),
            "basis": JSONSchema.string(enum: FactBasis.allCases.map(\.rawValue)),
            "worth": JSONSchema.string(enum: FactWorthOutput.allCases.map(\.rawValue)),
            "as_of": JSONSchema.string(),
            "supersedes": JSONSchema.array(JSONSchema.integer),
            "evidence": JSONSchema.array(JSONSchema.integer),
        ])),
        "flags": JSONSchema.array(JSONSchema.object([
            "kind": JSONSchema.string(enum: FlagKind.allCases.map(\.rawValue)),
            "owner": JSONSchema.string(enum: FlagOwner.allCases.map(\.rawValue)),
            "text": JSONSchema.string(),
            "person": JSONSchema.string(),
            "project": JSONSchema.string(),
            "due": JSONSchema.string(),
            "evidence": JSONSchema.array(JSONSchema.integer),
            "quote": JSONSchema.string(),
        ])),
    ])
}

// MARK: - rollup (day / week / month / year)

public struct RollupOutput: PipelineOutput, Equatable {
    public var summary: String
    public var projects: [String]
    public var highlights: [String]

    public static let schemaName = "rollup"
    public static let schema = JSONSchema.object([
        "summary": JSONSchema.string(),
        "projects": JSONSchema.array(JSONSchema.string()),
        "highlights": JSONSchema.array(JSONSchema.string()),
    ])
}

// MARK: - working_memory

public enum WorkingMemoryKind: String, Decodable, Sendable, CaseIterable { case task, topic, person, document, question }

public struct WorkingMemoryOutput: PipelineOutput, Equatable {
    public struct Item: Decodable, Sendable, Equatable {
        public var text: String
        public var kind: WorkingMemoryKind
        public var relevance: Double
        public var evidence: [Int]
    }

    public var items: [Item]

    public static let schemaName = "working_memory"
    public static let schema = JSONSchema.object([
        "items": JSONSchema.array(JSONSchema.object([
            "text": JSONSchema.string(),
            "kind": JSONSchema.string(enum: WorkingMemoryKind.allCases.map(\.rawValue)),
            "relevance": JSONSchema.number,
            "evidence": JSONSchema.array(JSONSchema.integer),
        ])),
    ])
}

// MARK: - wiki_page

public struct WikiPageOutput: PipelineOutput, Equatable {
    public var summary: String
    public var body: String
    public var links: [String]

    public static let schemaName = "wiki_page"
    public static let schema = JSONSchema.object([
        "summary": JSONSchema.string(),
        "body": JSONSchema.string(),
        "links": JSONSchema.array(JSONSchema.string()),
    ])

    /// Output caps (plan pinned values; enforced in code, not in the schema).
    public static let maxSummaryChars = 140
    public static let maxBodyWords = 300
}

// MARK: - memory_digest

public struct MemoryDigestOutput: PipelineOutput, Equatable {
    public var digest: String

    public static let schemaName = "memory_digest"
    public static let schema = JSONSchema.object(["digest": JSONSchema.string()])

    /// The stored body is cut to this many characters.
    public static let maxChars = 8_000
}

// MARK: - identity

public struct IdentityOutput: PipelineOutput, Equatable {
    public var identity: String

    public static let schemaName = "identity"
    public static let schema = JSONSchema.object(["identity": JSONSchema.string()])

    /// The model's text is cut to this many characters before the user's lines are re-added.
    public static let maxChars = 6_000
}

// MARK: - style_rules

public enum StyleScopeOutput: String, Decodable, Sendable, CaseIterable { case thisSurface = "this_surface", all }
public enum StyleKindOutput: String, Decodable, Sendable, CaseIterable { case format, lexical, tone }

public struct StyleRulesOutput: PipelineOutput, Equatable {
    public struct Rule: Decodable, Sendable, Equatable {
        public var scope: StyleScopeOutput
        public var kind: StyleKindOutput
        public var bullet: String
    }

    public var rules: [Rule]

    public static let schemaName = "style_rules"
    public static let schema = JSONSchema.object([
        "rules": JSONSchema.array(JSONSchema.object([
            "scope": JSONSchema.string(enum: StyleScopeOutput.allCases.map(\.rawValue)),
            "kind": JSONSchema.string(enum: StyleKindOutput.allCases.map(\.rawValue)),
            "bullet": JSONSchema.string(),
        ])),
    ])
}

// MARK: - loop_check

/// An open-loop check (job `evidenceCheck`): whether the evidence shows the owed outcome happened.
/// `evidence` is the 1-based snapshot number (0 for none) and `quote` is copied from it.
public struct LoopCheckOutput: PipelineOutput, Equatable {
    public var done: Bool
    public var confidence: Double
    public var evidence: Int
    public var quote: String

    public static let schemaName = "loop_check"
    public static let schema = JSONSchema.object([
        "done": JSONSchema.boolean,
        "confidence": JSONSchema.number,
        "evidence": JSONSchema.integer,
        "quote": JSONSchema.string(),
    ])
}

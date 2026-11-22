import Foundation

public enum LLMBackend: String, Codable, Sendable { case siwc, onDevice = "on_device", apiKey = "api_key" }

/// There is no `minimal` and no `none`: nil means "model default" (the `reasoning` field is omitted).
public enum ReasoningEffort: String, Codable, Sendable, CaseIterable { case low, medium, high }

public indirect enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Foundation representation for JSONSerialization.
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }
}

public struct FunctionCall: Sendable, Equatable, Codable {
    public var callID: String
    public var namespace: String?
    public var name: String
    public var arguments: String
    public init(callID: String, namespace: String? = nil, name: String, arguments: String) {
        self.callID = callID; self.namespace = namespace; self.name = name; self.arguments = arguments
    }
}

/// No system case, by construction: the system prompt travels in `instructions`.
public enum InputItem: Sendable, Equatable {
    case user(String)
    case assistant(String)
    case functionCall(FunctionCall)
    case functionCallOutput(callID: String, output: String)
}

public enum TextFormat: Sendable, Equatable {
    case text
    case jsonSchema(name: String, schema: JSONValue, strict: Bool)
}

public struct FunctionTool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public var strict: Bool
    public init(name: String, description: String, parameters: JSONValue, strict: Bool = true) {
        self.name = name; self.description = description; self.parameters = parameters; self.strict = strict
    }
}

public struct LLMRequest: Sendable, Equatable {
    public var model: String
    public var instructions: String
    public var input: [InputItem]
    public var reasoning: ReasoningEffort?
    public var format: TextFormat
    public var tools: [FunctionTool]
    public var toolChoiceRequired: Bool
    public init(model: String, instructions: String, input: [InputItem], reasoning: ReasoningEffort?,
                format: TextFormat = .text, tools: [FunctionTool] = [], toolChoiceRequired: Bool = false) {
        self.model = model; self.instructions = instructions; self.input = input; self.reasoning = reasoning
        self.format = format; self.tools = tools; self.toolChoiceRequired = toolChoiceRequired
    }
}

public struct LLMUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public init(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int, reasoningTokens: Int) {
        self.inputTokens = inputTokens; self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens; self.reasoningTokens = reasoningTokens
    }
    public static let zero = LLMUsage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0)
}

public enum LLMEvent: Sendable, Equatable {
    case textDelta(String)
    case functionCall(FunctionCall)
    case completed(LLMUsage)
}

public protocol LLMClient: Sendable {
    var backend: LLMBackend { get }
    /// Errors are `LLMError`. Cancelling the consuming task cancels the request.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, any Error>
}

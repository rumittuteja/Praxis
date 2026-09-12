import Foundation

// MARK: - Cache control

struct CacheControl: Codable, Hashable, Sendable {
    var type: String = "ephemeral"
    /// "5m" (default) or "1h".
    var ttl: String?

    static let ephemeral = CacheControl(type: "ephemeral", ttl: nil)
    static let oneHour = CacheControl(type: "ephemeral", ttl: "1h")
}

// MARK: - Content blocks

/// A block inside a message's content array.
///
/// Only the block kinds this app actually sends or reads are modeled. Unknown
/// block types decode into `.unknown` rather than throwing, so a new server
/// block kind can't break an in-flight session.
enum ContentBlock: Codable, Hashable, Sendable {
    // No default on `cacheControl`: Swift does not allow default values
    // for enum case associated values. Every call site passes it explicitly.
    case text(String, cacheControl: CacheControl?)
    case thinking(String, signature: String?)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, signature, id, name, input
        case toolUseID = "tool_use_id"
        case content
        case isError = "is_error"
        case cacheControl = "cache_control"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(
                try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                cacheControl: try c.decodeIfPresent(CacheControl.self, forKey: .cacheControl)
            )
        case "thinking":
            self = .thinking(
                try c.decodeIfPresent(String.self, forKey: .thinking) ?? "",
                signature: try c.decodeIfPresent(String.self, forKey: .signature)
            )
        case "tool_use":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:])
            )
        case "tool_result":
            self = .toolResult(
                toolUseID: try c.decode(String.self, forKey: .toolUseID),
                content: try c.decodeIfPresent(String.self, forKey: .content) ?? "",
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )
        default:
            self = .unknown(type: type)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let cacheControl):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(cacheControl, forKey: .cacheControl)
        case .thinking(let thinking, let signature):
            try c.encode("thinking", forKey: .type)
            try c.encode(thinking, forKey: .thinking)
            try c.encodeIfPresent(signature, forKey: .signature)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content, let isError):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseID, forKey: .toolUseID)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .isError)
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }
}

// MARK: - Messages

struct WireMessage: Codable, Hashable, Sendable {
    var role: String            // "user" | "assistant"
    var content: [ContentBlock]

    static func user(_ text: String, cacheControl: CacheControl? = nil) -> WireMessage {
        WireMessage(role: "user", content: [.text(text, cacheControl: cacheControl)])
    }

    static func assistant(_ blocks: [ContentBlock]) -> WireMessage {
        WireMessage(role: "assistant", content: blocks)
    }
}

// MARK: - Tools

struct ToolDefinition: Codable, Hashable, Sendable {
    var name: String
    var description: String
    var inputSchema: JSONValue
    /// Guarantees `tool_use.input` validates against the schema exactly.
    /// Requires `additionalProperties: false` and `required` in the schema.
    var strict: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, description, strict
        case inputSchema = "input_schema"
    }
}

struct ToolChoice: Codable, Hashable, Sendable {
    var type: String            // "auto" | "any" | "tool" | "none"
    var name: String?

    static let auto = ToolChoice(type: "auto", name: nil)
    static let none = ToolChoice(type: "none", name: nil)
    static func tool(_ name: String) -> ToolChoice { ToolChoice(type: "tool", name: name) }
}

// MARK: - Thinking & effort

struct ThinkingConfig: Codable, Hashable, Sendable {
    /// "adaptive" on every model this app targets. `budget_tokens` is removed
    /// on Opus 5 / Sonnet 5 and returns a 400 if sent.
    var type: String
    /// "summarized" surfaces a readable reasoning summary; the default,
    /// "omitted", returns empty thinking blocks.
    var display: String?

    static let adaptive = ThinkingConfig(type: "adaptive", display: nil)
    static let adaptiveVisible = ThinkingConfig(type: "adaptive", display: "summarized")
}

struct OutputConfig: Codable, Hashable, Sendable {
    /// "low" | "medium" | "high" | "xhigh" | "max". Defaults to high server-side.
    var effort: String?
}

// MARK: - Request

/// One Messages API request.
///
/// The same struct serializes for both providers; `encode(to:)` branches on
/// `bedrockStyle`, because Bedrock takes the model in the URL path and needs
/// an `anthropic_version` in the body, while the first-party API is the
/// reverse.
struct MessagesRequest: Codable, Sendable {
    var model: String
    var maxTokens: Int
    var messages: [WireMessage]
    var system: [ContentBlock]?
    var tools: [ToolDefinition]?
    var toolChoice: ToolChoice?
    var thinking: ThinkingConfig?
    var outputConfig: OutputConfig?
    var stream: Bool?

    /// Set by `BedrockProvider` before encoding. Not part of the API surface.
    var bedrockStyle: Bool = false

    private enum CodingKeys: String, CodingKey {
        case model, messages, system, tools, thinking, stream
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
        case outputConfig = "output_config"
        case anthropicVersion = "anthropic_version"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if bedrockStyle {
            // Bedrock InvokeModel: model lives in the URL, and the body must
            // carry the Bedrock-specific version discriminator.
            try c.encode("bedrock-2023-05-31", forKey: .anthropicVersion)
        } else {
            try c.encode(model, forKey: .model)
        }
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(system, forKey: .system)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try c.encodeIfPresent(thinking, forKey: .thinking)
        try c.encodeIfPresent(outputConfig, forKey: .outputConfig)
        try c.encodeIfPresent(stream, forKey: .stream)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        maxTokens = try c.decode(Int.self, forKey: .maxTokens)
        messages = try c.decode([WireMessage].self, forKey: .messages)
        system = try c.decodeIfPresent([ContentBlock].self, forKey: .system)
        tools = try c.decodeIfPresent([ToolDefinition].self, forKey: .tools)
        toolChoice = try c.decodeIfPresent(ToolChoice.self, forKey: .toolChoice)
        thinking = try c.decodeIfPresent(ThinkingConfig.self, forKey: .thinking)
        outputConfig = try c.decodeIfPresent(OutputConfig.self, forKey: .outputConfig)
        stream = try c.decodeIfPresent(Bool.self, forKey: .stream)
        bedrockStyle = false
    }

    init(
        model: String,
        maxTokens: Int,
        messages: [WireMessage],
        system: [ContentBlock]? = nil,
        tools: [ToolDefinition]? = nil,
        toolChoice: ToolChoice? = nil,
        thinking: ThinkingConfig? = .adaptive,
        outputConfig: OutputConfig? = nil,
        stream: Bool? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.messages = messages
        self.system = system
        self.tools = tools
        self.toolChoice = toolChoice
        self.thinking = thinking
        self.outputConfig = outputConfig
        self.stream = stream
    }
}

// MARK: - Response

struct WireUsage: Codable, Hashable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    var asStats: UsageStats {
        UsageStats(
            inputTokens: inputTokens ?? 0,
            outputTokens: outputTokens ?? 0,
            cacheCreationInputTokens: cacheCreationInputTokens ?? 0,
            cacheReadInputTokens: cacheReadInputTokens ?? 0
        )
    }
}

/// Populated only when `stopReason == "refusal"`; null for every other stop
/// reason, so always check `stopReason` before reading it.
struct StopDetails: Codable, Hashable, Sendable {
    var type: String?
    var category: String?
    var explanation: String?
}

struct MessagesResponse: Codable, Sendable {
    var id: String?
    var model: String?
    var role: String?
    var content: [ContentBlock]
    var stopReason: String?
    var stopDetails: StopDetails?
    var usage: WireUsage?

    private enum CodingKeys: String, CodingKey {
        case id, model, role, content, usage
        case stopReason = "stop_reason"
        case stopDetails = "stop_details"
    }

    /// All text blocks joined. Thinking blocks are deliberately excluded.
    var text: String {
        content.compactMap { block in
            if case .text(let t, _) = block { return t }
            return nil
        }.joined()
    }

    /// First tool call matching `name`, if any. Structured output arrives this
    /// way, and thinking blocks precede it, so this scans rather than indexes.
    func toolInput(named name: String) -> JSONValue? {
        for block in content {
            if case .toolUse(_, let blockName, let input) = block, blockName == name {
                return input
            }
        }
        return nil
    }

    var wasRefused: Bool { stopReason == "refusal" }
    var hitTokenCap: Bool { stopReason == "max_tokens" }
}

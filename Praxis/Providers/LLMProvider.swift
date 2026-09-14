import Foundation

/// Errors surfaced to the UI. Each case maps to a message the learner can act
/// on — "add your key in Settings", "you're rate limited", "the model
/// declined" — rather than a raw status code.
enum LLMError: LocalizedError, Sendable {
    case missingCredentials(ProviderKind)
    case invalidConfiguration(String)
    case http(status: Int, body: String)
    case rateLimited(retryAfter: TimeInterval?)
    case refused(category: String?, explanation: String?)
    case truncated
    case malformedResponse(String)
    case transport(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let kind):
            switch kind {
            case .anthropic:
                return String(localized: "No Anthropic API key saved. Add one in Settings.",
                              comment: "Error shown when the Anthropic key is missing")
            case .bedrock:
                return String(localized: "No AWS credentials saved. Add an access key and secret in Settings.",
                              comment: "Error shown when AWS credentials are missing")
            }
        case .invalidConfiguration(let detail):
            return detail
        case .http(let status, let body):
            return String(localized: "The API returned \(status). \(Self.condense(body))",
                          comment: "HTTP error. First placeholder is a status code, second the server message")
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return String(localized: "Rate limited. Try again in about \(Int(retryAfter.rounded())) seconds.",
                              comment: "Rate limit error with a retry delay in seconds")
            }
            return String(localized: "Rate limited. Wait a moment and try again.",
                       comment: "Rate limit error with no retry delay given")
        case .refused(let category, let explanation):
            let reason = explanation ?? String(localized: "The model declined this request.",
                                               comment: "Fallback when the model refuses without an explanation")
            if let category { return "\(reason) (category: \(category))" }
            return reason
        case .truncated:
            return String(localized: "The response hit the token cap before finishing.",
                          comment: "Response was truncated by max_tokens")
        case .malformedResponse(let detail):
            return String(localized: "Could not read the model's response. \(detail)",
                          comment: "Malformed response. Placeholder is a technical detail")
        case .transport(let detail):
            return String(localized: "Network problem: \(detail)",
                          comment: "Transport failure. Placeholder is the system error text")
        case .cancelled:
            return String(localized: "Cancelled.", comment: "The request was cancelled by the user")
        }
    }

    /// Whether retrying the identical request could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .rateLimited: return true
        case .transport: return true
        case .http(let status, _): return status >= 500 || status == 408 || status == 409
        default: return false
        }
    }

    private static func condense(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Surface the API's own error message when the body is the standard
        // {"type":"error","error":{"type":..,"message":..}} envelope.
        if let data = trimmed.data(using: .utf8),
           let root = try? JSONDecoder().decode(JSONValue.self, from: data),
           let message = root["error"]?["message"]?.stringValue {
            return message
        }
        return String(trimmed.prefix(300))
    }
}

/// Incremental output from a streaming request.
enum StreamEvent: Sendable {
    /// A chunk of visible answer text.
    case textDelta(String)
    /// A chunk of summarized reasoning, when `thinking.display` is "summarized".
    case thinkingDelta(String)
    /// The complete assembled response. Always the last event on success.
    case completed(MessagesResponse)
}

/// One way of talking to Claude. Implemented twice: first-party API and
/// Bedrock. Everything above this protocol is provider-agnostic, which is what
/// makes the side-by-side comparison in Settings possible.
protocol LLMProvider: Sendable {
    var kind: ProviderKind { get }

    /// Human-readable description of where requests are going, shown in the
    /// request inspector (e.g. "bedrock-runtime.us-east-1.amazonaws.com").
    var endpointDescription: String { get }

    func send(_ request: MessagesRequest) async throws -> MessagesResponse

    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

extension LLMProvider {
    /// Send and validate in one step: refusals and truncation become thrown
    /// errors so callers don't have to remember to check `stopReason`.
    func sendChecked(_ request: MessagesRequest) async throws -> MessagesResponse {
        let response = try await send(request)
        if response.wasRefused {
            throw LLMError.refused(
                category: response.stopDetails?.category,
                explanation: response.stopDetails?.explanation
            )
        }
        if response.hitTokenCap { throw LLMError.truncated }
        return response
    }
}

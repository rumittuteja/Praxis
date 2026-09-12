import Foundation

/// Rebuilds a complete `MessagesResponse` from the streaming event sequence.
///
/// Both transports carry the *same* JSON event objects — the first-party API
/// wraps them in SSE frames, Bedrock wraps them in `vnd.amazon.eventstream`
/// binary frames — so this accumulator is shared and both providers stay thin.
struct StreamAccumulator {

    private struct PartialBlock {
        var type: String
        var text: String = ""
        var thinking: String = ""
        var signature: String?
        var toolID: String = ""
        var toolName: String = ""
        var partialJSON: String = ""
    }

    private var blocks: [Int: PartialBlock] = [:]
    private var order: [Int] = []

    private(set) var messageID: String?
    private(set) var model: String?
    private(set) var stopReason: String?
    private(set) var stopDetails: StopDetails?
    private var usage = WireUsage()

    /// Feed one decoded event object. Returns a user-visible delta, if any.
    mutating func consume(_ event: JSONValue) throws -> StreamEvent? {
        guard let type = event["type"]?.stringValue else { return nil }

        switch type {
        case "message_start":
            guard let message = event["message"] else { return nil }
            messageID = message["id"]?.stringValue
            model = message["model"]?.stringValue
            if let u = message["usage"] { mergeUsage(u) }
            return nil

        case "content_block_start":
            guard let index = event["index"]?.intValue,
                  let block = event["content_block"],
                  let blockType = block["type"]?.stringValue else { return nil }
            var partial = PartialBlock(type: blockType)
            partial.text = block["text"]?.stringValue ?? ""
            partial.thinking = block["thinking"]?.stringValue ?? ""
            partial.toolID = block["id"]?.stringValue ?? ""
            partial.toolName = block["name"]?.stringValue ?? ""
            blocks[index] = partial
            if !order.contains(index) { order.append(index) }
            return nil

        case "content_block_delta":
            guard let index = event["index"]?.intValue,
                  let delta = event["delta"],
                  let deltaType = delta["type"]?.stringValue,
                  var partial = blocks[index] else { return nil }
            switch deltaType {
            case "text_delta":
                let chunk = delta["text"]?.stringValue ?? ""
                partial.text += chunk
                blocks[index] = partial
                return chunk.isEmpty ? nil : .textDelta(chunk)
            case "thinking_delta":
                let chunk = delta["thinking"]?.stringValue ?? ""
                partial.thinking += chunk
                blocks[index] = partial
                return chunk.isEmpty ? nil : .thinkingDelta(chunk)
            case "signature_delta":
                partial.signature = (partial.signature ?? "") + (delta["signature"]?.stringValue ?? "")
                blocks[index] = partial
                return nil
            case "input_json_delta":
                // Tool inputs arrive as a string of JSON fragments that is only
                // valid once the block closes — never parse it mid-stream.
                partial.partialJSON += delta["partial_json"]?.stringValue ?? ""
                blocks[index] = partial
                return nil
            default:
                return nil
            }

        case "content_block_stop":
            return nil

        case "message_delta":
            if let delta = event["delta"] {
                stopReason = delta["stop_reason"]?.stringValue ?? stopReason
                if let details = delta["stop_details"], details != .null {
                    stopDetails = try? details.decode(as: StopDetails.self)
                }
            }
            if let u = event["usage"] { mergeUsage(u) }
            return nil

        case "message_stop":
            return .completed(finish())

        case "error":
            let message = event["error"]?["message"]?.stringValue ?? "Unknown streaming error"
            throw LLMError.malformedResponse(message)

        default:
            // "ping" and any event type added after this was written.
            return nil
        }
    }

    private mutating func mergeUsage(_ value: JSONValue) {
        if let v = value["input_tokens"]?.intValue { usage.inputTokens = v }
        if let v = value["output_tokens"]?.intValue { usage.outputTokens = v }
        if let v = value["cache_creation_input_tokens"]?.intValue { usage.cacheCreationInputTokens = v }
        if let v = value["cache_read_input_tokens"]?.intValue { usage.cacheReadInputTokens = v }
    }

    /// Assemble the final response. Safe to call even if `message_stop` never
    /// arrived, which is how a dropped connection still yields partial text.
    mutating func finish() -> MessagesResponse {
        var content: [ContentBlock] = []
        for index in order.sorted() {
            guard let partial = blocks[index] else { continue }
            switch partial.type {
            case "text":
                content.append(.text(partial.text, cacheControl: nil))
            case "thinking":
                content.append(.thinking(partial.thinking, signature: partial.signature))
            case "tool_use":
                let input: JSONValue
                if let data = partial.partialJSON.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    input = parsed
                } else {
                    input = .object([:])
                }
                content.append(.toolUse(id: partial.toolID, name: partial.toolName, input: input))
            default:
                content.append(.unknown(type: partial.type))
            }
        }
        return MessagesResponse(
            id: messageID,
            model: model,
            role: "assistant",
            content: content,
            stopReason: stopReason,
            stopDetails: stopDetails,
            usage: usage
        )
    }
}

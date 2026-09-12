import Testing
import Foundation
@testable import Praxis

/// Builds `vnd.amazon.eventstream` frames so the decoder can be tested without
/// a live Bedrock connection.
private enum FrameBuilder {

    static func header(name: String, value: String) -> Data {
        var out = Data()
        let nameBytes = Array(name.utf8)
        out.append(UInt8(nameBytes.count))
        out.append(contentsOf: nameBytes)
        out.append(7)                                   // value type 7 == string
        let valueBytes = Array(value.utf8)
        out.append(UInt8((valueBytes.count >> 8) & 0xFF))
        out.append(UInt8(valueBytes.count & 0xFF))
        out.append(contentsOf: valueBytes)
        return out
    }

    static func frame(headers: [(String, String)], payload: Data) -> Data {
        var headerBlock = Data()
        for (name, value) in headers { headerBlock.append(header(name: name, value: value)) }

        let totalLength = 12 + headerBlock.count + payload.count + 4
        var out = Data()
        out.append(bigEndian(UInt32(totalLength)))
        out.append(bigEndian(UInt32(headerBlock.count)))
        out.append(bigEndian(UInt32(0)))                // prelude CRC (not verified)
        out.append(headerBlock)
        out.append(payload)
        out.append(bigEndian(UInt32(0)))                // message CRC (not verified)
        return out
    }

    /// A Bedrock chunk: the frame payload wraps the Anthropic event in base64.
    static func chunk(event: String) -> Data {
        let inner = Data(event.utf8).base64EncodedString()
        let payload = Data(#"{"bytes":"\#(inner)"}"#.utf8)
        return frame(
            headers: [(":message-type", "event"), (":event-type", "chunk"),
                      (":content-type", "application/json")],
            payload: payload
        )
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
              UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}

@Suite("AWS event stream decoding")
struct EventStreamTests {

    @Test("A single complete frame decodes with its headers and payload")
    func singleFrame() throws {
        var decoder = AWSEventStreamDecoder()
        decoder.append(FrameBuilder.frame(
            headers: [(":message-type", "event"), (":event-type", "chunk")],
            payload: Data("hello".utf8)
        ))
        let messages = try decoder.drain()
        #expect(messages.count == 1)
        #expect(messages[0].messageType == "event")
        #expect(messages[0].eventType == "chunk")
        #expect(String(data: messages[0].payload, encoding: .utf8) == "hello")
    }

    @Test("A frame split across arbitrary byte boundaries still decodes")
    func splitAcrossChunks() throws {
        let full = FrameBuilder.frame(
            headers: [(":message-type", "event")],
            payload: Data("payload-content".utf8)
        )
        var decoder = AWSEventStreamDecoder()

        // Feed one byte at a time, which is how URLSession's AsyncBytes arrives.
        var produced: [AWSEventStreamMessage] = []
        for byte in full {
            decoder.append(byte)
            produced.append(contentsOf: try decoder.drain())
        }
        #expect(produced.count == 1)
        #expect(String(data: produced[0].payload, encoding: .utf8) == "payload-content")
    }

    @Test("Several frames in one buffer all decode, in order")
    func multipleFrames() throws {
        var buffer = Data()
        buffer.append(FrameBuilder.frame(headers: [(":event-type", "a")], payload: Data("one".utf8)))
        buffer.append(FrameBuilder.frame(headers: [(":event-type", "b")], payload: Data("two".utf8)))

        var decoder = AWSEventStreamDecoder()
        decoder.append(buffer)
        let messages = try decoder.drain()
        #expect(messages.count == 2)
        #expect(messages[0].eventType == "a")
        #expect(messages[1].eventType == "b")
    }

    @Test("A partial frame yields nothing and waits for the rest")
    func partialFrameWaits() throws {
        let full = FrameBuilder.frame(headers: [(":event-type", "x")], payload: Data("abc".utf8))
        var decoder = AWSEventStreamDecoder()
        decoder.append(full.prefix(full.count - 3))
        #expect(try decoder.drain().isEmpty)

        decoder.append(full.suffix(3))
        #expect(try decoder.drain().count == 1)
    }

    @Test("An implausible length prefix is rejected rather than allocated")
    func rejectsBadLength() {
        var decoder = AWSEventStreamDecoder()
        // total length 0xFFFFFFFF, far beyond the guard.
        decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
                             0x00, 0x00, 0x00, 0x00]))
        #expect(throws: LLMError.self) { try decoder.drain() }
    }

    @Test("A Bedrock chunk double-wraps the Anthropic event in base64")
    func bedrockChunkUnwrapping() throws {
        // Bedrock nests the event twice: the binary frame carries JSON, and
        // that JSON's `bytes` field is base64 of the ordinary Anthropic event.
        let inner = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}"#
        var decoder = AWSEventStreamDecoder()
        decoder.append(FrameBuilder.chunk(event: inner))

        let frame = try #require(try decoder.drain().first)
        #expect(frame.eventType == "chunk")

        let outer = try JSONDecoder().decode(JSONValue.self, from: frame.payload)
        let encoded = try #require(outer["bytes"]?.stringValue)
        let decoded = try #require(Data(base64Encoded: encoded))
        let event = try JSONDecoder().decode(JSONValue.self, from: decoded)
        #expect(event["type"]?.stringValue == "content_block_delta")
        #expect(event["delta"]?["text"]?.stringValue == "hi")
    }

    @Test("Non-string header types are skipped without corrupting later headers")
    func mixedHeaderTypes() {
        var block = Data()
        // A boolean-true header (type 0, no value bytes).
        block.append(UInt8("flag".utf8.count))
        block.append(contentsOf: Array("flag".utf8))
        block.append(0)
        // Then a normal string header.
        block.append(FrameBuilder.header(name: ":event-type", value: "chunk"))

        let headers = AWSEventStreamDecoder.parseHeaders(block)
        #expect(headers["flag"] == "true")
        #expect(headers[":event-type"] == "chunk")
    }
}

@Suite("Stream accumulation")
struct StreamAccumulatorTests {

    private func event(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test("Text deltas accumulate into a complete message")
    func textDeltas() throws {
        var accumulator = StreamAccumulator()
        _ = try accumulator.consume(event(#"{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5","usage":{"input_tokens":100}}}"#))
        _ = try accumulator.consume(event(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
        _ = try accumulator.consume(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}"#))
        _ = try accumulator.consume(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}"#))
        _ = try accumulator.consume(event(#"{"type":"content_block_stop","index":0}"#))
        _ = try accumulator.consume(event(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#))

        let final = try #require(accumulator.consume(event(#"{"type":"message_stop"}"#)))
        guard case .completed(let response) = final else {
            Issue.record("expected a completed event"); return
        }
        #expect(response.text == "Hello world")
        #expect(response.id == "msg_1")
        #expect(response.stopReason == "end_turn")
        #expect(response.usage?.inputTokens == 100)
        #expect(response.usage?.outputTokens == 7)
    }

    @Test("Tool input JSON fragments are only parsed once the block closes")
    func toolInputAssembly() throws {
        var accumulator = StreamAccumulator()
        _ = try accumulator.consume(event(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"emit_lesson"}}"#))
        // Deliberately split mid-token, which is what the API actually sends.
        for fragment in [#"{"tit"#, #"le":"A"#, #" Lesson"}"#] {
            let json = try JSONEncoder().encode(fragment)
            let fragmentJSON = String(data: json, encoding: .utf8) ?? "\"\""
            _ = try accumulator.consume(event(
                #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":\#(fragmentJSON)}}"#
            ))
        }
        _ = try accumulator.consume(event(#"{"type":"content_block_stop","index":0}"#))

        let response = accumulator.finish()
        let input = try #require(response.toolInput(named: "emit_lesson"))
        #expect(input["title"]?.stringValue == "A Lesson")
    }

    @Test("Thinking deltas surface separately from answer text")
    func thinkingDeltas() throws {
        var accumulator = StreamAccumulator()
        _ = try accumulator.consume(event(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#))
        let emitted = try accumulator.consume(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"considering"}}"#))
        guard case .thinkingDelta(let chunk)? = emitted else {
            Issue.record("expected a thinking delta"); return
        }
        #expect(chunk == "considering")
        // Thinking is not part of the visible answer.
        #expect(accumulator.finish().text.isEmpty)
    }

    @Test("A stream cut short still yields the partial content")
    func truncatedStream() throws {
        var accumulator = StreamAccumulator()
        _ = try accumulator.consume(event(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
        _ = try accumulator.consume(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#))
        // No message_stop — the connection dropped.
        #expect(accumulator.finish().text == "partial")
    }

    @Test("An error event throws rather than being silently dropped")
    func errorEvent() throws {
        var accumulator = StreamAccumulator()
        #expect(throws: LLMError.self) {
            _ = try accumulator.consume(event(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
        }
    }

    @Test("Unknown event types are ignored")
    func unknownEvents() throws {
        var accumulator = StreamAccumulator()
        #expect(try accumulator.consume(event(#"{"type":"ping"}"#)) == nil)
        #expect(try accumulator.consume(event(#"{"type":"something_new_in_2027"}"#)) == nil)
    }
}

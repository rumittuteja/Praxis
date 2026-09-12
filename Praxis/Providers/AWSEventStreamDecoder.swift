import Foundation

/// One decoded `vnd.amazon.eventstream` frame.
struct AWSEventStreamMessage: Sendable {
    /// Frame headers. Only string-valued headers are retained — the ones
    /// Bedrock uses (`:message-type`, `:event-type`, `:exception-type`,
    /// `:content-type`) are all strings.
    var headers: [String: String]
    var payload: Data

    var messageType: String? { headers[":message-type"] }
    var eventType: String? { headers[":event-type"] }
    var exceptionType: String? { headers[":exception-type"] }
}

/// Incremental decoder for the AWS binary event-stream framing used by
/// Bedrock's `invoke-with-response-stream`.
///
/// Frame layout:
/// ```
/// [ total length : uint32 ]
/// [ headers length : uint32 ]
/// [ prelude CRC32 : uint32 ]
/// [ headers : headersLength bytes ]
/// [ payload : totalLength - headersLength - 16 bytes ]
/// [ message CRC32 : uint32 ]
/// ```
/// Feed bytes in as they arrive; `drain()` returns whatever complete frames
/// the buffer now holds.
///
/// The two CRC fields are skipped rather than verified. TLS already protects
/// against corruption on the wire, and a CRC mismatch here would have no
/// recovery path better than the surrounding error handling.
struct AWSEventStreamDecoder {

    private var buffer = Data()

    /// Guards against a malformed length prefix turning into a huge allocation.
    private static let maxFrameLength = 16 * 1024 * 1024

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func append(_ byte: UInt8) {
        buffer.append(byte)
    }

    /// Pull every complete frame currently buffered.
    mutating func drain() throws -> [AWSEventStreamMessage] {
        var messages: [AWSEventStreamMessage] = []
        while let message = try nextMessage() {
            messages.append(message)
        }
        return messages
    }

    var hasBufferedBytes: Bool { !buffer.isEmpty }

    private mutating func nextMessage() throws -> AWSEventStreamMessage? {
        guard buffer.count >= 12 else { return nil }

        let totalLength = Int(readUInt32(at: 0))
        let headersLength = Int(readUInt32(at: 4))

        guard totalLength >= 16, totalLength <= Self.maxFrameLength,
              headersLength >= 0, headersLength <= totalLength - 16 else {
            throw LLMError.malformedResponse("Event stream frame has an implausible length prefix.")
        }
        // Wait for the whole frame.
        guard buffer.count >= totalLength else { return nil }

        // All offsets are taken relative to startIndex: a Data that has been
        // sliced does not necessarily start at 0.
        let base = buffer.startIndex
        let headersStart = base + 12
        let headersEnd = headersStart + headersLength
        let payloadEnd = base + totalLength - 4     // trailing message CRC

        let headerBytes = buffer.subdata(in: headersStart..<headersEnd)
        let payload = buffer.subdata(in: headersEnd..<payloadEnd)

        buffer.removeSubrange(base..<(base + totalLength))

        return AWSEventStreamMessage(
            headers: Self.parseHeaders(headerBytes),
            payload: payload
        )
    }

    /// Big-endian uint32 read relative to the start of `buffer`.
    private func readUInt32(at offset: Int) -> UInt32 {
        let base = buffer.startIndex + offset
        return (UInt32(buffer[base]) << 24)
            | (UInt32(buffer[base + 1]) << 16)
            | (UInt32(buffer[base + 2]) << 8)
            | UInt32(buffer[base + 3])
    }

    /// Header wire format, repeated until the block is consumed:
    /// `[name length: uint8][name][value type: uint8][value...]`
    static func parseHeaders(_ data: Data) -> [String: String] {
        var headers: [String: String] = [:]
        var index = data.startIndex

        func remaining() -> Int { data.endIndex - index }
        func byte() -> UInt8? {
            guard remaining() >= 1 else { return nil }
            defer { index += 1 }
            return data[index]
        }
        func uint16() -> Int? {
            guard remaining() >= 2 else { return nil }
            let value = (Int(data[index]) << 8) | Int(data[index + 1])
            index += 2
            return value
        }
        func skip(_ count: Int) -> Bool {
            guard remaining() >= count else { return false }
            index += count
            return true
        }

        while remaining() > 0 {
            guard let nameLength = byte(), remaining() >= Int(nameLength) else { break }
            let nameData = data.subdata(in: index..<(index + Int(nameLength)))
            index += Int(nameLength)
            let name = String(data: nameData, encoding: .utf8) ?? ""

            guard let valueType = byte() else { break }
            switch valueType {
            case 0: headers[name] = "true"          // bool true, no payload
            case 1: headers[name] = "false"         // bool false, no payload
            case 2: guard skip(1) else { return headers }   // byte
            case 3: guard skip(2) else { return headers }   // short
            case 4: guard skip(4) else { return headers }   // integer
            case 5: guard skip(8) else { return headers }   // long
            case 6:                                          // byte array
                guard let length = uint16(), skip(length) else { return headers }
            case 7:                                          // string
                guard let length = uint16(), remaining() >= length else { return headers }
                let valueData = data.subdata(in: index..<(index + length))
                index += length
                headers[name] = String(data: valueData, encoding: .utf8) ?? ""
            case 8: guard skip(8) else { return headers }   // timestamp
            case 9: guard skip(16) else { return headers }  // uuid
            default:
                // Unknown type: the remaining bytes can't be walked safely.
                return headers
            }
        }
        return headers
    }
}

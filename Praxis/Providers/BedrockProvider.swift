import Foundation

/// Talks to Amazon Bedrock's `InvokeModel` / `InvokeModelWithResponseStream`.
///
/// Three things differ from the first-party API, and each one is a lesson in
/// the AWS track:
///  1. Auth is SigV4 over AWS credentials, not a bearer key.
///  2. The model ID lives in the URL path and carries an `anthropic.` prefix;
///     the body instead carries `anthropic_version: "bedrock-2023-05-31"`.
///  3. Streaming is AWS's binary event-stream framing, not SSE — though the
///     JSON events inside the frames are byte-identical to the first-party
///     ones, which is why `StreamAccumulator` is shared.
struct BedrockProvider: LLMProvider {

    let kind: ProviderKind = .bedrock
    let region: String
    let credentials: AWSCredentials

    var endpointDescription: String { "bedrock-runtime.\(region).amazonaws.com" }

    private var host: String { "bedrock-runtime.\(region).amazonaws.com" }

    private func url(modelID: String, streaming: Bool) throws -> URL {
        let action = streaming ? "invoke-with-response-stream" : "invoke"
        let encodedModel = SigV4Signer.uriEncode(modelID, encodeSlash: true)
        guard let url = URL(string: "https://\(host)/model/\(encodedModel)/\(action)") else {
            throw LLMError.invalidConfiguration("Could not build a Bedrock URL for model \(modelID).")
        }
        return url
    }

    private func signedRequest(_ body: MessagesRequest, streaming: Bool) throws -> URLRequest {
        var payload = body
        payload.bedrockStyle = true
        payload.stream = nil          // Bedrock selects streaming by endpoint, not by a body flag.

        var request = URLRequest(url: try url(modelID: body.model, streaming: streaming))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try HTTPSupport.encoder.encode(payload)

        let signer = SigV4Signer(region: region, service: "bedrock", credentials: credentials)
        return try signer.sign(request)
    }

    // MARK: Non-streaming

    func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        let urlRequest = try signedRequest(request, streaming: false)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTPSupport.session.data(for: urlRequest)
        } catch {
            throw HTTPSupport.transportError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse("Response was not HTTP.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapError(http: http, body: String(data: data, encoding: .utf8) ?? "")
        }

        do {
            return try HTTPSupport.decoder.decode(MessagesResponse.self, from: data)
        } catch {
            throw LLMError.malformedResponse(error.localizedDescription)
        }
    }

    // MARK: Streaming (AWS event stream)

    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try signedRequest(request, streaming: true)
                    let (bytes, response) = try await HTTPSupport.session.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.malformedResponse("Response was not HTTP.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var errorBody = Data()
                        for try await byte in bytes { errorBody.append(byte) }
                        throw Self.mapError(http: http, body: String(data: errorBody, encoding: .utf8) ?? "")
                    }

                    var decoder = AWSEventStreamDecoder()
                    var accumulator = StreamAccumulator()
                    var sawCompletion = false

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        decoder.append(byte)
                        for frame in try decoder.drain() {
                            guard let event = try Self.anthropicEvent(from: frame) else { continue }
                            if let emitted = try accumulator.consume(event) {
                                continuation.yield(emitted)
                                if case .completed = emitted { sawCompletion = true }
                            }
                        }
                    }

                    if !sawCompletion {
                        continuation.yield(.completed(accumulator.finish()))
                    }
                    continuation.finish()
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: HTTPSupport.transportError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Unwrap one event-stream frame into the Anthropic event JSON it carries.
    ///
    /// Bedrock double-wraps: the frame payload is `{"bytes": "<base64>"}`, and
    /// the base64 decodes to the same `content_block_delta` / `message_stop`
    /// objects the first-party SSE stream sends.
    private static func anthropicEvent(from frame: AWSEventStreamMessage) throws -> JSONValue? {
        if frame.messageType == "exception" || frame.exceptionType != nil {
            let text = String(data: frame.payload, encoding: .utf8) ?? ""
            let message = (try? HTTPSupport.decoder.decode(JSONValue.self, from: frame.payload))?["message"]?.stringValue
            throw LLMError.http(
                status: 400,
                body: "\(frame.exceptionType ?? "Bedrock exception"): \(message ?? text)"
            )
        }
        guard frame.messageType == nil || frame.messageType == "event" else { return nil }

        let outer = try? HTTPSupport.decoder.decode(JSONValue.self, from: frame.payload)
        guard let encoded = outer?["bytes"]?.stringValue,
              let inner = Data(base64Encoded: encoded) else {
            // Some frames (initial-response, metadata) carry no chunk payload.
            return nil
        }
        return try? HTTPSupport.decoder.decode(JSONValue.self, from: inner)
    }

    /// Bedrock's error envelope differs from the first-party one, so the
    /// generic mapper would show a raw blob. Pull out AWS's own fields first.
    private static func mapError(http: HTTPURLResponse, body: String) -> LLMError {
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        }
        if let data = body.data(using: .utf8),
           let root = try? HTTPSupport.decoder.decode(JSONValue.self, from: data) {
            let message = root["message"]?.stringValue ?? root["Message"]?.stringValue
            let type = http.value(forHTTPHeaderField: "x-amzn-ErrorType")
            if let message {
                let prefix = type.map { "\($0): " } ?? ""
                return .http(status: http.statusCode, body: prefix + message)
            }
        }
        if http.statusCode == 403 {
            return .http(
                status: 403,
                body: String(
                    localized: "Access denied. Check the IAM permissions on this key (bedrock:InvokeModel) and that the model is enabled in \(http.url?.host ?? "this region").",
                    comment: "Bedrock 403. Placeholder is the endpoint host, or a fallback phrase."
                )
            )
        }
        return .http(status: http.statusCode, body: body)
    }
}

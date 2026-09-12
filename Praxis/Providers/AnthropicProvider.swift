import Foundation

/// Talks to the first-party Messages API at api.anthropic.com.
///
/// Auth is a bare API key in the `x-api-key` header. That key sits in the
/// Keychain and goes nowhere else — but it *is* on the device, which is the
/// honest tradeoff of a keyless-backend personal app. The `key-on-device`
/// concept in the production track covers why this doesn't generalise to a
/// shipped multi-user product.
struct AnthropicProvider: LLMProvider {

    let kind: ProviderKind = .anthropic
    let apiKey: String
    var baseURL = URL(string: "https://api.anthropic.com")!

    var endpointDescription: String { "api.anthropic.com/v1/messages" }

    private static let apiVersion = "2023-06-01"

    private func makeRequest(_ body: MessagesRequest) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try HTTPSupport.encoder.encode(body)
        return request
    }

    // MARK: Non-streaming

    func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        var body = request
        body.stream = nil
        let urlRequest = try makeRequest(body)

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
            throw HTTPSupport.error(for: http, body: String(data: data, encoding: .utf8) ?? "")
        }

        do {
            return try HTTPSupport.decoder.decode(MessagesResponse.self, from: data)
        } catch {
            throw LLMError.malformedResponse(error.localizedDescription)
        }
    }

    // MARK: Streaming (SSE)

    func stream(_ request: MessagesRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body = request
                    body.stream = true
                    let urlRequest = try makeRequest(body)

                    let (bytes, response) = try await HTTPSupport.session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.malformedResponse("Response was not HTTP.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Error bodies are small and not SSE-framed; drain and report.
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        throw HTTPSupport.error(for: http, body: errorBody)
                    }

                    var accumulator = StreamAccumulator()
                    var sawCompletion = false

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        // SSE frames here are one JSON object per `data:` line;
                        // `event:` lines restate the type already in the payload.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        guard let data = payload.data(using: .utf8),
                              let event = try? HTTPSupport.decoder.decode(JSONValue.self, from: data)
                        else { continue }

                        if let emitted = try accumulator.consume(event) {
                            continuation.yield(emitted)
                            if case .completed = emitted { sawCompletion = true }
                        }
                    }

                    // A stream that ends without `message_stop` (dropped
                    // connection) still has usable partial content.
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
}

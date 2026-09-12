import Foundation

enum HTTPSupport {

    /// Shared session for model calls.
    ///
    /// The long timeouts are deliberate: Opus 5 with adaptive thinking at high
    /// effort can legitimately take minutes on a hard grading request, and the
    /// URLSession default would kill it mid-flight.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static let decoder = JSONDecoder()

    /// Map a non-2xx response onto a typed error. `body` is the response body
    /// already read as text.
    static func error(for response: HTTPURLResponse, body: String) -> LLMError {
        switch response.statusCode {
        case 429:
            let retryAfter = (response.value(forHTTPHeaderField: "retry-after")
                ?? response.value(forHTTPHeaderField: "Retry-After"))
                .flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        case 401, 403:
            return .http(status: response.statusCode, body: body.isEmpty
                ? "Authentication failed. Check the credentials in Settings."
                : body)
        default:
            return .http(status: response.statusCode, body: body)
        }
    }

    /// Wrap a URLSession failure, distinguishing cancellation from a real
    /// network fault so a learner backing out of a screen doesn't see an error.
    static func transportError(_ error: Error) -> LLMError {
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return .cancelled
        }
        return .transport(nsError.localizedDescription)
    }
}

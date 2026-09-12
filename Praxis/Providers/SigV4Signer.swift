import Foundation
import CryptoKit

struct AWSCredentials: Sendable, Hashable {
    var accessKeyID: String
    var secretAccessKey: String
    /// Present for temporary credentials (STS, Cognito, SSO). When set it must
    /// be sent as `x-amz-security-token` *and* included in the signature.
    var sessionToken: String?
}

/// AWS Signature Version 4 request signing.
///
/// Hand-rolled because there is no AWS SDK for Swift on iOS that's worth the
/// dependency weight here, and because implementing SigV4 is itself one of the
/// things the AWS track teaches. The four-step derivation below mirrors the
/// AWS "Signing AWS API requests" reference exactly.
struct SigV4Signer: Sendable {

    let region: String
    let service: String
    let credentials: AWSCredentials

    init(region: String, service: String = "bedrock", credentials: AWSCredentials) {
        self.region = region
        self.service = service
        self.credentials = credentials
    }

    /// Returns a copy of `request` with `Authorization`, `X-Amz-Date`, and —
    /// when using temporary credentials — `X-Amz-Security-Token` set.
    ///
    /// `request` must already have its URL, HTTP method, body, and any headers
    /// that should be signed (notably `Content-Type`) in place.
    func sign(_ request: URLRequest, date: Date = Date()) throws -> URLRequest {
        guard let url = request.url, let host = url.host else {
            throw LLMError.invalidConfiguration("Request has no host to sign against.")
        }

        var signed = request
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = Self.dateStampFormatter.string(from: date)
        let body = request.httpBody ?? Data()
        let payloadHash = Self.hexSHA256(body)

        signed.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        signed.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")
        if let token = credentials.sessionToken, !token.isEmpty {
            signed.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        // ---- Step 1: canonical request -------------------------------------

        // Every header we sign, lowercased. `host` is not in `allHTTPHeaderFields`
        // because URLSession adds it, so it is contributed explicitly.
        var headersToSign: [String: String] = ["host": host]
        for (name, value) in signed.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            guard Self.signedHeaderNames.contains(lower) else { continue }
            headersToSign[lower] = value.trimmingCharacters(in: .whitespaces)
        }

        let sortedNames = headersToSign.keys.sorted()
        let canonicalHeaders = sortedNames
            .map { "\($0):\(headersToSign[$0] ?? "")\n" }
            .joined()
        let signedHeaders = sortedNames.joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "POST",
            Self.canonicalURI(from: url),
            Self.canonicalQueryString(from: url),
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        // ---- Step 2: string to sign ----------------------------------------

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.hexSHA256(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        // ---- Step 3: derive the signing key --------------------------------

        let signingKey = Self.derivedSigningKey(
            secret: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )

        // ---- Step 4: sign ---------------------------------------------------

        let signature = Self.hex(Self.hmac(key: signingKey, data: Data(stringToSign.utf8)))

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"
        signed.setValue(authorization, forHTTPHeaderField: "Authorization")

        return signed
    }

    /// Headers included in the signature. Keeping this an explicit allowlist
    /// avoids a whole class of intermittent 403s: URLSession silently adds
    /// headers (Accept-Encoding, User-Agent, Content-Length) at send time, and
    /// signing a header the transport later rewrites breaks the signature.
    private static let signedHeaderNames: Set<String> = [
        "content-type", "x-amz-date", "x-amz-security-token", "x-amz-content-sha256"
    ]

    // MARK: - Canonicalization

    /// URI-encoded absolute path.
    ///
    /// The SigV4 spec asks for each path segment to be encoded *twice* for
    /// every service except S3. Bedrock model identifiers are drawn from
    /// `[A-Za-z0-9._:-]` and inference-profile IDs add only dots, all of which
    /// are RFC 3986 unreserved or otherwise pass through unchanged, so a single
    /// pass is byte-identical to two here. Raw ARNs as model IDs would need the
    /// second pass and are not supported.
    static func canonicalURI(from url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let encoded = segments.map { uriEncode(String($0), encodeSlash: true) }
        let joined = encoded.joined(separator: "/")
        return joined.isEmpty ? "/" : joined
    }

    static func canonicalQueryString(from url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return "" }
        return items
            .map { (uriEncode($0.name, encodeSlash: true), uriEncode($0.value ?? "", encodeSlash: true)) }
            .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0)=\($1)" }
            .joined(separator: "&")
    }

    /// RFC 3986 percent-encoding with only unreserved characters left as-is.
    /// `Foundation`'s own percent-encoding sets are wrong for SigV4 — they
    /// leave several reserved characters unescaped.
    static func uriEncode(_ value: String, encodeSlash: Bool) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for byte in Array(value.utf8) {
            let char = Character(UnicodeScalar(byte))
            if (byte >= 0x41 && byte <= 0x5A)       // A-Z
                || (byte >= 0x61 && byte <= 0x7A)   // a-z
                || (byte >= 0x30 && byte <= 0x39)   // 0-9
                || char == "-" || char == "." || char == "_" || char == "~" {
                out.append(char)
            } else if char == "/" && !encodeSlash {
                out.append(char)
            } else {
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    // MARK: - Crypto primitives

    static func derivedSigningKey(secret: String, dateStamp: String, region: String, service: String) -> SymmetricKey {
        let kSecret = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        let kDate = hmac(key: kSecret, data: Data(dateStamp.utf8))
        let kRegion = hmac(key: SymmetricKey(data: kDate), data: Data(region.utf8))
        let kService = hmac(key: SymmetricKey(data: kRegion), data: Data(service.utf8))
        let kSigning = hmac(key: SymmetricKey(data: kService), data: Data("aws4_request".utf8))
        return SymmetricKey(data: kSigning)
    }

    static func hmac(key: SymmetricKey, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func hexSHA256(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Date formatting
    //
    // Created once and never mutated. Both are pinned to POSIX/UTC — a
    // device on a non-Gregorian calendar or a 12-hour locale would otherwise
    // produce a timestamp AWS rejects.

    static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    static let dateStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}

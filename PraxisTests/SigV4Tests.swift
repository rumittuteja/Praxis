import Testing
import Foundation
import CryptoKit   // SymmetricKey.withUnsafeBytes is used below
@testable import Praxis

/// Verified against the canonical vectors in AWS's "Signing AWS API requests"
/// documentation. Signing is the piece most likely to be subtly wrong and the
/// hardest to debug from a 403, so it gets exact-value tests rather than
/// smoke tests.
@Suite("SigV4")
struct SigV4Tests {

    private let credentials = AWSCredentials(
        accessKeyID: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        sessionToken: nil
    )

    @Test("SHA-256 of the empty payload matches the well-known constant")
    func emptyPayloadHash() {
        #expect(SigV4Signer.hexSHA256(Data())
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("Signing key derivation matches the AWS reference vector")
    func signingKeyDerivation() {
        // From the AWS documentation's worked example.
        let key = SigV4Signer.derivedSigningKey(
            secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            dateStamp: "20150830",
            region: "us-east-1",
            service: "iam"
        )
        let hex = key.withUnsafeBytes { SigV4Signer.hex(Data($0)) }
        #expect(hex == "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")
    }

    @Test("Unreserved characters pass through URI encoding untouched")
    func uriEncodeUnreserved() {
        #expect(SigV4Signer.uriEncode("anthropic.claude-opus-5", encodeSlash: true)
            == "anthropic.claude-opus-5")
        #expect(SigV4Signer.uriEncode("abcXYZ019-._~", encodeSlash: true) == "abcXYZ019-._~")
    }

    @Test("Reserved characters are percent-encoded uppercase")
    func uriEncodeReserved() {
        #expect(SigV4Signer.uriEncode("a b", encodeSlash: true) == "a%20b")
        #expect(SigV4Signer.uriEncode("a/b", encodeSlash: true) == "a%2Fb")
        #expect(SigV4Signer.uriEncode("a/b", encodeSlash: false) == "a/b")
        #expect(SigV4Signer.uriEncode("a:b", encodeSlash: true) == "a%3Ab")
    }

    @Test("Canonical URI keeps path separators and encodes each segment")
    func canonicalURI() {
        let url = URL(string: "https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-opus-5/invoke")!
        #expect(SigV4Signer.canonicalURI(from: url) == "/model/anthropic.claude-opus-5/invoke")
    }

    @Test("An empty path canonicalizes to a single slash")
    func canonicalURIRoot() {
        #expect(SigV4Signer.canonicalURI(from: URL(string: "https://example.com")!) == "/")
    }

    @Test("Query parameters are sorted by name")
    func canonicalQuerySorting() {
        let url = URL(string: "https://example.com/x?zebra=1&alpha=2&mid=3")!
        #expect(SigV4Signer.canonicalQueryString(from: url) == "alpha=2&mid=3&zebra=1")
    }

    @Test("Signing produces the expected header set")
    func signedHeaders() throws {
        var request = URLRequest(url: URL(string: "https://bedrock-runtime.us-east-1.amazonaws.com/model/anthropic.claude-opus-5/invoke")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"max_tokens":16}"#.utf8)

        let signer = SigV4Signer(region: "us-east-1", service: "bedrock", credentials: credentials)
        let signed = try signer.sign(request, date: Date(timeIntervalSince1970: 1_440_938_160))

        let authorization = try #require(signed.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"))
        #expect(authorization.contains("/us-east-1/bedrock/aws4_request"))
        #expect(authorization.contains("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date"))
        #expect(signed.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        // No temporary credentials, so no security token header.
        #expect(signed.value(forHTTPHeaderField: "X-Amz-Security-Token") == nil)
    }

    @Test("Temporary credentials add the security token to the signed headers")
    func sessionTokenIsSigned() throws {
        var request = URLRequest(url: URL(string: "https://bedrock-runtime.us-west-2.amazonaws.com/model/x/invoke")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()

        let temporary = AWSCredentials(
            accessKeyID: "ASIAEXAMPLE",
            secretAccessKey: "secret",
            sessionToken: "token-value"
        )
        let signer = SigV4Signer(region: "us-west-2", service: "bedrock", credentials: temporary)
        let signed = try signer.sign(request)

        #expect(signed.value(forHTTPHeaderField: "X-Amz-Security-Token") == "token-value")
        let authorization = try #require(signed.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("x-amz-security-token"))
    }

    @Test("The same request signed twice at the same instant is identical")
    func deterministic() throws {
        var request = URLRequest(url: URL(string: "https://bedrock-runtime.eu-west-1.amazonaws.com/model/m/invoke")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("body".utf8)

        let signer = SigV4Signer(region: "eu-west-1", service: "bedrock", credentials: credentials)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try signer.sign(request, date: date).value(forHTTPHeaderField: "Authorization")
        let second = try signer.sign(request, date: date).value(forHTTPHeaderField: "Authorization")
        #expect(first == second)
    }

    @Test("A different body produces a different signature")
    func bodyAffectsSignature() throws {
        let url = URL(string: "https://bedrock-runtime.eu-west-1.amazonaws.com/model/m/invoke")!
        let signer = SigV4Signer(region: "eu-west-1", service: "bedrock", credentials: credentials)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        func signature(body: String) throws -> String? {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            return try signer.sign(request, date: date).value(forHTTPHeaderField: "Authorization")
        }

        #expect(try signature(body: "a") != signature(body: "b"))
    }
}

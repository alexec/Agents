#if canImport(Security)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Checking a credential when it is saved (043, R9), against a stand-in for Anthropic that
/// records what it was sent and answers as told.
@Suite("Checking a credential", .serialized)
struct CredentialCheckTests {
    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var answer: (Int, String) = (200, "{}")
        nonisolated(unsafe) static var fail: URLError?
        nonisolated(unsafe) static var seen: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.seen = request
            if let fail = Self.fail {
                client?.urlProtocol(self, didFailWithError: fail)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.answer.0, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.answer.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func check(_ secret: Secret, answer: (Int, String) = (200, "{}"), fail: URLError? = nil) async -> CredentialCheck.Answer {
        Stub.answer = answer
        Stub.fail = fail
        Stub.seen = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return await CredentialCheck(session: URLSession(configuration: config)).check(secret)
    }

    static let token = Secret("sk-ant-oat01-TESTTESTTEST-a3f9")!
    static let key = Secret("sk-ant-api03-TESTTESTTEST-9x9z")!

    @Test func aSubscriptionTokenGoesAsABearerWithTheOAuthBeta() async {
        #expect(await check(Self.token) == .works)
        #expect(Stub.seen?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-TESTTESTTEST-a3f9")
        #expect(Stub.seen?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(Stub.seen?.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test func anAPIKeyGoesAsXAPIKey() async {
        #expect(await check(Self.key) == .works)
        #expect(Stub.seen?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-api03-TESTTESTTEST-9x9z")
        #expect(Stub.seen?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// The body Anthropic sent on 2026-09-25 for a made-up token (walk/spike.md T010).
    @Test func a401IsRefusedInAnthropicsOwnWords() async {
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"OAuth access token is invalid."},"request_id":null}"#
        #expect(await check(Self.token, answer: (401, body)) == .refused("OAuth access token is invalid."))
    }

    @Test func anythingElseIsCannotCheck() async {
        if case .cannotCheck = await check(Self.token, answer: (529, "overloaded")) {} else { Issue.record("529") }
        if case .cannotCheck = await check(Self.token, fail: URLError(.notConnectedToInternet)) {} else { Issue.record("offline") }
    }
}
#endif

/// Gemini's key is checked with Google, in a header (046, contracts/credentials.md).
@Suite("Checking a Gemini key")
struct GeminiCredentialCheckTests {
    @Test func theKeyGoesInAHeaderAndNeverTheURL() throws {
        let key = "AQ." + "Ab8RN6FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE5678"
        let request = CredentialCheck.request(for: try #require(Secret(key)))
        #expect(request.url == CredentialCheck.geminiEndpoint)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == key)
        #expect(!(request.url?.absoluteString.contains(key) ?? true))
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test func googlesWordForAnUnknownKeyIsARefusal() {
        let body = Data(#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#.utf8)
        #expect(CredentialCheck.isInvalidKey(body))
        #expect(CredentialCheck.message(body) == "API key not valid. Please pass a valid API key.")
    }
}

/// Codex's key is checked with OpenAI, as a bearer token (047).
@Suite("Checking an OpenAI key")
struct OpenAICredentialCheckTests {
    @Test func theKeyGoesInTheAuthorizationHeader() throws {
        let key = "sk-" + "proj-FAKEFAKEFAKEFAKEFAKEFAKE1234"
        let request = CredentialCheck.request(for: try #require(Secret(key)))
        #expect(request.url == CredentialCheck.openAIEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
        #expect(!(request.url?.absoluteString.contains(key) ?? true))
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test func openAIsErrorSentenceIsRead() {
        let body = Data(#"{"error":{"message":"Incorrect API key provided: sk-proj-****1234.","type":"invalid_request_error","code":"invalid_api_key"}}"#.utf8)
        #expect(CredentialCheck.message(body) == "Incorrect API key provided: sk-proj-****1234.")
    }
}

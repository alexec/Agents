#if canImport(Security)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Checking a credential when it is saved (043, R9), against a stand-in for the provider that
/// records what it was sent and answers as told. Gemini's key is the only kind since 056.
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

    static let token = Secret("AQ." + "Ab8RN6FAKECHECKTESTCHECKTEST-a3f9")!

    @Test func aWorkingKeyWorks() async {
        #expect(await check(Self.token) == .works)
        #expect(Stub.seen?.url == CredentialCheck.geminiEndpoint)
    }

    @Test func a403IsRefusedInGooglesOwnWords() async {
        let body = #"{"error":{"code":403,"message":"Method doesn't allow unregistered callers.","status":"PERMISSION_DENIED"}}"#
        #expect(await check(Self.token, answer: (403, body)) == .refused("Method doesn't allow unregistered callers."))
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

import Foundation
import Network
import Security
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The Mac end of the sign-in relay (047): the stand-in carries nothing secret, the
/// certificates are made once and load, a request parses, and a TLS connection is answered.
@Suite("The Mac's sign-in relay", .timeLimit(.minutes(1)))
struct MacSignInRelayTests {
    static func temporary() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func jwt(_ claims: [String: Any]) throws -> String {
        try CodexFileSignIn.unsigned(claims).replacingOccurrences(of: ".standin", with: ".c2lnbmF0dXJl")
    }

    /// A Mac sign-in file shaped like Codex's, with made-up secrets.
    static func signInFile(in folder: URL, access: String = "ACCESS-SECRET") throws -> URL {
        let file = folder.appendingPathComponent("auth.json")
        let auth: [String: Any] = ["chatgpt_account_id": "acct-1", "chatgpt_plan_type": "plus",
                                   "chatgpt_user_id": "user-1", "user_id": "user-1",
                                   "organizations": [["id": "org-secret-ish"]], "groups": ["g"]]
        let object: [String: Any] = [
            "auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
            "tokens": ["id_token": try jwt(["email": "alex@example.com", "https://api.openai.com/auth": auth]),
                       "access_token": access, "refresh_token": "REFRESH-SECRET", "account_id": "acct-1"],
            "last_refresh": "2026-09-26T04:11:16.326107Z"]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return file
    }

    @Test func theStandInHoldsNoSecretAndNoPersonalDetail() throws {
        let folder = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let signIn = CodexFileSignIn(file: try Self.signInFile(in: folder))
        let standIn = try signIn.standIn()
        for secret in ["ACCESS-SECRET", "REFRESH-SECRET", "alex@example.com", "org-secret-ish"] {
            #expect(!standIn.contains(secret), "\(secret) must not reach a server")
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(standIn.utf8)) as? [String: Any])
        let tokens = try #require(object["tokens"] as? [String: Any])
        #expect(object["auth_mode"] as? String == "chatgpt")
        #expect(tokens["account_id"] as? String == "acct-1")
        #expect((tokens["access_token"] as? String)?.hasSuffix(".standin") == true)
        let claims = CodexFileSignIn.claims(tokens["id_token"] as! String)
        let auth = try #require(claims["https://api.openai.com/auth"] as? [String: Any])
        #expect(auth["chatgpt_plan_type"] as? String == "plus")
        #expect(auth["organizations"] == nil)
        #expect(try signIn.current() == .init(access: "ACCESS-SECRET", headers: ["ChatGPT-Account-Id": "acct-1"]))
    }

    @Test func anAPIKeySignInIsNotOneTheRelayCanLend() throws {
        let folder = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("auth.json")
        try Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-proj-x"}"#.utf8).write(to: file)
        let signIn = CodexFileSignIn(file: file)
        #expect(!signIn.isSignedIn)
        #expect(throws: (any Error).self) { try signIn.standIn() }
    }

    @Test func aRenewalSomebodyElseMadeIsUsedWithoutSpendingTheRefreshToken() async throws {
        let folder = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let signIn = CodexFileSignIn(file: try Self.signInFile(in: folder, access: "NEWER"),
                               tokenEndpoint: URL(string: "https://example.invalid/never-called")!)
        let renewed = try await signIn.renew(after: .init(access: "OLDER", headers: ["ChatGPT-Account-Id": "acct-1"]))
        #expect(renewed.access == "NEWER")
    }

    /// The runtime's own sign-in never reaches the service; this Mac's does, with the
    /// headers its sign-in carries and no others (056).
    @Test func theUpstreamRequestCarriesThisMacsSignInOnly() throws {
        let raw = Data("POST /v1/messages?beta=true HTTP/1.1\r\nHost: 127.0.0.1:9\r\nAuthorization: Bearer sk-ant-oat01-agents-relay-standin\r\nx-api-key: sk-ant-api-server\r\nanthropic-beta: oauth-2025-04-20\r\nConnection: keep-alive\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard case .complete(let request) = HTTPRequest.parse(raw) else { Issue.record("not parsed"); return }

        let claudeURL = try #require(MacSignInRelay.upstreamURL(host: "api.anthropic.com", target: request.target))
        let claude = MacSignInRelay.upstream(request, url: claudeURL, token: MacSignInToken(access: "MAC-ACCESS"))
        #expect(claude.url?.absoluteString == "https://api.anthropic.com/v1/messages?beta=true")
        #expect(claude.value(forHTTPHeaderField: "Authorization") == "Bearer MAC-ACCESS")
        #expect(claude.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(claude.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(claude.value(forHTTPHeaderField: "Connection") == nil)
        #expect(claude.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
        #expect(claude.httpBody == Data("{}".utf8))

        let codexURL = try #require(MacSignInRelay.upstreamURL(host: "chatgpt.com", target: request.target))
        let codex = MacSignInRelay.upstream(request, url: codexURL,
                                            token: MacSignInToken(access: "A", headers: ["ChatGPT-Account-Id": "acct-1"]))
        #expect(codex.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
        #expect("\(MacSignInToken(access: "MAC-ACCESS"))".contains("MAC-ACCESS") == false)
    }

    @Test func requestsParseWithLengthOrChunkedBodies() {
        let plain = Data("POST /backend-api/codex/responses?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nhello".utf8)
        guard case .complete(let request) = HTTPRequest.parse(plain) else { Issue.record("not parsed"); return }
        #expect(request.method == "POST")
        #expect(request.pathOnly == "/backend-api/codex/responses")
        #expect(request.body == Data("hello".utf8))
        #expect(HTTPRequest.parse(plain.prefix(plain.count - 2)) == .incomplete)
        let chunked = Data("POST /a HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nhel\r\n2\r\nlo\r\n0\r\n\r\n".utf8)
        guard case .complete(let other) = HTTPRequest.parse(chunked) else { Issue.record("not parsed"); return }
        #expect(other.body == Data("hello".utf8))
    }

    /// The token goes only to the runtime's own service: a target that is not a plain path
    /// (`@host/`, `:443@host/`, `//host/`, a whole URL) is refused, and one that is keeps the
    /// relay's host whatever it holds.
    @Test func onlyAPlainPathReachesTheUpstreamHost() throws {
        let host = "chatgpt.com"
        for target in ["@evil.example/x", "@evil.example", ":443@evil.example/", "//evil.example/x",
                       "https://evil.example/x", ".evil.example/x", "*", "", "evil.example/x",
                       "/a b", "/a\\b", "/a#frag", "/a%zz", "/a%4", "/\u{0}x"] {
            #expect(MacSignInRelay.upstreamURL(host: host, target: target) == nil, "\(target) must be refused")
        }
        let kept = try #require(MacSignInRelay.upstreamURL(host: host, target: "/backend-api/codex/responses?x=1&y=%2F"))
        #expect(kept.absoluteString == "https://chatgpt.com/backend-api/codex/responses?x=1&y=%2F")
        for target in ["/@evil.example/x", "/x:443@evil.example/", "/a?next=//evil.example/@x", "/"] {
            let url = try #require(MacSignInRelay.upstreamURL(host: host, target: target), "\(target)")
            #expect(url.host == host && url.user == nil && url.port == nil, "\(target) stays on \(host)")
        }
    }

    /// End to end: with a sign-in on this Mac, a request naming another host in its target
    /// is answered 400 by the relay itself, and never sent on with the token.
    @Test func aTargetNamingAnotherHostIsRefusedBeforeTheTokenIsUsed() async throws {
        let folder = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let certificates = RelayCertificates(folder: folder.appendingPathComponent("relay"))
        let relay = MacSignInRelay(relay: try #require(ToolPolicyCatalog.codex.relay),
                                   signIn: CodexFileSignIn(file: try Self.signInFile(in: folder)),
                                   certificates: certificates)
        let port = try await relay.start()
        defer { relay.stop() }
        let answer = try await Self.rawTLS(port: port,
                                           request: "GET @agents-relay-test.invalid/steal HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(answer.hasPrefix("HTTP/1.1 400"), "got \(answer.prefix(40))")
    }

    /// Loopback is every local account's to dial: without the stand-in bearer handed to
    /// the server, the Mac's token is not attached (S4).
    @Test func aCallerWithoutTheStandInDoesNotGetThisMacsToken() async throws {
        let folder = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let certificates = RelayCertificates(folder: folder.appendingPathComponent("relay"))
        let standIn = try CodexFileSignIn(file: try Self.signInFile(in: folder)).standIn()
        let relay = MacSignInRelay(relay: try #require(ToolPolicyCatalog.codex.relay),
                                   signIn: CodexFileSignIn(file: try Self.signInFile(in: folder)),
                                   certificates: certificates)
        relay.expectClientBearer(MacSignInRelay.clientBearer(fromStandIn: standIn))
        let port = try await relay.start()
        defer { relay.stop() }
        let none = try await Self.rawTLS(port: port,
                                         request: "GET /backend-api/codex/responses HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(none.hasPrefix("HTTP/1.1 403"), "got \(none.prefix(40))")
        let wrong = try await Self.rawTLS(port: port,
                                          request: "GET /backend-api/codex/responses HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer not-the-stand-in\r\n\r\n")
        #expect(wrong.hasPrefix("HTTP/1.1 403"), "got \(wrong.prefix(40))")
        #expect(MacSignInRelay.freshClaudeStandIn() != ClaudeKeychainSignIn.standInToken)
        #expect(MacSignInRelay.freshClaudeStandIn() != MacSignInRelay.freshClaudeStandIn())
    }

    /// Send `request` as it is over TLS to the relay, trusting whatever it presents (the
    /// point here is the request line, which URLSession would never send), and read the head.
    static func rawTLS(port: UInt16, request: String) async throws -> String {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, .global())
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                      using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        defer { connection.cancel() }
        return try await withCheckedThrowingContinuation { done in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                        guard once.take() else { return }
                        if let data { done.resume(returning: String(decoding: data, as: UTF8.self)) }
                        else { done.resume(throwing: error ?? URLError(.zeroByteResource)) }
                    }
                case .failed(let error):
                    if once.take() { done.resume(throwing: error) }
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }

    /// The certificates are made once, the server certificate loads as an identity, and a
    /// TLS client trusting only the relay's CA gets an answer: a WebSocket upgrade is turned
    /// down with 404, and with no sign-in on this Mac a request gets 502, not a token.
    @Test func aTLSClientTrustingTheRelaysCAIsAnswered() async throws {
        let folder = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let certificates = RelayCertificates(folder: folder.appendingPathComponent("relay"))
        let pem = try certificates.caPEM()
        #expect(pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
        let before = try Data(contentsOf: certificates.caCertificate)
        _ = try certificates.caPEM()
        #expect(try Data(contentsOf: certificates.caCertificate) == before, "made once")
        let keyMode = try FileManager.default.attributesOfItem(
            atPath: certificates.folder.appendingPathComponent("ca-key.pem").path)[.posixPermissions] as? Int
        #expect(keyMode == 0o600)

        let relay = MacSignInRelay(relay: try #require(ToolPolicyCatalog.codex.relay),
                                   signIn: CodexFileSignIn(file: folder.appendingPathComponent("no-sign-in.json")),
                                   certificates: certificates)
        let standInBearer = MacSignInRelay.freshClaudeStandIn()
        relay.expectClientBearer(standInBearer)
        let port = try await relay.start()
        defer { relay.stop() }
        #expect(port != 0)

        let trust = TrustOnly(caPEM: pem)
        let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        var upgrade = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/backend-api/codex/responses")!)
        upgrade.setValue("websocket", forHTTPHeaderField: "Upgrade")
        upgrade.setValue("Bearer \(standInBearer)", forHTTPHeaderField: "Authorization")
        let (_, upgraded) = try await session.data(for: upgrade)
        #expect((upgraded as? HTTPURLResponse)?.statusCode == 404)
        var plain = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/backend-api/wham/accounts/check")!)
        plain.setValue("Bearer \(standInBearer)", forHTTPHeaderField: "Authorization")
        let (_, answered) = try await session.data(for: plain)
        #expect((answered as? HTTPURLResponse)?.statusCode == 502)
    }

    /// A URLSession delegate that trusts one CA and nothing else.
    final class TrustOnly: NSObject, URLSessionDelegate, @unchecked Sendable {
        let anchor: SecCertificate
        init(caPEM: String) {
            let base64 = caPEM.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
            anchor = SecCertificateCreateWithData(nil, Data(base64Encoded: base64)! as CFData)!
        }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard let trust = challenge.protectionSpace.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) { return (.useCredential, URLCredential(trust: trust)) }
            Issue.record("trust refused: \(String(describing: error))")
            return (.cancelAuthenticationChallenge, nil)
        }
    }
}

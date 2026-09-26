import Foundation
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
        try MacSignIn.unsigned(claims).replacingOccurrences(of: ".standin", with: ".c2lnbmF0dXJl")
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
        let signIn = MacSignIn(file: try Self.signInFile(in: folder))
        let standIn = try signIn.standIn()
        for secret in ["ACCESS-SECRET", "REFRESH-SECRET", "alex@example.com", "org-secret-ish"] {
            #expect(!standIn.contains(secret), "\(secret) must not reach a server")
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(standIn.utf8)) as? [String: Any])
        let tokens = try #require(object["tokens"] as? [String: Any])
        #expect(object["auth_mode"] as? String == "chatgpt")
        #expect(tokens["account_id"] as? String == "acct-1")
        #expect((tokens["access_token"] as? String)?.hasSuffix(".standin") == true)
        let claims = MacSignIn.claims(tokens["id_token"] as! String)
        let auth = try #require(claims["https://api.openai.com/auth"] as? [String: Any])
        #expect(auth["chatgpt_plan_type"] as? String == "plus")
        #expect(auth["organizations"] == nil)
        #expect(try signIn.current() == .init(access: "ACCESS-SECRET", account: "acct-1"))
    }

    @Test func anAPIKeySignInIsNotOneTheRelayCanLend() throws {
        let folder = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("auth.json")
        try Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-proj-x"}"#.utf8).write(to: file)
        let signIn = MacSignIn(file: file)
        #expect(!signIn.isSignedIn)
        #expect(throws: (any Error).self) { try signIn.standIn() }
    }

    @Test func aRenewalSomebodyElseMadeIsUsedWithoutSpendingTheRefreshToken() async throws {
        let folder = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let signIn = MacSignIn(file: try Self.signInFile(in: folder, access: "NEWER"),
                               tokenEndpoint: URL(string: "https://example.invalid/never-called")!)
        let renewed = try await signIn.renew(after: .init(access: "OLDER", account: "acct-1"))
        #expect(renewed.access == "NEWER")
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
                                   signIn: MacSignIn(file: folder.appendingPathComponent("no-sign-in.json")),
                                   certificates: certificates)
        let port = try await relay.start()
        defer { relay.stop() }
        #expect(port != 0)

        let trust = TrustOnly(caPEM: pem)
        let session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
        var upgrade = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/backend-api/codex/responses")!)
        upgrade.setValue("websocket", forHTTPHeaderField: "Upgrade")
        let (_, upgraded) = try await session.data(for: upgrade)
        #expect((upgraded as? HTTPURLResponse)?.statusCode == 404)
        let (_, plain) = try await session.data(from: URL(string: "https://127.0.0.1:\(port)/backend-api/wham/accounts/check")!)
        #expect((plain as? HTTPURLResponse)?.statusCode == 502)
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

import Foundation
import Testing
@testable import AgentsKitCore

/// Pairing with no code by signing in (#995): the `s:` exchange, the nonce the client makes
/// itself, and a GitHub sign-in that waits for Approve.
@Suite("Signing in with no code")
struct ControlSignInTests {
    /// The control plane's side, enough for one sign-in: hello, the `s:` proof, signIn/providers,
    /// and signIn/pair, which it answers as `pair` says.
    final class FakeControlPlane: LineTransport, @unchecked Sendable {
        let control = ControlAgreement.generate()
        let helloNonce = ControlAuth.nonce()
        let origin = "https://control.example:443"
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<String, any Error>.Continuation?
        private var pending: [String] = []
        var paired: DaemonAPI.SignInPair?
        var identity: ControlAuth.Identity?
        let pair: (DaemonAPI.SignInPair, FakeControlPlane) -> [String]

        init(pair: @escaping (DaemonAPI.SignInPair, FakeControlPlane) -> [String]) {
            self.pair = pair
            let hello = ControlAuth.Hello(name: "Team plane", control: ControlCode.base64url(control.publicKey),
                                          nonce: ControlCode.base64url(helloNonce), copy: "one")
            pending = [ControlAuth.Message.hello(hello).line]
        }

        func say(_ line: String) {
            lock.withLock {
                if let continuation { continuation.yield(line) } else { pending.append(line) }
            }
        }

        func lines() -> AsyncThrowingStream<String, any Error> {
            AsyncThrowingStream { continuation in
                lock.withLock {
                    self.continuation = continuation
                    for line in pending { continuation.yield(line) }
                    pending = []
                }
            }
        }

        func close() { lock.withLock { continuation?.finish() } }

        func write(line: String) throws {
            if case .auth(let auth)? = ControlAuth.Message(line: line) {
                Task {
                    let control = self.control
                    do {
                        let (who, mac) = try await ControlAuth.verify(auth, serverNonce: self.helloNonce, origin: self.origin) { id in
                            guard case .signingIn(let client) = id, let key = auth.publicKey else {
                                throw ControlAuth.Refusal(.unknown)
                            }
                            return try ControlAuth.clientKey(privateKey: control.privateKey, peer: key, client: client)
                        }
                        self.identity = who
                        self.say(ControlAuth.Message.ok(.init(mac: ControlCode.base64url(mac))).line)
                    } catch {
                        self.say(ControlAuth.Message.refused(.badProof).line)
                    }
                }
                return
            }
            guard case .request(let id, let method, let params)? = try? JSONRPCCodec.decode(line: line) else { return }
            switch method {
            case DaemonAPI.Method.signInProviders:
                let providers = DaemonAPI.SignInProviders(providers: [.init(provider: "github", on: true, available: true)],
                                                          challenge: ControlCode.base64url(helloNonce))
                try say(JSONRPCCodec.encode(.success(id: id, result: JSONValue.encoding(providers))))
            case DaemonAPI.Method.signInPair:
                let request = try params!.decode(DaemonAPI.SignInPair.self)
                paired = request
                for reply in pair(request, self) { say(reply.replacingOccurrences(of: "\"ID\"", with: idText(id))) }
            default:
                break
            }
        }

        private func idText(_ id: JSONRPCID) -> String {
            if case .number(let n) = id { return String(n) }
            return "0"
        }
    }

    // One vector with the control plane's Go (controllink.TestSignInNonceVector).
    @Test func theNonceIsTheControlPlanes() {
        let key = Data([4] + (1...64).map { UInt8($0) })
        #expect(ControlSignIn.keyID(controlKey: key) == "0ed3a6ab957ff6f5")
        #expect(ControlSignIn.nonce(controlKey: key, challenge: Data(repeating: 7, count: 32))
            == "f399352dbd13beb7c27b5061d7085781ee74d846b27756855bb0fc428a15e0dc")
    }

    @Test func aSigningInIdentityReadsBack() {
        let id = UUID()
        #expect(ControlAuth.Identity(text: ControlAuth.Identity.signingIn(id).text) == .signingIn(id))
        #expect(ControlAuth.Identity.signingIn(id).text.hasPrefix("s:"))
    }

    /// The whole sign-in: the key proved with `s:`, the nonce from the hello's nonce and the
    /// key the client trusts, the code shown while it waits, and the membership kept.
    @Test func aGitHubSignInWaitsAndPairs() async throws {
        let shown = Shown()
        let server = FakeControlPlane { request, server in
            [#"{"jsonrpc":"2.0","method":"control/signInWaiting","params":{"code":"K7M2QX","expires":812345678.5}}"#,
             #"{"jsonrpc":"2.0","id":"ID","result":{"client":"\#(server.identityText)"}}"#]
        }
        let client = ControlAgreement.generate()
        let id = UUID()
        let saw = Nonces()
        let membership = try await ControlSignIn.pair(
            url: URL(string: "https://control.example")!, pin: nil, controlKey: nil, privateKey: client.privateKey, id: id,
            name: "Sam's iPhone", kind: .iPhone, dial: { _, _ in server },
            signIn: { providers, nonce in
                saw.set(nonce)
                return (providers.turnedOn[0].provider, "ghu_token")
            }, waiting: { shown.set($0.code) })
        #expect(server.identity == .signingIn(id))
        #expect(saw.value == ControlSignIn.nonce(controlKey: server.control.publicKey, challenge: server.helloNonce))
        #expect(server.paired?.token == "ghu_token" && server.paired?.provider == "github" && server.paired?.kind == .iPhone)
        #expect(shown.value == "K7M2QX")
        #expect(membership.client == id && membership.controlKey == server.control.publicKey && membership.name == "Team plane")
    }

    /// A refused sign-in says why, and keeps nothing.
    @Test func aRefusedSignInSaysWhy() async throws {
        let server = FakeControlPlane { _, _ in
            [#"{"jsonrpc":"2.0","id":"ID","error":{"code":-32045,"message":"Nobody on this control plane signs in with this GitHub account."}}"#]
        }
        let client = ControlAgreement.generate()
        await #expect(throws: (any Error).self) {
            _ = try await ControlSignIn.pair(url: URL(string: "https://control.example")!, pin: nil, controlKey: nil,
                                             privateKey: client.privateKey, id: UUID(), name: "Mac", kind: .mac,
                                             dial: { _, _ in server }, signIn: { _, _ in ("github", "x") })
        }
    }

    /// A control plane whose key is not the one trusted is refused before anything is sent.
    @Test func anotherControlPlaneIsRefused() async throws {
        let server = FakeControlPlane { _, _ in [] }
        let client = ControlAgreement.generate()
        await #expect(throws: ControlAuth.Refusal.self) {
            _ = try await ControlSignIn.pair(url: URL(string: "https://control.example")!, pin: nil,
                                             controlKey: ControlAgreement.generate().publicKey, privateKey: client.privateKey,
                                             id: UUID(), name: "Mac", kind: .mac, dial: { _, _ in server },
                                             signIn: { _, _ in ("github", "x") })
        }
        #expect(server.paired == nil)
    }

    final class Shown: @unchecked Sendable {
        private let lock = NSLock()
        private var code: String?
        func set(_ value: String) { lock.withLock { code = value } }
        var value: String? { lock.withLock { code } }
    }

    final class Nonces: @unchecked Sendable {
        private let lock = NSLock()
        private var nonce: String?
        func set(_ value: String) { lock.withLock { nonce = value } }
        var value: String? { lock.withLock { nonce } }
    }
}

extension ControlSignInTests.FakeControlPlane {
    var identityText: String {
        if case .signingIn(let id)? = identity { return id.uuidString }
        return ""
    }
}

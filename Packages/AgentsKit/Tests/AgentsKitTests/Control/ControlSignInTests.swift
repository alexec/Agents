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
        var started: DaemonAPI.SignInOrgStart?
        var ticketed: DaemonAPI.SignInTicket?
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
            case DaemonAPI.Method.signInDiscover:
                let email = try params!.decode(DaemonAPI.SignInDiscover.self).email
                let found = email.hasSuffix("@acme.com") ? DaemonAPI.SignInDiscovered(provider: "acme-okta", name: "Acme Okta")
                    : DaemonAPI.SignInDiscovered()
                try say(JSONRPCCodec.encode(.success(id: id, result: JSONValue.encoding(found))))
            case DaemonAPI.Method.signInOrgStart:
                let start = try params!.decode(DaemonAPI.SignInOrgStart.self)
                started = start
                try say(JSONRPCCodec.encode(.success(id: id, result: JSONValue.encoding(
                    DaemonAPI.SignInOrgStarted(url: "https://control.example/v1/oidc/start?s=abc")))))
            case DaemonAPI.Method.signInTicket:
                let ticket = try params!.decode(DaemonAPI.SignInTicket.self)
                ticketed = ticket
                if ticket.ticket == "good-ticket", case .signingIn(let client)? = identity {
                    try say(JSONRPCCodec.encode(.success(id: id, result: JSONValue.encoding(DaemonAPI.SignInTicketResult(client: client)))))
                } else {
                    try say(JSONRPCCodec.encode(.failure(id: id, error: JSONRPCError(code: SignInWords.orgSignInRequired,
                        message: "Your organisation asks you to sign in with Acme Okta.",
                        data: ["provider": "acme-okta", "name": "Acme Okta"]))))
                }
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

    // One vector with the control plane's Go (controllink.TestApprovalCodeIsBoundToBothKeys).
    @Test func theApprovalCodeIsTheControlPlanes() {
        #expect(ControlSignIn.approvalCode(clientPublicKey: Data(repeating: 1, count: 65), controlKey: Data(repeating: 2, count: 65))
            == "8UMUNH")
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
            signIn: { providers, nonce, _ in
                saw.set(nonce)
                return .token(provider: providers.turnedOn[0].provider, token: "ghu_token")
            }, waiting: { shown.set($0.code) })
        #expect(server.identity == .signingIn(id))
        #expect(saw.value == ControlSignIn.nonce(controlKey: server.control.publicKey, challenge: server.helloNonce))
        #expect(server.paired?.token == "ghu_token" && server.paired?.provider == "github" && server.paired?.kind == .iPhone)
        // The code made here from its own key and the key it trusts, never the control plane's.
        #expect(shown.value == ControlSignIn.approvalCode(clientPublicKey: client.publicKey, controlKey: server.control.publicKey))
        #expect(shown.value != "K7M2QX")
        #expect(membership.client == id && membership.controlKey == server.control.publicKey && membership.name == "Team plane")
    }

    /// An org provider (#1002): the email finds its provider, the flow starts on this
    /// connection, and the ticket the browser came back with pairs it.
    @Test func anOrgSignInPairsByTicket() async throws {
        let server = FakeControlPlane { _, _ in [] }
        let client = ControlAgreement.generate()
        let id = UUID()
        let opened = Nonces()
        let membership = try await ControlSignIn.pair(
            url: URL(string: "https://control.example")!, pin: nil, controlKey: nil, privateKey: client.privateKey, id: id,
            name: "Sam's iPhone", kind: .iPhone, dial: { _, _ in server },
            signIn: { _, _, ask in
                #expect(try await ask.discover("lee@other.org").provider == nil)
                let found = try await ask.discover("sam@acme.com")
                let address = try await ask.orgStart(found.provider!, "sam@acme.com")
                opened.set(address.absoluteString)
                return .ticket("good-ticket")
            })
        #expect(opened.value == "https://control.example/v1/oidc/start?s=abc")
        #expect(server.started == DaemonAPI.SignInOrgStart(provider: "acme-okta", purpose: .pair, returnTo: .app, loginHint: "sam@acme.com"))
        #expect(server.ticketed == DaemonAPI.SignInTicket(ticket: "good-ticket", name: "Sam's iPhone", kind: .iPhone))
        #expect(membership.client == id)
    }

    /// A refused ticket says which org provider the organisation asks for (FR-029).
    @Test func aRefusedTicketNamesTheProvider() async throws {
        let server = FakeControlPlane { _, _ in [] }
        let client = ControlAgreement.generate()
        do {
            _ = try await ControlSignIn.pair(url: URL(string: "https://control.example")!, pin: nil, controlKey: nil,
                                             privateKey: client.privateKey, id: UUID(), name: "Mac", kind: .mac,
                                             dial: { _, _ in server }, signIn: { _, _, _ in .ticket("bad") })
            Issue.record("a refused ticket paired")
        } catch {
            #expect(SignInWords.requiredProvider(error) == DaemonAPI.SignInOrgProvider(id: "acme-okta", name: "Acme Okta"))
        }
    }

    @Test func theCallbackGivesTheTicketOrWhy() {
        #expect(SignInWords.callback(URL(string: "agents://oidc#ticket=T1ck3t")!) == .ticket("T1ck3t"))
        #expect(SignInWords.callback(URL(string: "agents://oidc#error=expired&message=The%20sign-in%20took%20more%20than%2010%20minutes.")!)
            == .failed("The sign-in took more than 10 minutes."))
        #expect(SignInWords.callback(URL(string: "agents://oidc#error=access_denied")!) == .failed("The sign-in was cancelled."))
        #expect(SignInWords.callback(URL(string: "agents://oidc")!) == .failed("The sign-in came back with no answer. Try again."))
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
                                             dial: { _, _ in server }, signIn: { _, _, _ in .token(provider: "github", token: "x") })
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
                                             signIn: { _, _, _ in .token(provider: "github", token: "x") })
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

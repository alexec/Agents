import Foundation

/// Pairing with no code, by signing in with Google, Apple or GitHub (#995, spec 736 T2).
/// The client dials as `s:<a new UUID>` with the key it will keep, proves that key as a paired
/// client does, asks `signIn/providers`, signs in with its provider, and sends the token with
/// `signIn/pair`. The nonce an ID token carries is made here, from the control key this
/// client trusts and the hello's nonce, never taken from the control plane, so a token made
/// for one control plane is no good at another (R2, FR-011).
public enum ControlSignIn {
    /// Signs in with a provider, given the providers turned on, the nonce to sign in with, and
    /// what it may ask on the connection: a built-in provider's token (an ID token, or a GitHub
    /// user token), or an org provider's ticket (#1002).
    public typealias Provider = @Sendable (_ providers: DaemonAPI.SignInProviders, _ nonce: String, _ ask: Asking) async throws
        -> Answer

    /// What a sign-in gives: a built-in provider's token, or the ticket an org provider's
    /// flow came back with (#1002, D3).
    public enum Answer: Sendable, Equatable {
        case token(provider: String, token: String)
        case ticket(String)
    }

    /// What a sign-in screen asks on the connection that will pair (#1002): an org
    /// provider's flow to open in a browser, and the provider of a typed email.
    public struct Asking: Sendable {
        public let orgStart: @Sendable (_ provider: String, _ loginHint: String?) async throws -> URL
        public let discover: @Sendable (_ email: String) async throws -> DaemonAPI.SignInDiscovered

        public init(orgStart: @escaping @Sendable (String, String?) async throws -> URL,
                    discover: @escaping @Sendable (String) async throws -> DaemonAPI.SignInDiscovered) {
            self.orgStart = orgStart
            self.discover = discover
        }
    }

    public struct Failure: Error, Sendable, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// The control plane's key id, as the local owner's sign-in names it: SHA-256 of its key,
    /// the first 8 bytes in hex.
    public static func keyID(controlKey: Data) -> String {
        ControlAuth.hex(ControlAgreement.sha256(controlKey).prefix(8))
    }

    /// The code a sign-in that waits for approval shows, made here as the control plane makes
    /// it: SHA-256("agents-signin-approve" ‖ the new key's public half ‖ the control key this
    /// client trusts), two bytes a letter. Never the control plane's: one that passed the
    /// sign-in on could only pass on another key's code.
    public static func approvalCode(clientPublicKey: Data, controlKey: Data) -> String {
        let letters = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let sum = Array(ControlAgreement.sha256(Data("agents-signin-approve".utf8) + clientPublicKey + controlKey))
        return String((0..<6).map { letters[(Int(sum[2 * $0]) << 8 | Int(sum[2 * $0 + 1])) % letters.count] })
    }

    /// The nonce for a sign-in on one connection to one control plane:
    /// SHA-256("agents-signin-v1\0" ‖ key id ‖ "\0" ‖ challenge), in hex.
    public static func nonce(controlKey: Data, challenge: Data) -> String {
        let message = Data("agents-signin-v1\u{0}".utf8) + Data(keyID(controlKey: controlKey).utf8) + Data([0]) + challenge
        return ControlAuth.hex(ControlAgreement.sha256(message))
    }

    /// The nonce for `signIn/addToMe` on a paired client's connection: from the control key
    /// it trusts and the challenge `signIn/providers` gave.
    public static func nonce(controlKey: Data, providers: DaemonAPI.SignInProviders) -> String? {
        guard let text = providers.challenge, let challenge = ControlCode.data(base64url: text), challenge.count == 32 else {
            return nil
        }
        return nonce(controlKey: controlKey, challenge: challenge)
    }

    /// The providers turned on at `url`, read on an `s:` connection that is then closed: for a
    /// sign-in sheet to show only those. Refused (`unknown`) when none is on.
    public static func providers(url: URL, pin: String?, controlKey: Data?, kind: ClientRecord.Kind,
                                 dial: ControlCodeUse.Dial) async throws -> DaemonAPI.SignInProviders {
        let session = try await open(url: url, pin: pin, controlKey: controlKey, privateKey: ControlAgreement.generate().privateKey, id: UUID(),
                                     kind: kind, dial: dial)
        defer { session.reader.close() }
        return try await call(session.reader, id: 1, method: DaemonAPI.Method.signInProviders, params: .object([:]),
                              within: 15, waiting: nil).decode(DaemonAPI.SignInProviders.self)
    }

    /// Pairs as the person the sign-in names: what the client keeps to dial again. A GitHub
    /// sign-in waits for Approve on another of the person's clients; `waiting` is told the
    /// code to show, made here (`approvalCode`).
    public static func pair(url: URL, pin: String?, controlKey: Data?, privateKey: Data, id: UUID, name: String,
                            kind: ClientRecord.Kind, dial: ControlCodeUse.Dial, signIn: Provider,
                            waiting: (@Sendable (DaemonAPI.SignInWaiting) -> Void)? = nil) async throws -> ControlMembership {
        let session = try await open(url: url, pin: pin, controlKey: controlKey, privateKey: privateKey, id: id, kind: kind,
                                     dial: dial)
        defer { session.reader.close() }
        let line = Line(session.reader)
        let providers = try await line.call(DaemonAPI.Method.signInProviders, .object([:]), within: 15, waiting: nil)
            .decode(DaemonAPI.SignInProviders.self)
        let asking = Asking(orgStart: { provider, hint in
            let start = DaemonAPI.SignInOrgStart(provider: provider, purpose: .pair, returnTo: .app, loginHint: hint)
            let started = try await line.call(DaemonAPI.Method.signInOrgStart, try JSONValue.encoding(start), within: 30,
                                              waiting: nil).decode(DaemonAPI.SignInOrgStarted.self)
            guard let address = URL(string: started.url), ["https", "http"].contains(address.scheme?.lowercased()) else {
                throw Failure("the control plane gave no address to sign in at")
            }
            return address
        }, discover: { email in
            try await line.call(DaemonAPI.Method.signInDiscover, try JSONValue.encoding(DaemonAPI.SignInDiscover(email: email)),
                                within: 15, waiting: nil).decode(DaemonAPI.SignInDiscovered.self)
        })
        let paired: UUID?
        switch try await signIn(providers, nonce(controlKey: session.controlKey, challenge: session.helloNonce), asking) {
        case .token(let provider, let token):
            let request = DaemonAPI.SignInPair(provider: provider, token: token, name: name, kind: kind)
            let code = approvalCode(clientPublicKey: try ControlAgreement.publicKey(privateKey: privateKey),
                                    controlKey: session.controlKey)
            var shown: (@Sendable (DaemonAPI.SignInWaiting) -> Void)?
            if let waiting {
                shown = { told in waiting(DaemonAPI.SignInWaiting(code: code, expires: told.expires)) }
            }
            // Long enough for another client to approve a GitHub sign-in (10 minutes there).
            paired = try await line.call(DaemonAPI.Method.signInPair, try JSONValue.encoding(request), within: 11 * 60,
                                         waiting: shown).decode(DaemonAPI.Admitted.self).client
        case .ticket(let ticket):
            let request = DaemonAPI.SignInTicket(ticket: ticket, name: name, kind: kind)
            paired = try await line.call(DaemonAPI.Method.signInTicket, try JSONValue.encoding(request), within: 30,
                                         waiting: nil).decode(DaemonAPI.SignInTicketResult.self).client
        }
        guard paired == id else { throw Failure("the control plane paired another client") }
        return ControlMembership(client: id, controlKey: session.controlKey, addresses: [], name: session.name,
                                 url: url.absoluteString, pin: pin)
    }

    private struct Session {
        var reader: PrefixReader
        var controlKey: Data
        var helloNonce: Data
        var name: String
    }

    /// Dials as `s:<id>`, proves the key, and checks the control plane's proof of the key the
    /// nonce is bound to. `controlKey` is the key this client already trusts, or nil to take
    /// the hello's (an address alone, behind TLS or a pin).
    private static func open(url: URL, pin: String?, controlKey: Data?, privateKey: Data, id: UUID,
                             kind: ClientRecord.Kind, dial: ControlCodeUse.Dial) async throws -> Session {
        guard let origin = ControlAuth.origin(url) else { throw Failure("\(url) is not an address to dial") }
        let reader = PrefixReader(try await dial(url, pin))
        do {
            guard let line = try await reader.next(within: 15), case .hello(let hello)? = ControlAuth.Message(line: line),
                  let helloNonce = ControlCode.data(base64url: hello.nonce),
                  let trusted = controlKey ?? ControlCode.data(base64url: hello.control), trusted.count == 65 else {
                throw ControlAuth.Refusal(.badMessage)
            }
            let key = try ControlAuth.clientKey(privateKey: privateKey, peer: trusted, client: id)
            var (auth, expect) = try ControlAuth.answer(hello, identity: .signingIn(id), key: key, origin: origin,
                                                       kind: kind.rawValue, expecting: trusted)
            auth.publicKey = try ControlAgreement.publicKey(privateKey: privateKey)
            try reader.write(line: ControlAuth.Message.auth(auth).line)
            guard let reply = try await reader.next(within: 15), let message = ControlAuth.Message(line: reply) else {
                throw ControlAuth.Refusal(.badMessage)
            }
            switch message {
            case .ok(let ok): try ControlAuth.check(ok, expect: expect)
            case .refused(let reason): throw ControlAuth.Refusal(reason)
            default: throw ControlAuth.Refusal(.badMessage)
            }
            return Session(reader: reader, controlKey: trusted, helloNonce: helloNonce, name: hello.name)
        } catch {
            reader.close()
            throw error
        }
    }

    /// The connection's calls, one at a time, each with the next id.
    private actor Line {
        let reader: PrefixReader
        var next = 0

        init(_ reader: PrefixReader) { self.reader = reader }

        func call(_ method: String, _ params: JSONValue, within seconds: Double,
                  waiting: (@Sendable (DaemonAPI.SignInWaiting) -> Void)?) async throws -> JSONValue {
            next += 1
            return try await ControlSignIn.call(reader, id: next, method: method, params: params, within: seconds, waiting: waiting)
        }
    }

    fileprivate static func call(_ reader: PrefixReader, id: Int, method: String, params: JSONValue, within seconds: Double,
                             waiting: (@Sendable (DaemonAPI.SignInWaiting) -> Void)?) async throws -> JSONValue {
        try reader.write(line: JSONRPCCodec.encode(.request(id: .number(id), method: method, params: params)))
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, let line = try await reader.next(within: left) else {
                throw Failure("the control plane did not answer")
            }
            switch try JSONRPCCodec.decode(line: line) {
            case .notification(let name, let params) where name == DaemonAPI.Notification.controlSignInWaiting:
                if let params, let shown = try? params.decode(DaemonAPI.SignInWaiting.self) { waiting?(shown) }
            case .success(.number(id), let result):
                return result
            case .failure(_, let error):
                throw error
            default:
                continue
            }
        }
    }
}

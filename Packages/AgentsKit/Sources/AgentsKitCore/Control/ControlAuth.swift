import Foundation

/// How a client, a host or another copy proves its key to the control plane, and the
/// control plane proves its own back, at the start of every WebSocket (058, research R6,
/// contracts/wire.md "The key exchange").
///
/// Three messages: the server's `hello` with a nonce, the peer's `auth` with a nonce and
/// a MAC, and the server's `ok` with a MAC of its own, or `refused`. Each MAC is
/// HMAC-SHA256 under a key both sides can derive and nobody else can:
///
/// - a client (`c:<uuid>`) or a host (`h:<id>`): HKDF of the ECDH of its key and the
///   control plane's, the keys it already has;
/// - someone holding a code (`p:<id>`, `e:<id>`): HKDF of the code's secret;
/// - another copy (`x:<copy>`): HKDF of the control plane's private key alone.
///
/// Pure Swift, on `ControlAgreement`, so a Linux host and the service need no second
/// BoringSSL. It runs inside TLS, which is what stops a relay in the middle: the MACs
/// are not bound to the TLS session, so the peer must check the certificate or its pin.
public enum ControlAuth {
    public static let version = 1

    // MARK: Messages

    public struct Hello: Codable, Sendable, Equatable {
        public var v: Int
        public var name: String
        /// The control plane's public key, X9.63, base64url.
        public var control: String
        public var nonce: String
        public var copy: String
        /// The control plane's key before it rotated (#997), for 30 days after: a member
        /// that still trusts it proves itself with it, and is given the new key in `ok`.
        public var previous: String?
        public init(v: Int = ControlAuth.version, name: String, control: String, nonce: String, copy: String,
                    previous: String? = nil) {
            self.v = v
            self.name = name
            self.control = control
            self.nonce = nonce
            self.copy = copy
            self.previous = previous
        }
    }

    /// The control plane's new key in `ok` (#997), with the HMAC of it under the member's
    /// shared key from the previous one: only the previous key's holder could make it.
    public struct NewKey: Codable, Sendable, Equatable {
        public var key: String
        public var proof: String
        public init(key: String, proof: String) {
            self.key = key
            self.proof = proof
        }
    }

    public struct Auth: Codable, Sendable, Equatable {
        public var id: String
        public var nonce: String
        public var mac: String
        /// `mac`, `iphone`, `ipad`, `host`, `relay`, `copy`.
        public var kind: String
        /// A relayed device's id: `agents-relay` opens the socket for it (R10).
        public var `for`: String?
        /// The epoch of the endpoints this peer holds (R16), so the control plane knows
        /// who has heard of a move. Nil from a build that keeps none.
        public var epoch: Int?
        /// What a client has (#1748), so the control plane can tell one too old for it. Nil
        /// from a host, which says its own in `machine/hello`.
        public var capabilities: [String]?
        /// With an `s:` identity (#995): the key of the client that signs in, X9.63.
        public var publicKey: Data?
        public init(id: String, nonce: String, mac: String, kind: String, for device: String? = nil, epoch: Int? = nil,
                    capabilities: [String]? = nil, publicKey: Data? = nil) {
            self.id = id
            self.nonce = nonce
            self.mac = mac
            self.kind = kind
            self.for = device
            self.epoch = epoch
            self.capabilities = capabilities
            self.publicKey = publicKey
        }
    }

    public struct OK: Codable, Sendable, Equatable {
        public var mac: String
        /// `operator` for a client, for an older web page that shows it (#111). Not read.
        public var grant: String?
        public var host: MachineRef?
        public var relayed: Bool?
        /// Where the control plane answers now, and from when (R16): a member with an older
        /// epoch keeps this list in place of its own. Sent once one has been announced.
        public var endpoints: [ControlEndpoint]?
        public var epoch: Int?
        /// The control plane's new key, to a member that proved itself with the previous
        /// one (#997).
        public var newKey: NewKey?
        public init(mac: String, client: Bool = false, host: MachineRef? = nil, relayed: Bool? = nil,
                    endpoints: [ControlEndpoint]? = nil, epoch: Int? = nil, newKey: NewKey? = nil) {
            self.mac = mac
            self.grant = client ? LegacyGrant.everything : nil
            self.host = host
            self.relayed = relayed
            self.endpoints = endpoints
            self.epoch = epoch
            self.newKey = newKey
        }
    }

    public enum Reason: String, Codable, Sendable {
        case unknown, forgotten, expired, spent, badProof = "bad-proof", wrongControlPlane = "wrong-control-plane"
        case badMessage = "bad-message"
        /// The control plane could not tell, for now: its store could not be read, or it
        /// is being filled by a handover. Try again; it says nothing about the member (#81).
        /// A build from before this case cannot read it, and takes it as a failed dial.
        case unavailable
        /// The client's person was suspended by their org provider (#1002, D13). The client
        /// keeps its key and shows only that, until the provider turns them on again.
        case suspended
        /// The client's key, or its person, holds as many sockets as it may (#2150, #2194).
        /// Try again, as for unavailable; the web page says to close a tab.
        case crowded
    }

    /// One line of the exchange, as it goes on the wire.
    public enum Message: Sendable, Equatable {
        case hello(Hello)
        case auth(Auth)
        case ok(OK)
        case refused(Reason)

        public var line: String {
            let object: [String: JSONValue]
            switch self {
            case .hello(let hello): object = ["hello": (try? JSONValue.encoding(hello)) ?? .null]
            case .auth(let auth): object = ["auth": (try? JSONValue.encoding(auth)) ?? .null]
            case .ok(let ok): object = ["ok": (try? JSONValue.encoding(ok)) ?? .null]
            case .refused(let reason): object = ["refused": ["reason": .string(reason.rawValue)]]
            }
            let data = (try? Self.encoder.encode(JSONValue.object(object))) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }

        private static let encoder: JSONEncoder = {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return e
        }()

        public init?(line: String) {
            guard let value = try? JSONValue.parse(Data(line.utf8)), case .object(let object) = value, object.count == 1,
                  let (tag, body) = object.first else { return nil }
            switch tag {
            case "hello": guard let hello = try? body.decode(Hello.self) else { return nil }; self = .hello(hello)
            case "auth": guard let auth = try? body.decode(Auth.self) else { return nil }; self = .auth(auth)
            case "ok": guard let ok = try? body.decode(OK.self) else { return nil }; self = .ok(ok)
            case "refused":
                guard let text = body["reason"]?.stringValue, let reason = Reason(rawValue: text) else { return nil }
                self = .refused(reason)
            default: return nil
            }
        }
    }

    // MARK: Identities

    public enum Identity: Sendable, Hashable {
        case client(UUID)
        /// A client signing in with no code (#995): the UUID it will pair as.
        case signingIn(UUID)
        case host(MachineRef)
        /// A client code's id (hex), or a host code's.
        case pairing(String)
        case enrolling(String)
        case copy(String)

        public var text: String {
            switch self {
            case .client(let id): "c:" + id.uuidString
            case .signingIn(let id): "s:" + id.uuidString
            case .host(let id): "h:" + id.rawValue
            case .pairing(let id): "p:" + id
            case .enrolling(let id): "e:" + id
            case .copy(let id): "x:" + id
            }
        }

        public init?(text: String) {
            let rest = String(text.dropFirst(2))
            switch text.prefix(2) {
            case "c:": guard let id = UUID(uuidString: rest) else { return nil }; self = .client(id)
            case "s:": guard let id = UUID(uuidString: rest) else { return nil }; self = .signingIn(id)
            case "h:": guard ControlWire.isHostID(rest) else { return nil }; self = .host(MachineRef(rawValue: rest))
            case "p:": guard ControlAuth.isCodeID(rest) else { return nil }; self = .pairing(rest)
            case "e:": guard ControlAuth.isCodeID(rest) else { return nil }; self = .enrolling(rest)
            case "x:": guard !rest.isEmpty, rest.count <= 64 else { return nil }; self = .copy(rest)
            default: return nil
            }
        }
    }

    // MARK: Keys

    public static let clientSalt = "agents-control-client-v1"
    public static let hostSalt = "agents-control-host-v1"

    /// What a client and the control plane share: the same derivation `ControlKeys`
    /// makes with CryptoKit, so a key paired under the first build still proves itself.
    public static func clientKey(privateKey: Data, peer: Data, client: UUID) throws -> Data {
        let shared = try ControlAgreement.sharedSecret(privateKey: privateKey, peerPublic: peer)
        return ControlAgreement.hkdfSHA256(ikm: shared, salt: Data(clientSalt.utf8),
                                           info: Data(client.uuidString.utf8), length: 32)
    }

    public static func hostKey(privateKey: Data, peer: Data, host: MachineRef) throws -> Data {
        try ControlAgreement.hostKey(privateKey: privateKey, peer: peer, host: host)
    }

    /// What every copy shares, and only copies: it comes from the control plane's
    /// private key, which only they hold (FR-010).
    public static func copyKey(controlPrivateKey: Data) -> Data {
        ControlAgreement.hkdfSHA256(ikm: controlPrivateKey, salt: Data("agents-copy-v1".utf8), info: Data(), length: 32)
    }

    // MARK: Codes

    /// A code's secret is its id and a tag only a copy can make: 16 random bytes, then
    /// 16 bytes of HMAC under a key from the control plane's private key. Any copy can
    /// check a code another copy showed, and the store holds only the id (rule 7).
    public static func makeCodeSecret(controlPrivateKey: Data) -> (id: String, secret: Data) {
        var generator = SystemRandomNumberGenerator()
        let id = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return (hex(id), id + codeTag(controlPrivateKey: controlPrivateKey, id: id))
    }

    /// The secret a copy expects for a code id, or nil if the id is not one.
    public static func codeSecret(controlPrivateKey: Data, id: String) -> Data? {
        guard let raw = unhex(id), raw.count == 16 else { return nil }
        return raw + codeTag(controlPrivateKey: controlPrivateKey, id: raw)
    }

    /// The id a holder of the secret presents.
    public static func codeID(secret: Data) -> String? {
        secret.count == 32 ? hex(secret.prefix(16)) : nil
    }

    public static func codeKey(secret: Data) -> Data { ControlAgreement.codeKey(secret) }

    static func isCodeID(_ text: String) -> Bool { text.count == 32 && unhex(text) != nil }

    private static func codeTag(controlPrivateKey: Data, id: Data) -> Data {
        let key = ControlAgreement.hkdfSHA256(ikm: controlPrivateKey, salt: Data("agents-codes-v1".utf8),
                                              info: Data(), length: 32)
        return ControlAgreement.hmacSHA256(key: key, message: Data("agents-code-v1".utf8) + id).prefix(16)
    }

    // MARK: Proofs

    /// `scheme://host:port`, lowercased, with the default port written out, so both ends
    /// agree whatever the dialled URL looked like. `wss` counts as `https`.
    public static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let normal = scheme == "wss" ? "https" : scheme == "ws" ? "http" : scheme
        let port = url.port ?? (normal == "https" ? 443 : 80)
        return "\(normal)://\(host):\(port)"
    }

    static func transcript(serverNonce: Data, peerNonce: Data, identity: String, origin: String) -> Data {
        Data("agents-auth-v1".utf8) + serverNonce + peerNonce + Data(identity.utf8) + Data(origin.utf8)
    }

    public static func peerMAC(key: Data, serverNonce: Data, peerNonce: Data, identity: String, origin: String) -> Data {
        ControlAgreement.hmacSHA256(key: key, message: Data("c".utf8)
            + transcript(serverNonce: serverNonce, peerNonce: peerNonce, identity: identity, origin: origin))
    }

    public static func serverMAC(key: Data, serverNonce: Data, peerNonce: Data, identity: String, origin: String) -> Data {
        ControlAgreement.hmacSHA256(key: key, message: Data("s".utf8)
            + transcript(serverNonce: serverNonce, peerNonce: peerNonce, identity: identity, origin: origin))
    }

    public static func nonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Compares two MACs in time that does not depend on where they differ.
    public static func same(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: The peer's side

    /// What a client, a host or a copy says in answer to `hello`, and the MAC it then
    /// expects in `ok`. `controlKey` is the key it already trusts; a hello with any other
    /// is not its control plane.
    public static func answer(_ hello: Hello, identity: Identity, key: Data, origin: String, kind: String,
                              expecting controlKey: Data?, for device: UUID? = nil, epoch: Int? = nil)
        throws -> (auth: Auth, expect: Data) {
        guard hello.v == version, let serverNonce = ControlCode.data(base64url: hello.nonce), serverNonce.count == 32 else {
            throw Refusal(.badMessage)
        }
        if let controlKey, !trusts(hello, controlKey: controlKey) {
            throw Refusal(.wrongControlPlane)
        }
        let peerNonce = nonce()
        let text = identity.text
        let mac = peerMAC(key: key, serverNonce: serverNonce, peerNonce: peerNonce, identity: text, origin: origin)
        let expect = serverMAC(key: key, serverNonce: serverNonce, peerNonce: peerNonce, identity: text, origin: origin)
        var capabilities: [String]?
        if case .client = identity { capabilities = Capability.declared["client"] }
        return (Auth(id: text, nonce: ControlCode.base64url(peerNonce), mac: ControlCode.base64url(mac), kind: kind,
                     for: device?.uuidString, epoch: epoch, capabilities: capabilities), expect)
    }

    /// Whether a hello is from the control plane a member trusts: its key now, or the one
    /// before it rotated (#997), which the member then proves itself with.
    static func trusts(_ hello: Hello, controlKey: Data) -> Bool {
        ControlCode.data(base64url: hello.control) == controlKey
            || hello.previous.flatMap { ControlCode.data(base64url: $0) } == controlKey
    }

    /// The proof of a rotated key (#997): HMAC of the new key under the member's shared key.
    public static func newKeyProof(shared: Data, newKey: Data) -> Data {
        ControlAgreement.hmacSHA256(key: shared, message: Data("k".utf8) + Data("agents-newkey-v1".utf8) + newKey)
    }

    /// The control plane's new key from an `ok` (#997), checked against the member's shared
    /// key: nil when it gives none, and a refusal when its proof is not the previous key's
    /// holder's.
    public static func newKey(_ ok: OK, shared: Data) throws -> Data? {
        guard let offer = ok.newKey else { return nil }
        guard let key = ControlCode.data(base64url: offer.key), key.count == 65,
              let proof = ControlCode.data(base64url: offer.proof),
              same(proof, newKeyProof(shared: shared, newKey: key)) else {
            throw Refusal(.wrongControlPlane)
        }
        return key
    }

    /// Checks the server's `ok` against what `answer` said to expect.
    public static func check(_ ok: OK, expect: Data) throws {
        guard let mac = ControlCode.data(base64url: ok.mac), same(mac, expect) else {
            throw Refusal(.wrongControlPlane)
        }
    }

    // MARK: The server's side

    /// Checks a peer's `auth` for a hello this copy sent. `key` finds the shared key for
    /// an identity, or says why there is none. Returns who it is and the server's MAC.
    public static func verify(_ auth: Auth, serverNonce: Data, origin: String,
                              key: (Identity) async throws -> Data) async throws -> (Identity, mac: Data) {
        try await verify(auth, serverNonce: serverNonce, origins: [origin], key: key)
    }

    /// As above, for a control plane that answers at several places (R16): the peer's
    /// MAC may bind any one of them, and the server's binds the same one.
    public static func verify(_ auth: Auth, serverNonce: Data, origins: [String],
                              key: (Identity) async throws -> Data) async throws -> (Identity, mac: Data) {
        guard let identity = Identity(text: auth.id),
              let peerNonce = ControlCode.data(base64url: auth.nonce), peerNonce.count == 32,
              let mac = ControlCode.data(base64url: auth.mac) else { throw Refusal(.badMessage) }
        let shared = try await key(identity)
        for origin in origins {
            let wanted = peerMAC(key: shared, serverNonce: serverNonce, peerNonce: peerNonce, identity: auth.id, origin: origin)
            if same(mac, wanted) {
                return (identity, serverMAC(key: shared, serverNonce: serverNonce, peerNonce: peerNonce,
                                            identity: auth.id, origin: origin))
            }
        }
        throw Refusal(.badProof)
    }

    public struct Refusal: Error, Sendable, Equatable {
        public var reason: Reason
        public init(_ reason: Reason) { self.reason = reason }
    }

    // MARK: Hex

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func unhex(_ text: String) -> Data? {
        guard text.count.isMultiple(of: 2) else { return nil }
        var out = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

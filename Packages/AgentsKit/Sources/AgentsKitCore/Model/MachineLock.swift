#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// The machine lock (#3399, `specs/3399-machine-lock`): a chain of signed entries that says
/// which clients may sign and which machines are the person's. The control plane keeps it
/// and signs nothing; each client checks it as Go's `machinelock` does, and pins the head it
/// last saw. A client that is not in the lock asks to join (#3490, D2): it commits to its
/// key and a nonce, a signer sends a nonce of its own, then the client shows its nonce, and
/// both screens show six digits.
/// The types are hand-written against `Packages/Wire/daemon.schema.json` (`WireSchemaTests`).
public extension DaemonAPI {
    enum LockEntryKind: String, Codable, Sendable, Hashable {
        case root, addClient, addMachine, invite, remove, recovery
    }

    /// What an entry says, as its signer wrote it.
    struct LockBody: Codable, Sendable, Hashable {
        public var v: Int
        public var kind: LockEntryKind
        public var person: String
        public var previous: Data?
        public var signer: Data
        public var at: Date
        public var key: Data
        public var sealingKey: Data?
        public var id: String?
        public var name: String?
        public var clientKind: String?
        public var expires: Date?
        /// A recovery entry's (#3493): the recovery key's private half, sealed under the secret.
        public var sealed: Data?

        public init(kind: LockEntryKind, person: String, previous: Data? = nil, signer: Data = Data(), at: Date = Date(),
                    key: Data, sealingKey: Data? = nil, id: String? = nil, name: String? = nil, clientKind: String? = nil,
                    expires: Date? = nil, sealed: Data? = nil) {
            v = 1
            self.kind = kind
            self.person = person
            self.previous = previous
            self.signer = signer
            self.at = at
            self.key = key
            self.sealingKey = sealingKey
            self.id = id
            self.name = name
            self.clientKind = clientKind
            self.expires = expires
            self.sealed = sealed
        }
    }

    /// One entry: the body's JSON, kept as the signer wrote it, and its signature (r then s).
    struct LockEntry: Codable, Sendable, Hashable {
        public var body: Data
        public var sig: Data

        public init(body: Data, sig: Data) {
            self.body = body
            self.sig = sig
        }
    }

    /// `lock/get`: the person's chain, the root first.
    struct Lock: Codable, Sendable, Hashable {
        public var person: String
        public var entries: [LockEntry]

        public init(person: String, entries: [LockEntry]) {
            self.person = person
            self.entries = entries
        }
    }

    /// `lock/add`.
    struct LockAdd: Codable, Sendable, Hashable {
        public var entries: [LockEntry]

        public init(entries: [LockEntry]) { self.entries = entries }
    }

    /// `lock/add`'s answer, and `control/lockChanged`.
    struct LockHead: Codable, Sendable, Hashable {
        public var count: Int
        public var head: Data
    }

    /// `lock/hello` (#3492, D6): a client opens a checked channel to a machine.
    struct LockHello: Codable, Sendable, Hashable {
        public var key: Data
        public var ephemeral: Data
        public var sig: Data

        public init(key: Data, ephemeral: Data, sig: Data) {
            self.key = key
            self.ephemeral = ephemeral
            self.sig = sig
        }
    }

    /// `lock/hello`'s answer: the machine's key, its ephemeral key, and its signature.
    struct LockHelloReply: Codable, Sendable, Hashable {
        public var key: Data
        public var ephemeral: Data
        public var sig: Data

        public init(key: Data, ephemeral: Data, sig: Data) {
            self.key = key
            self.ephemeral = ephemeral
            self.sig = sig
        }
    }

    /// A request signed by its sender (#3492): a client's kept request, as a request's `lock`.
    /// `at` is seconds since 1970.
    struct LockSignature: Codable, Sendable, Hashable {
        public var to: String?
        public var at: Int64
        public var key: Data
        public var sig: Data

        public init(to: String?, at: Int64, key: Data, sig: Data) {
            self.to = to
            self.at = at
            self.key = key
            self.sig = sig
        }
    }

    /// A signed request as the control plane keeps and delivers it: its params as text.
    struct LockDelivery: Codable, Sendable, Hashable {
        public var method: String
        public var params: String
        public var lock: LockSignature

        public init(method: String, params: String, lock: LockSignature) {
            self.method = method
            self.params = params
            self.lock = lock
        }
    }

    /// `lock/join`.
    struct LockJoin: Codable, Sendable, Hashable {
        public var key: Data
        public var commitment: Data

        public init(key: Data, commitment: Data) {
            self.key = key
            self.commitment = commitment
        }
    }

    /// `lock/join`'s answer.
    struct LockJoinStarted: Codable, Sendable, Hashable {
        public var request: String
        public var expires: Date
    }

    /// `lock/get`: with `person`, another person's lock, an admin's only (#3491).
    struct LockGet: Codable, Sendable, Hashable {
        public var person: String?

        public init(person: String? = nil) { self.person = person }
    }

    /// `lock/joinRequests` and `control/lockJoinRequested`: a client asking to join, sent
    /// again in place as it goes on. `machine` is set when a machine asks (#3491): `client` is
    /// then its id, and a signer approves it with an addMachine.
    struct LockJoinRequest: Codable, Sendable, Hashable, Identifiable {
        public var request: String
        public var client: String
        public var machine: String?
        public var name: String
        public var kind: ClientRecord.Kind
        public var key: Data
        public var commitment: Data
        public var expires: Date
        /// The signer's nonce, once one sent it.
        public var nonce: Data?
        public var answeredBy: String?
        /// The asking client's nonce, once it showed it.
        public var reveal: Data?

        public init(request: String, client: String, machine: String? = nil, name: String, kind: ClientRecord.Kind, key: Data,
                    commitment: Data, expires: Date, nonce: Data? = nil, answeredBy: String? = nil, reveal: Data? = nil) {
            self.request = request
            self.client = client
            self.machine = machine
            self.name = name
            self.kind = kind
            self.key = key
            self.commitment = commitment
            self.expires = expires
            self.nonce = nonce
            self.answeredBy = answeredBy
            self.reveal = reveal
        }

        public var id: String { request }
    }

    /// `lock/joinAnswer` and `lock/joinReveal`.
    struct LockJoinNonce: Codable, Sendable, Hashable {
        public var request: String
        public var nonce: Data

        public init(request: String, nonce: Data) {
            self.request = request
            self.nonce = nonce
        }
    }

    /// `lock/joinDeny`.
    struct LockJoinEnd: Codable, Sendable, Hashable {
        public var request: String

        public init(request: String) { self.request = request }
    }

    /// `control/lockJoinDecided`: approved, denied or expired.
    struct LockJoinDecided: Codable, Sendable, Hashable {
        public var request: String
        public var result: String
    }
}

public extension DaemonAPI.Method {
    /// `LockGet` → `Lock` (#3399, #3491).
    static let lockGet = "lock/get"
    /// `LockHello` → `LockHelloReply`: a host's, the checked channel's start (#3492).
    static let lockHello = "lock/hello"
    /// `LockAdd` → `LockHead` (#3399).
    static let lockAdd = "lock/add"
    /// `LockJoin` → `LockJoinStarted` (#3490).
    static let lockJoin = "lock/join"
    /// `Empty` → `[LockJoinRequest]` (#3490).
    static let lockJoinRequests = "lock/joinRequests"
    /// `LockJoinNonce` → `{}` (#3490).
    static let lockJoinAnswer = "lock/joinAnswer"
    /// `LockJoinNonce` → `{}` (#3490).
    static let lockJoinReveal = "lock/joinReveal"
    /// `LockJoinEnd` → `{}` (#3490).
    static let lockJoinDeny = "lock/joinDeny"
    /// `{}` → `{}` (#3493): start a new lock, when every signer and the recovery key are lost.
    static let lockReset = "lock/reset"
}

public extension DaemonAPI.Notification {
    /// `LockHead`: an entry was put on the person's lock (#3399).
    static let controlLockChanged = "control/lockChanged"
    /// `LockJoinRequest` (#3490).
    static let controlLockJoinRequested = "control/lockJoinRequested"
    /// `LockJoinDecided` (#3490).
    static let controlLockJoinDecided = "control/lockJoinDecided"
}

#if canImport(CryptoKit)
/// The lock's checks, the same as Go's `machinelock`: `check` reads a whole chain, `follow`
/// checks it against the pin kept last.
public enum MachineLock {
    public static let version = 1
    public static let mostEntries = 4096
    public static let mostBody = 4096
    public static let nonceSize = 16
    static let domain = Data("agents-lock/1\n".utf8)
    static let commitDomain = Data("agents-lock-join/1\n".utf8)
    static let digitsDomain = Data("agents-lock-digits/1\n".utf8)

    /// Why a check failed, as Go's errors say it.
    public enum Failure: Error, Sendable, Hashable {
        case forged(String)
        case outOfOrder(String)
        case invalid(String)
        /// The lock does not grow from the pinned head.
        case forked(String)
        /// The lock is shorter than the pinned head.
        case behind(String)

        /// A fork, or a lock kept back: what the screen says in place of the reason.
        public var isFork: Bool {
            switch self {
            case .forked, .behind: true
            default: false
            }
        }

        public var why: String {
            switch self {
            case .forged(let why), .outOfOrder(let why), .invalid(let why), .forked(let why), .behind(let why): why
            }
        }
    }

    /// A key the lock names.
    public struct Member: Sendable, Hashable {
        public var kind: DaemonAPI.LockEntryKind
        public var key: Data
        public var sealingKey: Data?
        public var id: String?
        public var name: String?
        public var clientKind: String?
        public var expires: Date?
        public var entry: Int

        /// A client, so a signer.
        public var isClient: Bool { kind == .root || kind == .addClient }
    }

    /// What a client keeps of the lock it last checked.
    public struct Pin: Codable, Sendable, Hashable {
        public var person: String
        public var count: Int
        public var head: Data

        public init(person: String, count: Int, head: Data) {
            self.person = person
            self.count = count
            self.head = head
        }
    }

    /// A lock as its entries leave it.
    public struct State: Sendable {
        public private(set) var person = ""
        /// The root's hash: the lock's fingerprint.
        public private(set) var root = Data()
        public private(set) var hashes: [Data] = []
        public private(set) var members: [Data: Member] = [:]
        public private(set) var recovery: Data?
        /// The recovery key's private half, sealed under the person's secret (#3493).
        public private(set) var recoverySealed: Data?

        public init() {}

        public var count: Int { hashes.count }
        /// The newest entry's hash; empty for a lock with no entries.
        public var head: Data { hashes.last ?? Data() }
        public var pin: Pin { Pin(person: person, count: count, head: head) }

        /// The key may sign: a client of the lock, or the recovery key.
        public func isSigner(_ key: Data) -> Bool {
            if let member = members[key] { return member.isClient }
            return recovery == key
        }

        /// The key is a client of the lock, but for another client id than `client` (#4292). A
        /// new sign-in pairs a device again with a new id, and a machine refuses a channel whose
        /// member is not the client the control plane names, so the device needs a key of its
        /// own for the new id. A member with no id, or no client yet, names nobody else.
        public func namesAnotherClient(_ key: Data, client: String?) -> Bool {
            guard let member = members[key], member.isClient, let id = member.id, let client else { return false }
            return id.caseInsensitiveCompare(client) != .orderedSame
        }

        /// Takes one entry when it passes the checks.
        public mutating func add(_ entry: DaemonAPI.LockEntry) throws(Failure) {
            let i = hashes.count
            if i >= MachineLock.mostEntries { throw .invalid("entry \(i): the lock has the most entries it takes") }
            let body = try MachineLock.open(entry, index: i)
            guard MachineLock.validKey(body.key) else { throw .invalid("entry \(i): its key is not a P-256 key") }
            if i == 0 {
                guard body.kind == .root else { throw .outOfOrder("entry 0 is \(body.kind.rawValue), not root") }
                guard body.previous?.isEmpty ?? true else { throw .outOfOrder("the root names an entry before it") }
                guard !body.person.isEmpty else { throw .invalid("the root names no person") }
                guard body.signer == body.key else { throw .forged("the root is not signed by the key it names") }
                person = body.person
                members = [:]
                take(body, at: i)
                root = MachineLock.hash(entry)
                hashes.append(root)
                return
            }
            guard body.person == person else { throw .forged("entry \(i) names another person") }
            guard body.previous == head else { throw .outOfOrder("entry \(i) does not follow the head") }
            var signer = isSigner(body.signer)
            var spent: Data?
            switch body.kind {
            case .root:
                throw .outOfOrder("entry \(i) is a second root")
            case .addMachine:
                guard let sealing = body.sealingKey, MachineLock.validKey(sealing) else {
                    throw .invalid("entry \(i): the machine's sealing key is not a P-256 key")
                }
                if let invite = members[body.signer], invite.kind == .invite {
                    guard let expires = invite.expires, body.at < expires else { throw .forged("entry \(i): its invite expired") }
                    spent = body.signer
                    signer = true
                }
            case .invite:
                guard let expires = body.expires, expires > body.at else { throw .invalid("entry \(i): the invite has no expiry") }
            case .addClient, .remove, .recovery:
                break
            }
            guard signer else { throw .forged("entry \(i): its signer is not a client or the recovery key of the lock") }
            switch body.kind {
            case .remove:
                guard members[body.key] != nil else { throw .invalid("entry \(i) removes a key the lock does not name") }
                members[body.key] = nil
            case .recovery:
                guard members[body.key] == nil else { throw .invalid("entry \(i): the recovery key is a member of the lock") }
                recovery = body.key
                recoverySealed = body.sealed
            default:
                guard members[body.key] == nil, body.key != recovery else { throw .invalid("entry \(i): its key is in the lock already") }
                take(body, at: i)
            }
            if let spent { members[spent] = nil }
            hashes.append(MachineLock.hash(entry))
        }

        private mutating func take(_ body: DaemonAPI.LockBody, at i: Int) {
            members[body.key] = Member(kind: body.kind, key: body.key, sealingKey: body.sealingKey, id: body.id, name: body.name,
                                       clientKind: body.clientKind, expires: body.expires, entry: i)
        }
    }

    /// An entry's hash: the SHA-256 of its body.
    public static func hash(_ entry: DaemonAPI.LockEntry) -> Data { Data(SHA256.hash(data: entry.body)) }

    static func validKey(_ key: Data) -> Bool { (try? P256.KeyAgreement.PublicKey(x963Representation: key)) != nil }

    /// What a signature covers: the domain, then the body.
    static func signed(_ body: Data) -> Data { domain + body }

    /// Reads an entry's body and checks its signature by the signer it names.
    public static func open(_ entry: DaemonAPI.LockEntry, index: Int = 0) throws(Failure) -> DaemonAPI.LockBody {
        guard entry.body.count <= mostBody else { throw .invalid("entry \(index): its body is over \(mostBody) bytes") }
        let body: DaemonAPI.LockBody
        do {
            body = try JSONDecoder().decode(DaemonAPI.LockBody.self, from: entry.body)
        } catch {
            throw .invalid("entry \(index): its body does not read")
        }
        guard body.v == version else { throw .invalid("entry \(index): version \(body.v), not \(version)") }
        guard let key = try? P256.Signing.PublicKey(x963Representation: body.signer) else {
            throw .forged("entry \(index): its signer is not a P-256 key")
        }
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: entry.sig),
              key.isValidSignature(signature, for: signed(entry.body)) else {
            throw .forged("entry \(index): its signature does not check")
        }
        return body
    }

    /// Reads a whole chain, the root first.
    public static func check(_ entries: [DaemonAPI.LockEntry]) throws(Failure) -> State {
        var state = State()
        for entry in entries { try state.add(entry) }
        return state
    }

    /// Checks a lock against the pin kept last: it must check, be the same person's, and grow
    /// from the pinned head. No pin takes any lock that checks (trust on first use, D9).
    public static func follow(_ pin: Pin?, _ lock: DaemonAPI.Lock) throws(Failure) -> State {
        let state = try check(lock.entries)
        guard let pin, pin.count > 0 else { return state }
        guard state.person == pin.person else { throw .forked("it is another person's lock") }
        guard state.count >= pin.count else { throw .behind("\(state.count) entries, and \(pin.count) were seen") }
        guard state.hashes[pin.count - 1] == pin.head else { throw .forked("entry \(pin.count - 1) is not the one pinned") }
        return state
    }

    /// What a new client sends first: SHA-256 of the domain, its key, its nonce.
    public static func commitment(key: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: commitDomain + key + nonce))
    }

    /// The six digits both screens show.
    public static func digits(key: Data, clientNonce: Data, signerNonce: Data) -> String {
        let sum = Array(SHA256.hash(data: digitsDomain + key + clientNonce + signerNonce))
        let value = (UInt32(sum[0]) << 24) | (UInt32(sum[1]) << 16) | (UInt32(sum[2]) << 8) | UInt32(sum[3])
        let text = String(value % 1_000_000)
        return String(repeating: "0", count: 6 - text.count) + text
    }

    /// The digits as a screen shows them: "123 456".
    public static func shown(_ digits: String) -> String {
        "\(digits.prefix(3)) \(digits.dropFirst(3))"
    }

    /// A new nonce.
    public static func nonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceSize)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    /// An addClient's clientKind, from the record's kind.
    public static func clientKind(_ kind: ClientRecord.Kind) -> String {
        switch kind {
        case .mac: "mac"
        case .iPhone, .iPad: "remote"
        case .browser: "web"
        default: kind.rawValue
        }
    }

    /// The lock names `key` as a machine's sealing key (#3491, D8).
    public static func sealsTo(_ state: State, key: Data) -> Bool {
        state.members.values.contains { $0.kind == .addMachine && $0.sealingKey == key }
    }

    /// The recipients a client may seal to (#3491, D8): every client, and each machine whose
    /// key its owner's lock names as a sealing key. `stateOf` is a person's checked lock (nil:
    /// the caller's own), or nil when it does not check; a machine whose lock is nil is left out.
    public static func signedRecipients(_ recipients: [DaemonAPI.SealRecipient], isolation: isolated (any Actor)? = #isolation,
                                        stateOf: (String?) async -> State?) async -> [DaemonAPI.SealRecipient] {
        var states: [String: State?] = [:]
        var out: [DaemonAPI.SealRecipient] = []
        for r in recipients {
            guard r.id.hasPrefix("m:") else {
                out.append(r)
                continue
            }
            let person = r.owner ?? ""
            if states[person] == nil { states[person] = .some(await stateOf(r.owner)) }
            if let state = states[person] ?? nil, sealsTo(state, key: r.publicKey) { out.append(r) }
        }
        return out
    }

    /// An invite's key (D3): a software key, since its private half goes in a join code.
    public static func inviteKey() -> P256.Signing.PrivateKey { P256.Signing.PrivateKey() }

    /// A host code with an invite (#3491, D3): version 4, the control plane's version 2 or 3
    /// code with the invite's private key and the lock's pin after the invite, as Go's
    /// `controllink.Code` reads it. A code that is not a host's version 2 or 3 comes back as it was.
    public static func inviteCode(_ text: String, invite: Data, pin: Pin) -> String {
        var fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3, fields[0] == "agents-control", fields[2] == "h",
              fields.count == 9 && fields[1] == "2" || fields.count == 10 && fields[1] == "3" else { return text }
        if fields.count == 9 { fields.append("-") }
        fields[1] = "4"
        fields += [base64URL(invite), escapeField(pin.person), String(pin.count), base64URL(pin.head)]
        return fields.joined(separator: ":")
    }

    /// Keeps an invite in a host's root (#4248, D3) as its join code would: the file that Go's
    /// `controllink.SaveLockInvite` writes, 0600. The host signs its own addMachine with it,
    /// and pins the lock from it, when the control plane sends the lock.
    public static func keepInvite(_ invite: Data, pin: Pin, in locations: StoreLocations) throws {
        struct File: Encodable { let key: Data, person: String, count: Int, head: Data }
        let data = try JSONEncoder().encode(File(key: invite, person: pin.person, count: pin.count, head: pin.head))
        let file = locations.lockInvite
        let made = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).tmp")
        guard FileManager.default.createFile(atPath: made.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(made.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Percent-encoding as Go's `controllink` escape: only ASCII letters, digits, ".", "-" and "_" stay.
    static func escapeField(_ text: String) -> String {
        Data(text.utf8).map { byte in
            let c = Character(UnicodeScalar(byte))
            return byte < 0x80 && (c.isLetter || c.isNumber || c == "." || c == "-" || c == "_") ? String(c) : String(format: "%%%02X", byte)
        }.joined()
    }

    /// Signs `body` as the next entry of `state` with `key`: sets previous, person and signer.
    public static func sign(_ body: DaemonAPI.LockBody, after state: State?, with key: LockSigningKey) throws -> DaemonAPI.LockEntry {
        var body = body
        body.signer = key.publicKey
        if let state, state.count > 0 {
            body.previous = state.head
            body.person = state.person
        }
        let data = try JSONEncoder().encode(body)
        return DaemonAPI.LockEntry(body: data, sig: try key.sign(signed(data)))
    }
}

/// The recovery key (#3493, `specs/3399-machine-lock` D4), as Go's `machinelock/recovery.go`
/// makes it: a P-256 signing key made at random, its public half a signer of the lock, its
/// private half sealed in the recovery entry under a 16-byte secret that only the person keeps.
/// The person sees the secret with a 4-byte check as 32 letters and digits in groups of four
/// (Crockford's base32), so a typo is found before anything is sent.
public extension MachineLock {
    static let recoverySecretSize = 16
    private static let recoveryCheckDomain = Data("agents-lock-recovery-check/1\n".utf8)
    private static let recoverySealDomain = Data("agents-lock-recovery/1\n".utf8)
    private static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Typed text that is not a recovery key, or a key that is not this lock's.
    enum RecoveryError: Error, Equatable {
        case typo, notThisLock
    }

    private static func recoveryCheck(_ secret: Data) -> Data { Data(SHA256.hash(data: recoveryCheckDomain + secret).prefix(4)) }

    /// The secret as the person sees it: "ABCD-EFGH-…", eight groups of four.
    static func recoveryText(_ secret: Data) -> String {
        var out = ""
        var acc = 0, bits = 0, n = 0
        for byte in secret + recoveryCheck(secret) {
            acc = (acc << 8 | Int(byte)) & 0xFFFF
            bits += 8
            while bits >= 5 {
                bits -= 5
                if n > 0, n % 4 == 0 { out.append("-") }
                out.append(crockford[(acc >> bits) & 31])
                n += 1
            }
        }
        return out
    }

    /// Reads a secret as typed: any case, dashes and spaces or none, O as 0, I and L as 1.
    static func parseRecovery(_ text: String) throws(RecoveryError) -> Data {
        var raw = Data()
        var acc = 0, bits = 0, count = 0
        for var c in text.uppercased() {
            if c == "-" || c.isWhitespace { continue }
            if c == "O" { c = "0" }
            if c == "I" || c == "L" { c = "1" }
            guard let v = crockford.firstIndex(of: c) else { throw .typo }
            count += 1
            acc = (acc << 5 | v) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                raw.append(UInt8((acc >> bits) & 0xFF))
            }
        }
        guard count == 32, raw.count == recoverySecretSize + 4 else { throw .typo }
        let secret = raw.prefix(recoverySecretSize)
        guard recoveryCheck(Data(secret)) == raw.suffix(4) else { throw .typo }
        return Data(secret)
    }

    private static func recoveryKey(_ secret: Data, _ publicKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(), info: recoverySealDomain + publicKey,
                               outputByteCount: 32)
    }

    /// A new recovery key: the text to show once, and the public half and the sealed private
    /// half for its entry.
    static func makeRecovery() throws -> (text: String, publicKey: Data, sealed: Data) {
        let secret = Data((0..<recoverySecretSize).map { _ in UInt8.random(in: 0...255) })
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        let box = try AES.GCM.seal(key.rawRepresentation, using: recoveryKey(secret, publicKey), authenticating: publicKey)
        return (recoveryText(secret), publicKey, box.nonce.withUnsafeBytes { Data($0) } + box.ciphertext + box.tag)
    }

    /// Opens the lock's recovery key with the secret the person typed.
    static func openRecovery(_ secret: Data, publicKey: Data, sealed: Data) throws(RecoveryError) -> LockSigningKey {
        guard sealed.count > 28,
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let raw = try? AES.GCM.open(box, using: recoveryKey(secret, publicKey), authenticating: publicKey),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: raw),
              key.publicKey.x963Representation == publicKey else { throw .notThisLock }
        return LockSigningKey.recovery(key)
    }
}

/// A client's signing key for the lock (D5): P-256, used only to sign. In the Secure Enclave
/// where there is one, so it cannot leave the device; else a software key in the keychain,
/// this device only. The ECDH key the client proves itself with stays as it is.
public struct LockSigningKey: Sendable {
    /// X9.63, 65 bytes, as an entry names it.
    public let publicKey: Data
    private let holder: Holder

    private enum Holder: @unchecked Sendable {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    /// The key for `account`, made and kept on first use.
    public static func load(account: String = "lock-signing-key", accessGroup: String? = nil) throws -> LockSigningKey {
        let keychain = DeviceKey.Keychain(accessGroup: accessGroup)
        if let stored = try keychain.read(account: account) {
            if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored) {
                return LockSigningKey(publicKey: key.publicKey.x963Representation, holder: .enclave(key))
            }
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: stored) {
                return LockSigningKey(publicKey: key.publicKey.x963Representation, holder: .software(key))
            }
        }
        let made: LockSigningKey
        let representation: Data
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            made = LockSigningKey(publicKey: key.publicKey.x963Representation, holder: .enclave(key))
            representation = key.dataRepresentation
        } else {
            let key = P256.Signing.PrivateKey()
            made = LockSigningKey(publicKey: key.publicKey.x963Representation, holder: .software(key))
            representation = key.rawRepresentation
        }
        if try keychain.add(representation, account: account) { return made }
        // Made by another call at the same moment: that one is the key.
        return try load(account: account, accessGroup: accessGroup)
    }

    /// The key for `account` when one is kept there; nil, and nothing made, when none is.
    public static func existing(account: String, accessGroup: String? = nil) throws -> LockSigningKey? {
        guard try DeviceKey.Keychain(accessGroup: accessGroup).read(account: account) != nil else { return nil }
        return try load(account: account, accessGroup: accessGroup)
    }

    /// The lock's recovery key, opened from its entry with the person's secret (#3493).
    static func recovery(_ key: P256.Signing.PrivateKey) -> LockSigningKey {
        LockSigningKey(publicKey: key.publicKey.x963Representation, holder: .software(key))
    }

    /// A key that lives only for this process: for tests.
    public static func ephemeral() -> LockSigningKey {
        let key = P256.Signing.PrivateKey()
        return LockSigningKey(publicKey: key.publicKey.x963Representation, holder: .software(key))
    }

    private init(publicKey: Data, holder: Holder) {
        self.publicKey = publicKey
        self.holder = holder
    }

    /// ECDSA with SHA-256 over `data`, r then s.
    func sign(_ data: Data) throws -> Data {
        switch holder {
        case .enclave(let key): try key.signature(for: data).rawRepresentation
        case .software(let key): try key.signature(for: data).rawRepresentation
        }
    }
}
#endif

/// What the clients say about the machine lock (#3490), the same on the Mac and the Remote;
/// the web page's are in `Web/src/model/machineLock.ts`.
public enum LockWords {
    /// After the client's name: "Sam’s iPhone asks to join your devices."
    public static let asks = "asks to join your devices."
    public static let compareFirst = "Compare the digits on both screens before you approve it."
    public static let compare = "Compare Digits"
    public static let elsewhere = "Another of your devices is comparing the digits."
    public static func revealing(_ name: String) -> String { "Waiting for \(name) to show its digits…" }
    public static func approveOnly(_ name: String, _ digits: String) -> String {
        "Approve only if \(name) shows \(MachineLock.shown(digits))."
    }
    public static func mismatch(_ name: String) -> String { "\(name) did not show the digits it promised. Deny it." }

    /// A machine that asks (#3491, D3), on every client.
    public static func newMachine(_ name: String) -> String { "Approve the new machine \(name)?" }
    public static let compareMachine = "Compare the digits with the ones in its log before you approve it."
    public static func approveMachineOnly(_ name: String, _ digits: String) -> String {
        "Approve only if the log of \(name) shows \(MachineLock.shown(digits))."
    }

    /// This device, not in the lock yet.
    public static let thisDevice = "Approve this device on another of your devices."
    public static let openOther = "Open Agents on a device you use already and choose Compare Digits."
    public static func checkOther(_ digits: String) -> String {
        "Check that the other device shows \(MachineLock.shown(digits)), then approve it there."
    }
    public static let denied = "This device was not approved."
    public static let expired = "Nobody approved this device in time."
    public static let askAgain = "Ask Again"
    public static let forked = "The lock changed in a way your devices did not sign."
    public static func broken(_ why: String) -> String { "Your lock does not check: \(why)." }
    public static let unreachable = "The control plane can’t be reached, so nothing was answered."

    /// The recovery key (#3493, D4).
    public static let saveRecovery = "Save your recovery key."
    public static let recoveryShownOnce = "Keep it in your password manager. You see it only this once. If you lose every device, it adds a new one."
    public static let makeRecovery = "Make a recovery key."
    public static let recoveryWhy = "If you lose this device, the recovery key adds your next one. Without it, each machine must join again."
    public static let makeRecoveryButton = "Make Recovery Key"
    public static let savedIt = "I Saved It"
    public static let skip = "Skip"
    public static let useRecovery = "Use Recovery Key"
    public static let typeRecovery = "Type your recovery key."
    public static let use = "Use"
    public static let recoveryTypo = "That is not a recovery key. Check it for a typo."
    public static let recoveryNotThisLock = "That recovery key is not your lock’s."
    public static let noRecovery = "Your lock has no recovery key. Start a new lock instead."
    public static let recoveryFailed = "The recovery key could not be used. Try again."
    public static let startNewLock = "Start a New Lock"
    public static let newLockTitle = "Start a new lock?"
    public static let newLockMessage = "Do this only if you lost every device and your recovery key. Each machine refuses the new lock until you run agentsd lock reset in its shell, and approve it here."
}

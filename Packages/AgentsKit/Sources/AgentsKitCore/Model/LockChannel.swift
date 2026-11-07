#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// Requests checked end to end (#3492, `specs/3399-machine-lock` D6), as Go's
/// `machinelock/channel.go` makes them. A client sends a machine a new ECDH key signed with its
/// lock key (`lock/hello`); the machine answers with one of its own, signed with its machine
/// key, which the client's lock must name as an addMachine. HKDF-SHA256 makes a key for each
/// direction, and every request and answer then ends with `"lock":{"n":…,"mac":…}`:
/// HMAC-SHA256 over the count and the message without that member.
///
/// A prompt or a start for a machine that is not there goes signed instead
/// (`LockSignature`), so the control plane can keep it and the machine still takes it.
public enum LockChannel {
    static let channelDomain = Data("agents-lock-channel/1\n".utf8)
    static let requestDomain = "agents-lock-request/1\n"
    static let tailStart = #","lock":{"n":"#

    public enum Failure: Error, Sendable, Equatable {
        case notMember, forged, unsigned, badMAC, replayed
    }

    /// This device's lock key and its checked lock: what a channel is opened with.
    public struct Signer: Sendable {
        public let key: LockSigningKey
        public let state: MachineLock.State

        public init(key: LockSigningKey, state: MachineLock.State) {
            self.key = key
            self.state = state
        }
    }

    public static func clientHelloData(_ ephemeral: Data) -> Data { channelDomain + Data("client\n".utf8) + ephemeral }

    public static func machineHelloData(_ clientEphemeral: Data, _ machineEphemeral: Data, _ clientKey: Data) -> Data {
        channelDomain + Data("machine\n".utf8) + clientEphemeral + machineEphemeral + clientKey
    }

    /// ECDSA P-256 with SHA-256, r then s, by the key (X9.63).
    public static func verify(_ publicKey: Data, _ data: Data, _ sig: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sig) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// The two keys, from the ECDH secret and both ephemeral keys: what the client sends with, then the machine.
    public static func keys(_ shared: SharedSecret, clientEphemeral: Data, machineEphemeral: Data) -> (client: SymmetricKey, machine: SymmetricKey) {
        let salt = clientEphemeral + machineEphemeral
        let derive = { (info: String) in
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(info.utf8), outputByteCount: 32)
        }
        return (derive("agents-lock-channel/1 client"), derive("agents-lock-channel/1 machine"))
    }

    /// Whether a message ends with a MAC, whether or not it checks.
    public static func sealed(_ message: String) -> Bool { tail(of: message) != nil }

    /// Where the MAC member starts, its count and its MAC.
    static func tail(of message: String) -> (start: String.Index, n: UInt64, mac: String)? {
        guard message.hasSuffix("\"}}"), let start = message.range(of: tailStart, options: .backwards) else { return nil }
        let rest = message[start.upperBound...]
        guard let comma = rest.firstIndex(of: ","), let n = UInt64(rest[..<comma]), !rest[..<comma].isEmpty else { return nil }
        let after = rest[comma...]
        let macStart = #","mac":""#
        guard after.hasPrefix(macStart) else { return nil }
        let mac = after.dropFirst(macStart.count).dropLast(3)
        guard mac.count == 44, mac.hasSuffix("="), mac.dropLast().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }) else {
            return nil
        }
        return (start.lowerBound, n, String(mac))
    }

    static func mac(_ key: SymmetricKey, _ n: UInt64, _ body: String) -> Data {
        var count = n.bigEndian
        let prefix = withUnsafeBytes(of: &count) { Data($0) }
        return Data(HMAC<SHA256>.authenticationCode(for: prefix + Data(body.utf8), using: key))
    }

    /// One side of a checked channel.
    public final class Channel: @unchecked Sendable {
        private let send: SymmetricKey
        private let hear: SymmetricKey
        private let lock = NSLock()
        private var sent: UInt64
        private var heard: UInt64

        public init(send: SymmetricKey, hear: SymmetricKey, sent: UInt64 = 0, heard: UInt64 = 0) {
            self.send = send
            self.hear = hear
            self.sent = sent
            self.heard = heard
        }

        /// The message with the next count and its MAC as its last member.
        public func seal(_ message: String) -> String {
            lock.withLock { sealLocked(message) }
        }

        /// Seals a message and hands it to write while the next count waits, so the counts go out in order.
        public func sealThen(_ message: String, _ write: (String) throws -> Void) rethrows {
            try lock.withLock { try write(sealLocked(message)) }
        }

        private func sealLocked(_ message: String) -> String {
            sent += 1
            let mac = LockChannel.mac(send, sent, message).base64EncodedString()
            return "\(message.dropLast()),\"lock\":{\"n\":\(sent),\"mac\":\"\(mac)\"}}"
        }

        /// The message without its MAC member, once its MAC and count check.
        public func open(_ message: String) throws(Failure) -> String {
            guard let tail = LockChannel.tail(of: message) else { throw .unsigned }
            let body = String(message[..<tail.start]) + "}"
            guard LockChannel.mac(hear, tail.n, body).base64EncodedString() == tail.mac else { throw .badMAC }
            lock.lock()
            defer { lock.unlock() }
            guard tail.n > heard else { throw .replayed }
            heard = tail.n
            return body
        }
    }

    /// A client's `lock/hello`, and the ephemeral key it keeps for `finish`.
    public struct Hello: Sendable {
        public let params: DaemonAPI.LockHello
        let ephemeral: P256.KeyAgreement.PrivateKey
    }

    public static func hello(_ signer: LockSigningKey) throws -> Hello {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let raw = ephemeral.publicKey.x963Representation
        let sig = try signer.sign(clientHelloData(raw))
        return Hello(params: DaemonAPI.LockHello(key: signer.publicKey, ephemeral: raw, sig: sig), ephemeral: ephemeral)
    }

    /// Whether the lock names the machine `host` with an addMachine.
    public static func names(_ state: MachineLock.State, host: String) -> Bool {
        !host.isEmpty && state.members.values.contains { $0.kind == .addMachine && $0.id == host }
    }

    /// Checks a machine's answer against the client's lock and makes the client's side of the
    /// channel. `host` is the machine's id; "" is any machine (the window's `.mac`). A machine
    /// the lock names must answer with the key its addMachine names; one it does not name yet
    /// (it waits for approval) is taken on its word, as before the lock, and the requests to
    /// it are still this device's alone.
    public static func finish(_ hello: Hello, state: MachineLock.State, host: String, reply: DaemonAPI.LockHelloReply) throws(Failure) -> Channel {
        if let member = state.members[reply.key] {
            guard member.kind == .addMachine, host.isEmpty || member.id == nil || member.id == host else { throw .notMember }
        } else if names(state, host: host) {
            throw .notMember
        }
        guard verify(reply.key, machineHelloData(hello.params.ephemeral, reply.ephemeral, hello.params.key), reply.sig),
              let peer = try? P256.KeyAgreement.PublicKey(x963Representation: reply.ephemeral),
              let shared = try? hello.ephemeral.sharedSecretFromKeyAgreement(with: peer) else { throw .forged }
        let keys = keys(shared, clientEphemeral: hello.params.ephemeral, machineEphemeral: reply.ephemeral)
        return Channel(send: keys.client, hear: keys.machine)
    }

    public static func requestData(to: String, at: Int64, method: String, params: String) -> Data {
        Data("\(requestDomain)\(to)\n\(at)\n\(method)\n\(params)".utf8)
    }

    /// A request signed for the machine `to`, with its params as they are sent.
    public static func sign(_ signer: LockSigningKey, to: String, method: String, params: String, at: Date = Date()) throws -> DaemonAPI.LockSignature {
        let seconds = Int64(at.timeIntervalSince1970.rounded(.down))
        let sig = try signer.sign(requestData(to: to, at: seconds, method: method, params: params))
        return DaemonAPI.LockSignature(to: to, at: seconds, key: signer.publicKey, sig: sig)
    }

    /// The text JSON-RPC's encoder writes for a value: sorted keys, slashes as they are.
    public static func text(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// A kept request signed by this device, as `machines/keep` carries it.
    public static func delivery(_ signer: LockSigningKey, to host: String, method: String, params: JSONValue) throws -> DaemonAPI.LockDelivery {
        let text = try text(params)
        return DaemonAPI.LockDelivery(method: method, params: text, lock: try sign(signer, to: host, method: method, params: text))
    }
}
#endif

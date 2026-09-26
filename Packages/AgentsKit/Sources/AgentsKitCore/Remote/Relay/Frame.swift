// Not on Linux: the server build of agentsd has no CryptoKit and no relay (037).
#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// Which way a frame is going. Part of what a frame is sealed to, so one written by the
/// Mac cannot be passed off as the device's.
public enum FrameDirection: UInt8, Sendable, Hashable, Codable {
    case toMac = 0
    case toDevice = 1
}

/// One numbered batch of daemon lines, on its way through the person's iCloud (046).
///
/// A frame is what a relayed session is made of: the device's requests go to the Mac in
/// frames, and the Mac's replies and notifications come back in frames, each numbered
/// from nought in its own direction. The lines inside are exactly what would cross the
/// Unix socket — the relay carries JSON-RPC, it does not speak it.
///
/// Sealed with HPKE in authenticated mode (research R3): to the recipient's key, by the
/// sender's, with the session, the direction and the number bound in as associated data.
/// So iCloud sees only ciphertext, a frame opens only for the one it was sealed to and
/// only as having come from the one that sealed it, and a frame copied into another
/// session, turned round, or renumbered does not open at all.
public struct Frame: Sendable, Hashable {
    public var session: UUID
    public var direction: FrameDirection
    public var seq: Int64
    public var lines: [String]
    /// The sender is closing the session. Nothing follows it.
    public var end: Bool

    public init(session: UUID, direction: FrameDirection, seq: Int64, lines: [String] = [], end: Bool = false) {
        self.session = session
        self.direction = direction
        self.seq = seq
        self.lines = lines
        self.end = end
    }

    static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    static let info = Data("com.alexecollins.agents.relay.v1".utf8)
    /// A P256 encapsulated key, uncompressed: what the recipient needs first.
    static let encapsulatedLength = 65

    /// session (16 bytes) ‖ direction (1) ‖ seq (8, big-endian) — contracts/relay.md.
    static func associatedData(session: UUID, direction: FrameDirection, seq: Int64) -> Data {
        var data = Data(capacity: 25)
        withUnsafeBytes(of: session.uuid) { data.append(contentsOf: $0) }
        data.append(direction.rawValue)
        withUnsafeBytes(of: seq.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    private struct Body: Codable {
        var lines: [String]
        var end: Bool?
    }

    /// Seal this frame to `recipient`, as `sender`.
    public func seal(to recipient: Data, from sender: some RelayKey) throws -> Data {
        let body = try JSONEncoder().encode(Body(lines: lines, end: end ? true : nil))
        let plain = try (body as NSData).compressed(using: .zlib) as Data
        return try sender.seal(plain, to: recipient,
                               associatedData: Self.associatedData(session: session, direction: direction, seq: seq))
    }

    /// Open a frame sealed to `recipient` by the holder of `sender`. The session, direction
    /// and number are the record's own; a frame that was sealed under any others fails.
    public static func open(_ sealed: Data, with recipient: some RelayKey, from sender: Data,
                            session: UUID, direction: FrameDirection, seq: Int64) throws -> Frame {
        let plain = try recipient.open(sealed, from: sender,
                                       associatedData: associatedData(session: session, direction: direction, seq: seq))
        let body = try (plain as NSData).decompressed(using: .zlib) as Data
        let decoded = try JSONDecoder().decode(Body.self, from: body)
        return Frame(session: session, direction: direction, seq: seq,
                     lines: decoded.lines, end: decoded.end ?? false)
    }
}

/// A key that can seal a frame as itself and open one sealed to it: the device's own
/// key, and the Mac's. Both are P256; which holds the private half — the Secure Enclave
/// or the keychain — is the key's business, not the frame's.
public protocol RelayKey: Sendable {
    /// X9.63, 65 bytes: what the other side is given.
    var publicKey: Data { get }
    func seal(_ plain: Data, to recipient: Data, associatedData: Data) throws -> Data
    func open(_ sealed: Data, from sender: Data, associatedData: Data) throws -> Data
}

public enum RelaySealing {
    public struct Unopenable: Error, Sendable {}

    static func seal<Key: HPKEDiffieHellmanPrivateKey>(_ plain: Data, to recipient: Data, associatedData: Data,
                                                       as sender: Key) throws -> Data
        where Key.PublicKey == P256.KeyAgreement.PublicKey {
        let recipientKey = try P256.KeyAgreement.PublicKey(x963Representation: recipient)
        var hpke = try HPKE.Sender(recipientKey: recipientKey, ciphersuite: Frame.suite,
                                   info: Frame.info, authenticatedBy: sender)
        let ciphertext = try hpke.seal(plain, authenticating: associatedData)
        return hpke.encapsulatedKey + ciphertext
    }

    static func open<Key: HPKEDiffieHellmanPrivateKey>(_ sealed: Data, from sender: Data, associatedData: Data,
                                                       as recipient: Key) throws -> Data
        where Key.PublicKey == P256.KeyAgreement.PublicKey {
        guard sealed.count > Frame.encapsulatedLength else { throw Unopenable() }
        let encapsulated = sealed.prefix(Frame.encapsulatedLength)
        let ciphertext = sealed.dropFirst(Frame.encapsulatedLength)
        let senderKey = try P256.KeyAgreement.PublicKey(x963Representation: sender)
        var hpke = try HPKE.Recipient(privateKey: recipient, ciphersuite: Frame.suite, info: Frame.info,
                                      encapsulatedKey: Data(encapsulated), authenticatedBy: senderKey)
        return try hpke.open(Data(ciphertext), authenticating: associatedData)
    }
}
#endif

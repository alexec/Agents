#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// Something sealed to one device, and to nobody else.
///
/// HPKE to the device's P256 public key, with the banner's `Headline` inside. Nothing
/// legible goes to a device that is not `to` (FR-022): the project's name, the agent's
/// name and what is wanted travel only as ciphertext, and a withdrawal carries no
/// envelope at all — it names the need's id, which identifies nothing about the work.
///
/// The headline is truncated to its budget **before** it is sealed, so a banner is
/// never cut mid-ciphertext; one that will not fit degrades to the placeholder first.
public struct Envelope: Hashable, Sendable, Codable {
    /// The encapsulated key: what the recipient needs, with its own private key, to
    /// derive the one this was sealed with.
    public var encapsulated: Data
    public var ciphertext: Data

    public init(encapsulated: Data, ciphertext: Data) {
        self.encapsulated = encapsulated
        self.ciphertext = ciphertext
    }

    #if canImport(CryptoKit)
    static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    static let purpose = Data("com.alexecollins.agents.headline.v1".utf8)

    /// Seal a headline to a device.
    public static func seal(_ headline: Headline, to publicKey: Data) throws -> Envelope {
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: purpose)
        let plaintext = try JSONEncoder().encode(headline.truncating())
        let ciphertext = try sender.seal(plaintext)
        return Envelope(encapsulated: sender.encapsulatedKey, ciphertext: ciphertext)
    }

    /// Open one on the device it was sealed to.
    public static func open(_ envelope: Envelope, with key: DeviceKey) throws -> Headline {
        let plaintext = try key.open(envelope)
        return try JSONDecoder().decode(Headline.self, from: plaintext)
    }

    static func open<Key: HPKEDiffieHellmanPrivateKey>(_ envelope: Envelope, with key: Key) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: purpose,
                                           encapsulatedKey: envelope.encapsulated)
        return try recipient.open(envelope.ciphertext)
    }
    #else
    public struct Unavailable: Error {}

    /// A Linux server has no paired devices (037), so nothing is ever sealed there.
    /// Asked anyway, it says so rather than sending a banner in the clear.
    public static func seal(_ headline: Headline, to publicKey: Data) throws -> Envelope {
        throw Unavailable()
    }
    #endif
}

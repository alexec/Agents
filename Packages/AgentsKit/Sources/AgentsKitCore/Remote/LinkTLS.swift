// Not on Linux: the server build of agentsd has no Network and no CryptoKit (037).
#if canImport(Network) && canImport(CryptoKit)
import CryptoKit
import Foundation
import Network
import Security

/// The keys the direct link is locked with (security review, Phase 3).
///
/// Two kinds, told apart by their identity's first letter. `d:` is a paired device: the
/// key is what its key and the Mac's share (`DeviceKey.linkKey`). `p:` is somebody
/// pairing: the key comes from the secret in the QR code the Mac is showing, and the
/// identity names that code without giving it away.
public enum LinkKey {
    static func derive(_ shared: SharedSecret, device: UUID) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("agents-lan-v1".utf8),
                                       sharedInfo: Data(device.uuidString.utf8), outputByteCount: 32)
    }

    public static func deviceIdentity(_ device: UUID) -> String { "d:" + device.uuidString }

    /// The device a `d:` identity names, or `nil` for anything else.
    public static func device(fromIdentity identity: String) -> UUID? {
        guard identity.hasPrefix("d:") else { return nil }
        return UUID(uuidString: String(identity.dropFirst(2)))
    }

    /// The key a pairing code opens.
    public static func pairing(_ secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data("agents-pair-v1".utf8),
                               info: Data(), outputByteCount: 32)
    }

    /// Which code: a hash's first eight bytes, so the identity sent in the clear says
    /// nothing a listener could use.
    public static func pairingIdentity(_ secret: Data) -> String {
        "p:" + SHA256.hash(data: secret).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func isPairing(_ identity: String) -> Bool { identity.hasPrefix("p:") }
}

/// TLS for the direct link: a pre-shared key and nothing else, no certificates.
///
/// TLS 1.2, because TLS 1.3's external keys fail in Network framework whatever they are
/// given, and the one suite that brings forward secrecy with a pre-shared key —
/// ECDHE-PSK with ChaCha20-Poly1305. Asked for alone it is what is agreed; others that
/// were asked for quietly became plain PSK, so the bridge checks what was agreed rather
/// than trusting what it asked for (S0, phase-3-plan.md).
public enum LinkTLS {
    /// `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`.
    public static let suite: UInt16 = 0xCCAC

    private static func options() -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: suite)!)
        // Every connection proves its key afresh. A resumed session skips choosing a key,
        // so the bridge would not learn which device it is and would close it: a phone
        // coming straight back would be shut out until the cache forgot it.
        sec_protocol_options_set_tls_resumption_enabled(sec, false)
        sec_protocol_options_set_tls_tickets_enabled(sec, false)
        return tls
    }

    private static func dispatch(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }

    private static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    /// The phone's side: one identity, one key.
    public static func client(identity: String, key: SymmetricKey) -> NWParameters {
        let tls = options()
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, dispatch(bytes(key)),
                                                dispatch(Data(identity.utf8)))
        return NWParameters(tls: tls)
    }

    /// The bridge's side: every key it will take, and a word each time a handshake picks
    /// one, so the connection can be told which device it is. Network framework chooses
    /// among keys added here and nowhere else, so a new device means new parameters.
    public static func server(keys: [String: SymmetricKey], chosen: ChosenIdentities) -> NWParameters {
        let tls = options()
        let sec = tls.securityProtocolOptions
        for (identity, key) in keys {
            sec_protocol_options_add_pre_shared_key(sec, dispatch(bytes(key)), dispatch(Data(identity.utf8)))
        }
        let known = Set(keys.keys)
        sec_protocol_options_set_pre_shared_key_selection_block(sec, { metadata, offered, complete in
            let identity = offered.map { String(decoding: Data($0 as DispatchData), as: UTF8.self) }
            guard let identity, known.contains(identity) else { complete(nil); return }
            chosen.record(identity, for: metadata)
            complete(offered)
        }, DispatchQueue(label: "com.alexecollins.agents.bridge.psk"))
        return NWParameters(tls: tls)
    }

    static func metadata(of connection: NWConnection) -> sec_protocol_metadata_t? {
        (connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)?
            .securityProtocolMetadata
    }

    /// Whether a ready connection agreed the one suite, not a weaker one beside it.
    public static func agreedTheSuite(_ connection: NWConnection) -> Bool {
        guard let metadata = metadata(of: connection) else { return false }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata).rawValue == suite
    }
}

/// Which identity each handshake chose, until its connection is ready and asks.
///
/// The selection block is told about a handshake, not a connection, and the only thing
/// the two share is the metadata object itself: the one the block is handed is the one
/// the ready connection carries. `peers_are_equal` is no use for this — it called two
/// different devices' handshakes equal. Each entry holds its metadata, so an address is
/// never reused while it waits; entries a connection never came for go after a minute.
public final class ChosenIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(metadata: sec_protocol_metadata_t, identity: String, at: Date)] = []

    public init() {}

    func record(_ identity: String, for metadata: sec_protocol_metadata_t) {
        lock.withLock {
            let now = Date()
            entries.removeAll { now.timeIntervalSince($0.at) > 60 }
            entries.append((metadata, identity, now))
        }
    }

    /// The identity `connection`'s handshake chose, once.
    public func take(for connection: NWConnection) -> String? {
        guard let metadata = LinkTLS.metadata(of: connection) else { return nil }
        return lock.withLock {
            guard let index = entries.firstIndex(where: { $0.metadata === metadata }) else { return nil }
            return entries.remove(at: index).identity
        }
    }
}
#endif

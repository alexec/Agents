// Not on Linux: the server build of agentsd has no CryptoKit and no use for this (037).
#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Security

/// A device's own key: P256, made once on the device and kept in the device's keychain.
///
/// The private half never leaves the device — which is the device's, not ours, and is
/// why this does not break the rule about storing nothing outside the daemon's root. The
/// Mac sees only the public half, announced once, and everything sealed to this device
/// is sealed to it. Secure-Enclave-backed where the hardware has one; a software key
/// where it does not, so a simulator and a test can hold one too.
public struct DeviceKey: Sendable {
    /// The public half, as the Mac keeps it: the X9.63 representation, 65 bytes.
    public let publicKey: Data
    private let holder: Holder

    private enum Holder: @unchecked Sendable {
        case enclave(SecureEnclave.P256.KeyAgreement.PrivateKey)
        case software(P256.KeyAgreement.PrivateKey)
    }

    /// The keychain access group the Remote and its notification service extension
    /// share, so the extension can open what was sealed to the app's key. The team
    /// prefix is the one in `project.yml`; an access group is spelt with it.
    public static let sharedAccessGroup = "6T4RVD5724.com.alexecollins.agents.shared"

    /// The device's key, made on first use and found in the keychain after that.
    /// `accessGroup` is the shared group on a device and `nil` on a Mac or in a test,
    /// where there is no entitlement to name one.
    ///
    /// `enclave: false` keeps the key in the keychain as a software key even where there is
    /// a Secure Enclave: the Mac's relay key (046) belongs to a helper with no window, which
    /// must not lose its key to a locked screen.
    public static func load(account: String = "device-key", accessGroup: String? = nil,
                            enclave: Bool = true) throws -> DeviceKey {
        let keychain = Keychain(accessGroup: accessGroup)
        if let stored = try keychain.read(account: account) {
            if enclave, SecureEnclave.isAvailable,
               let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: stored) {
                return DeviceKey(publicKey: key.publicKey.x963Representation,
                                 holder: .enclave(key))
            }
            if let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: stored) {
                return DeviceKey(publicKey: key.publicKey.x963Representation,
                                 holder: .software(key))
            }
        }
        let made = enclave ? try make() : ephemeral()
        try keychain.write(made.representation, account: account)
        return made
    }

    /// A key that lives only for this process: for tests, and for a Mac that is only
    /// ever the sender.
    public static func ephemeral() -> DeviceKey {
        let key = P256.KeyAgreement.PrivateKey()
        return DeviceKey(publicKey: key.publicKey.x963Representation,
                         holder: .software(key))
    }

    private static func make() throws -> DeviceKey {
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey() {
            return DeviceKey(publicKey: key.publicKey.x963Representation,
                             holder: .enclave(key))
        }
        return ephemeral()
    }

    private init(publicKey: Data, holder: Holder) {
        self.publicKey = publicKey
        self.holder = holder
    }

    private var representation: Data {
        switch holder {
        case .enclave(let key): return key.dataRepresentation
        case .software(let key): return key.rawRepresentation
        }
    }

    /// Open something sealed to this device.
    func open(_ envelope: Envelope) throws -> Data {
        switch holder {
        case .enclave(let key): return try Envelope.open(envelope, with: key)
        case .software(let key): return try Envelope.open(envelope, with: key)
        }
    }

    /// Keep a public key someone else gave this device, beside its own: the Mac's relay
    /// key, learnt at pairing (046). `nil` forgets it.
    public static func keepPublicKey(_ key: Data?, account: String, accessGroup: String? = nil) throws {
        let keychain = Keychain(accessGroup: accessGroup)
        if let key { try keychain.write(key, account: account) } else { keychain.delete(account: account) }
    }

    public static func publicKey(account: String, accessGroup: String? = nil) -> Data? {
        try? Keychain(accessGroup: accessGroup).read(account: account)
    }

    /// The device's keychain, and nothing else: one generic-password item per account.
    struct Keychain {
        var accessGroup: String?

        private func base(_ account: String) -> [String: Any] {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: "com.alexecollins.agents.device",
                                        kSecAttrAccount as String: account]
            if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
            return query
        }

        func read(account: String) throws -> Data? {
            var query = base(account)
            query[kSecReturnData as String] = true
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw Failure.keychain(status) }
            return item as? Data
        }

        func delete(account: String) {
            SecItemDelete(base(account) as CFDictionary)
        }

        func write(_ data: Data, account: String) throws {
            let query = base(account)
            SecItemDelete(query as CFDictionary)
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        }
    }

    public enum Failure: Error, Sendable {
        case keychain(OSStatus)
    }
}

/// The device's key seals and opens relayed frames as itself (046), with whichever half
/// it holds: the enclave's or the keychain's.
extension DeviceKey: RelayKey {
    public func seal(_ plain: Data, to recipient: Data, associatedData: Data) throws -> Data {
        switch holder {
        case .enclave(let key): try RelaySealing.seal(plain, to: recipient, associatedData: associatedData, as: key)
        case .software(let key): try RelaySealing.seal(plain, to: recipient, associatedData: associatedData, as: key)
        }
    }

    public func open(_ sealed: Data, from sender: Data, associatedData: Data) throws -> Data {
        switch holder {
        case .enclave(let key): try RelaySealing.open(sealed, from: sender, associatedData: associatedData, as: key)
        case .software(let key): try RelaySealing.open(sealed, from: sender, associatedData: associatedData, as: key)
        }
    }
}
#endif

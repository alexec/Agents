import AgentsKitCore
import Foundation
import Security

/// What Agents Host keeps secret (058, T056 and T058a): the control plane's private key,
/// made once, and the bucket's keys when the store is in one. In the keychain, handed to
/// `agents-control` only through inherited descriptors, and never written to disk.
///
/// A scratch set-up keeps them in 0600 files in its own root instead, so a walk never
/// adds to the person's keychain.
enum HostSecrets {
    struct BucketKeys: Codable, Sendable, Equatable {
        var accessKey: String
        var secretKey: String
    }

    private static let service = "com.alexecollins.agentshost"

    static func controlKey(_ paths: HostPaths) throws -> Data {
        if paths.scratch {
            try FileManager.default.createDirectory(at: paths.controlHome, withIntermediateDirectories: true)
            return try ControlAgreement.loadOrMake(file: paths.controlHome.appendingPathComponent("control-key"))
        }
        if let kept = read(account: "control-key") { return kept }
        // A key restored from a backup (`agents-control restore`, #2137) goes into the
        // keychain, and its file is deleted: a new Mac keeps the old control plane's key.
        let restored = paths.controlHome.appendingPathComponent("control-key")
        if let key = try? Data(contentsOf: restored), key.count == 32,
           (try? ControlAgreement.publicKey(privateKey: key)) != nil {
            try write(key, account: "control-key")
            try? FileManager.default.removeItem(at: restored)
            return key
        }
        let made = ControlAgreement.generate().privateKey
        try write(made, account: "control-key")
        return made
    }

    /// The control plane's key, written to `file` for the person to copy to another machine:
    /// whole and synced, or not at all, and thrown when the disk refuses it (#212).
    static func saveControlKey(_ paths: HostPaths, to file: URL) throws {
        try StoreCoding.writeAtomically(try controlKey(paths), to: file, permissions: 0o600)
    }

    /// The key in `file`, from `agents-control key export` on the machine the control plane
    /// was moved to, made this Mac's for a move back (T127, #1477). This Mac's own key is kept
    /// aside as `control-key-before-<time>`, not deleted. Throws, and changes nothing, when
    /// `file` holds no key.
    static func useControlKey(_ paths: HostPaths, from file: URL) throws {
        let key = try Data(contentsOf: file)
        guard key.count == 32, (try? ControlAgreement.publicKey(privateKey: key)) != nil else {
            throw ControlService.Failure("\(file.lastPathComponent) holds no control plane key.")
        }
        let mine = try controlKey(paths)
        guard mine != key else { return }
        let aside = "control-key-before-\(Int(Date().timeIntervalSince1970))"
        if paths.scratch {
            let here = paths.controlHome.appendingPathComponent("control-key")
            try StoreCoding.writeAtomically(mine, to: paths.controlHome.appendingPathComponent(aside), permissions: 0o600)
            try StoreCoding.writeAtomically(key, to: here, permissions: 0o600)
        } else {
            try write(mine, account: aside)
            try write(key, account: "control-key")
        }
    }

    static func bucketKeys(_ paths: HostPaths) -> BucketKeys? {
        let data = paths.scratch ? try? Data(contentsOf: bucketFile(paths)) : read(account: "bucket-keys")
        return data.flatMap { try? JSONDecoder().decode(BucketKeys.self, from: $0) }
    }

    static func saveBucketKeys(_ keys: BucketKeys, _ paths: HostPaths) throws {
        let data = try JSONEncoder().encode(keys)
        if paths.scratch {
            try StoreCoding.writeAtomically(data, to: bucketFile(paths), permissions: 0o600)
        } else {
            try write(data, account: "bucket-keys")
        }
    }

    private static func bucketFile(_ paths: HostPaths) -> URL { paths.controlHome.appendingPathComponent("bucket-keys.json") }

    // MARK: The keychain

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "the keychain refused (\(status))" }
    }

    private static func read(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, account: String) throws {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let updated = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure(status: updated) }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Agents Host"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
}

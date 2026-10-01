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
        let made = ControlAgreement.generate().privateKey
        try write(made, account: "control-key")
        return made
    }

    static func bucketKeys(_ paths: HostPaths) -> BucketKeys? {
        let data = paths.scratch ? try? Data(contentsOf: bucketFile(paths)) : read(account: "bucket-keys")
        return data.flatMap { try? JSONDecoder().decode(BucketKeys.self, from: $0) }
    }

    static func saveBucketKeys(_ keys: BucketKeys, _ paths: HostPaths) throws {
        let data = try JSONEncoder().encode(keys)
        if paths.scratch {
            try FileManager.default.createDirectory(at: paths.controlHome, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: bucketFile(paths).path, contents: data, attributes: [.posixPermissions: 0o600])
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

#if canImport(Security)
import AgentsKitCore
import CryptoKit
import Foundation
import Security

/// The credentials the window lends to servers (043, D1): each runtime's secret in this
/// Mac's login Keychain, and only what is safe to show beside it in `credentials.json`.
///
/// The window's alone. Neither daemon reads it — the Mac's never uses a credential from
/// here (D5), and a server's is lent one for a single connection when it asks.
///
/// Scoped by the app's root: a scratch copy on another root keeps its own, and never sees
/// the real one.
public struct CredentialStore: Sendable {
    /// What Settings shows. Never the secret.
    public struct Record: Codable, Hashable, Sendable {
        public var kind: CredentialKind
        public var lastFour: String
        public var addedAt: Date
        public var lastWorked: Date?
        public var lastRefused: Date?

        public var mask: String { Secret.mask(kind: kind, lastFour: lastFour) }
    }

    public struct Failure: Error, Equatable, Sendable {
        public var status: Int32
    }

    public let file: URL
    public let service: String

    public init(file: URL, service: String) {
        self.file = file
        self.service = service
    }

    public init(locations: StoreLocations) {
        let path = locations.root.standardizedFileURL.path(percentEncoded: false)
        let id = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        self.init(file: locations.root.appendingPathComponent("credentials.json"),
                  service: "agents.runtime-credential.\(id)")
    }

    // MARK: Records

    public func records() -> [String: Record] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Record].self, from: data)) ?? [:]
    }

    public func record(for runtimeID: String) -> Record? { records()[runtimeID] }

    // MARK: Secrets

    /// Keep a secret for a runtime, replacing any before it.
    public func save(_ secret: Secret, for runtimeID: String, at date: Date = Date()) throws {
        try deleteSecret(for: runtimeID)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: runtimeID,
            kSecAttrLabel as String: "Agents: \(runtimeID) credential for servers",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(secret.reveal().utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
        try update(runtimeID) { _ in
            Record(kind: secret.kind, lastFour: secret.lastFour, addedAt: date)
        }
    }

    public func secret(for runtimeID: String) -> Secret? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: runtimeID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return Secret(String(decoding: data, as: UTF8.self))
    }

    /// Take a runtime's credential away entirely: the secret and its record.
    public func remove(_ runtimeID: String) throws {
        try deleteSecret(for: runtimeID)
        try update(runtimeID) { _ in nil }
    }

    public func markWorked(_ runtimeID: String, at date: Date = Date()) throws {
        try update(runtimeID) { record in
            guard var record else { return nil }
            record.lastWorked = date
            return record
        }
    }

    public func markRefused(_ runtimeID: String, at date: Date = Date()) throws {
        try update(runtimeID) { record in
            guard var record else { return nil }
            record.lastRefused = date
            return record
        }
    }

    // MARK: -

    private func deleteSecret(for runtimeID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: runtimeID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    private func update(_ runtimeID: String, _ change: (Record?) -> Record?) throws {
        var all = records()
        all[runtimeID] = change(all[runtimeID])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: file, options: .atomic)
    }
}
#endif

#if canImport(Security)
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

    /// `fileRoot` is where `credentials.json` is kept. It stays the root unless the
    /// window has moved the file out of a host's root (058, R11). The keychain service
    /// stays derived from `locations.root` either way, so a move does not orphan the secrets.
    public init(locations: StoreLocations, fileRoot: URL? = nil) {
        let path = locations.root.standardizedFileURL.path(percentEncoded: false)
        let id = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let folder = fileRoot ?? locations.root
        self.init(file: folder.appendingPathComponent("credentials.json"),
                  service: "agents.runtime-credential.\(id)")
    }

    /// `credentials.json` is there and could not be read, so nothing is written over it
    /// (#205): writing then would keep only the one runtime being saved.
    public struct Unreadable: Error, Equatable, Sendable, CustomStringConvertible {
        public var path: String
        public var description: String {
            "\((path as NSString).lastPathComponent) could not be read, so nothing was written over it"
        }
    }

    /// Kinds an earlier build kept and this one retired (056's Claude token, 047's OpenAI
    /// key). Only these are forgotten: a kind this build does not know may be a newer
    /// build's, and swapping builds must not delete it (#205).
    static let retiredKinds: Set<String> = ["oauthToken", "openAIAPIKey"]

    // MARK: Records

    private enum Contents {
        case missing
        case read([String: Any])
        case unreadable
    }

    /// The file as JSON objects, one per runtime, each still undecoded so that one this
    /// build does not know is carried through a write untouched. A read error is tried
    /// once more before it counts.
    private func contents() -> Contents {
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        for _ in 0..<2 {
            if let data = try? Data(contentsOf: file) {
                guard let entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .unreadable
                }
                return .read(entries)
            }
        }
        return .unreadable
    }

    private static func decode(_ entry: Any) -> Record? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? JSONSerialization.data(withJSONObject: entry)).flatMap { try? decoder.decode(Record.self, from: $0) }
    }

    /// True when the file is there and could not be read; Settings then says so rather
    /// than showing no credentials.
    public var isUnreadable: Bool {
        if case .unreadable = contents() { return true }
        return false
    }

    public func records() -> [String: Record] {
        // One at a time, so a kind this version no longer takes (047's OpenAI key) drops
        // only itself, not every other runtime's record with it.
        guard case .read(let entries) = contents() else { return [:] }
        return entries.compactMapValues(Self.decode)
    }

    public func record(for runtimeID: String) -> Record? { records()[runtimeID] }

    /// A record of a kind this version no longer takes (056: Claude's token; 047: Codex's
    /// OpenAI key) is forgotten, and its secret deleted from the Keychain: nothing will lend
    /// it again, so nothing should keep it. A record this build cannot read for any other
    /// reason, a newer build's kind among them, is left with its secret (#205), and so is
    /// every other runtime's. Returns the runtimes forgotten. Kept past the #58 cut-off
    /// (051) for 056's Claude token.
    @discardableResult
    public func forgetKindsNoLongerTaken() -> [String] {
        guard case .read(var entries) = contents() else { return [] }
        let dropped = entries.filter { _, entry in
            guard Self.decode(entry) == nil, let kind = (entry as? [String: Any])?["kind"] as? String else { return false }
            return Self.retiredKinds.contains(kind)
        }.keys.sorted()
        guard !dropped.isEmpty else { return [] }
        for runtimeID in dropped { entries[runtimeID] = nil }
        guard (try? write(entries)) != nil else { return [] }
        for runtimeID in dropped { try? deleteSecret(for: runtimeID) }
        return dropped
    }

    // MARK: Secrets

    /// Keep a secret for a runtime, replacing any before it.
    public func save(_ secret: Secret, for runtimeID: String, at date: Date = Date()) throws {
        try requireReadable()
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
        try requireReadable()
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

    private func requireReadable() throws {
        if case .unreadable = contents() { throw Unreadable(path: file.path) }
    }

    /// Change one runtime's record. Every other entry is written back as it was read, so
    /// a kind this build does not know survives; an unreadable file is never written over.
    private func update(_ runtimeID: String, _ change: (Record?) -> Record?) throws {
        var entries: [String: Any]
        switch contents() {
        case .missing: entries = [:]
        case .read(let read): entries = read
        case .unreadable: throw Unreadable(path: file.path)
        }
        let before = entries[runtimeID].flatMap(Self.decode)
        if let record = change(before) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            entries[runtimeID] = try JSONSerialization.jsonObject(with: encoder.encode(record))
        } else if before != nil {
            entries[runtimeID] = nil
        }
        try write(entries)
    }

    private func write(_ entries: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        try StoreCoding.writeAtomically(data, to: file)
    }
}
#endif

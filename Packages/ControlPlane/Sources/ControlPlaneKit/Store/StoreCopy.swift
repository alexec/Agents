import AgentsKitCore
import Foundation

/// Moving what the control plane remembers from one store to another (058, contracts/
/// store.md "Copying a store"): *Switch Store…* in Agents Host, and `agents-control store
/// copy`. Run with no copy serving. Nothing in the store says where it lives, so the
/// records need no change: the copy is started again pointing at the new one.
public enum StoreCopy {
    public struct Report: Sendable, Equatable {
        public var copied: Int
        public var skipped: Int
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// The destination is already some control plane's store.
        case destinationInUse
        /// Afterwards, the destination did not hold what was copied.
        case mismatch(String)

        public var description: String {
            switch self {
            case .destinationInUse:
                "The new store already holds a control plane's records, so nothing was copied into it."
            case .mismatch(let what):
                "The copy did not come out the same (\(what)). The old store is untouched; the new one should be emptied before trying again."
            }
        }
    }

    /// Rebuilt when a copy starts, so never carried across.
    static let skipped = ["v1/leases/", "v1/copies/"]

    public static func copy(from source: any ControlStore, to destination: any ControlStore) async throws -> Report {
        if try await destination.get(ControlRecords.settingsKey) != nil { throw Failure.destinationInUse }
        let keys = try await source.list(prefix: "v1/")
        var copied: [String: Data] = [:]
        var leftOut = 0
        for entry in keys {
            if isSkipped(entry.key) { leftOut += 1; continue }
            guard let object = try await source.get(entry.key) else { continue }
            // Create only: a destination written to meanwhile is a conflict, not overwritten.
            _ = try await destination.put(entry.key, object.data, when: .absent)
            copied[entry.key] = object.data
        }
        // Afterwards: the count, and each object's SHA-256.
        let landed = try await destination.list(prefix: "v1/").filter { !isSkipped($0.key) }
        guard landed.count == copied.count else {
            throw Failure.mismatch("\(copied.count) records copied, \(landed.count) found")
        }
        for (key, data) in copied {
            guard let back = try await destination.get(key),
                  ControlAgreement.sha256(back.data) == ControlAgreement.sha256(data) else {
                throw Failure.mismatch(key)
            }
        }
        return Report(copied: copied.count, skipped: leftOut)
    }

    static func isSkipped(_ key: String) -> Bool { skipped.contains { key.hasPrefix($0) } }
}

/// A store named by its URL (contracts/store.md "Configuration"): `file:///path` or
/// `s3://bucket/prefix`, the bucket's keys handed over separately.
public enum StoreAddress {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case notAStore(String)
        case noCredentials

        public var description: String {
            switch self {
            case .notAStore(let text): "\(text) is not a store: say file:///path or s3://bucket/prefix"
            case .noCredentials: "no keys for the bucket: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, ~/.aws/credentials, or --store-credentials-fd"
            }
        }
    }

    public static func open(_ text: String, environment: [String: String],
                            credentials given: S3Store.Credentials? = nil) throws -> any ControlStore {
        guard let url = URL(string: text), let scheme = url.scheme else { throw Failure.notAStore(text) }
        switch scheme {
        case "file":
            return FolderStore(root: URL(fileURLWithPath: url.path, isDirectory: true))
        case "s3":
            guard let location = S3Store.Location(url: url, environment: environment) else { throw Failure.notAStore(text) }
            guard let credentials = given ?? S3Store.credentials(environment: environment) else { throw Failure.noCredentials }
            return S3Store(location, credentials: credentials)
        default:
            throw Failure.notAStore(text)
        }
    }
}

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Where the control plane remembers things (058, research R4, contracts/store.md): one
/// object per record under `<prefix>/v1/`, in a folder or an S3-compatible bucket.
///
/// Every write that matters is conditional, so several copies of the control plane can
/// share one store: a write either applies to the version it read, or is refused with
/// `.conflict` and changes nothing. There is no conditional delete (S4: MinIO ignores
/// `If-Match` on DELETE), so forgetting a record writes a tombstone instead.
public protocol ControlStore: Sendable {
    /// The object and its entity tag, or nil when there is none.
    func get(_ key: String) async throws -> StoredObject?
    /// Writes `data` if `when` holds, and returns the new entity tag.
    func put(_ key: String, _ data: Data, when: StoreCondition) async throws -> String
    /// Deletes unconditionally. Only for what a race cannot hurt: spent and expired codes,
    /// old events, old tombstones, a probe.
    func delete(_ key: String) async throws
    /// Every key under `prefix`, with its entity tag.
    func list(prefix: String) async throws -> [StoredKey]
}

public struct StoredObject: Sendable, Equatable {
    public var data: Data
    public var etag: String
    public init(data: Data, etag: String) {
        self.data = data
        self.etag = etag
    }
}

public struct StoredKey: Sendable, Equatable {
    public var key: String
    public var etag: String
    public init(key: String, etag: String) {
        self.key = key
        self.etag = etag
    }
}

public enum StoreCondition: Sendable, Equatable {
    /// Create only: `If-None-Match: *`.
    case absent
    /// Update only the version read: `If-Match: <etag>`, sent exactly as it was given.
    case matching(String)
    /// No condition. Only for a copy's own heartbeat, which nobody else writes.
    case always
}

public enum StoreError: Error, Sendable, Equatable {
    /// The condition did not hold: another writer got there first (412, 409, or 404 on an
    /// `If-Match`), or the key already exists (`absent`). Nothing was written.
    case conflict(key: String)
    /// The store could not be reached or answered something we do not understand.
    case unavailable(String)

    /// What a client is told (contracts/control-api.md).
    public var rpcError: JSONRPCError {
        switch self {
        case .conflict:
            JSONRPCError(code: DaemonAPI.Failure.changedElsewhere,
                         message: "Someone changed that at the same time, so nothing was changed. Try again.")
        case .unavailable(let why):
            JSONRPCError(code: DaemonAPI.Failure.storeUnavailable,
                         message: "The control plane can't reach where it keeps its records (\(why)). Nothing was changed.")
        }
    }
}

public extension ControlStore {
    /// The start-up probe (contracts/store.md rule 4): a store that ignores conditions would
    /// let two copies each believe they won, so a copy refuses to start on one.
    func probe(copy: String) async throws {
        let key = "probe/\(copy)-\(UUID().uuidString)"
        let first = try await put(key, Data("probe".utf8), when: .absent)
        defer { Task { try? await delete(key) } }
        do {
            _ = try await put(key, Data("again".utf8), when: .absent)
            throw StoreError.unavailable("the store let a second create of \(key) through, so it ignores If-None-Match")
        } catch StoreError.conflict {}
        _ = try await put(key, Data("moved".utf8), when: .matching(first))
        do {
            _ = try await put(key, Data("stale".utf8), when: .matching(first))
            throw StoreError.unavailable("the store let a write with a stale entity tag through, so it ignores If-Match")
        } catch StoreError.conflict {}
    }
}

// MARK: - In memory

/// A store in memory: for tests, and for copies in one process in the copies tests.
public actor MemoryStore: ControlStore {
    private var objects: [String: StoredObject] = [:]
    /// Set in a test to make every call fail as a store that cannot be reached.
    public var down = false

    public init() {}

    public func setDown(_ down: Bool) { self.down = down }

    public func get(_ key: String) async throws -> StoredObject? {
        try reachable()
        return objects[key]
    }

    public func put(_ key: String, _ data: Data, when: StoreCondition) async throws -> String {
        try reachable()
        switch when {
        case .absent where objects[key] != nil: throw StoreError.conflict(key: key)
        case .matching(let etag) where objects[key]?.etag != etag: throw StoreError.conflict(key: key)
        default: break
        }
        // Same bytes, same tag, as S3 and MinIO do (S4): a test of A→B→A needs it.
        let etag = "\"\(ControlAgreement.sha256(data).hexString)\""
        objects[key] = StoredObject(data: data, etag: etag)
        return etag
    }

    public func delete(_ key: String) async throws {
        try reachable()
        objects[key] = nil
    }

    public func list(prefix: String) async throws -> [StoredKey] {
        try reachable()
        return objects.filter { $0.key.hasPrefix(prefix) }
            .map { StoredKey(key: $0.key, etag: $0.value.etag) }
            .sorted { $0.key < $1.key }
    }

    private func reachable() throws {
        if down { throw StoreError.unavailable("the test turned it off") }
    }
}

// MARK: - A folder

/// A store in a folder on one machine (contracts/store.md rule 5): the host app's single
/// copy, or several copies on one server. A key is a file path; the entity tag is the
/// SHA-256 of the file. A write takes an advisory lock on `<key>.lock`, compares, writes
/// a temporary file, syncs it, and renames it into place. Folders shared over NFS are not
/// supported: advisory locks there cannot be trusted.
public struct FolderStore: ControlStore {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func get(_ key: String) async throws -> StoredObject? {
        let file = try url(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        // There and not readable (EIO, EACCES) is not absent (#171): absent would have
        // the member forgotten, and a browser delete its key.
        do {
            let data = try Data(contentsOf: file)
            return StoredObject(data: data, etag: Self.etag(data))
        } catch {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            throw StoreError.unavailable("cannot read \(key): \(error.localizedDescription)")
        }
    }

    public func put(_ key: String, _ data: Data, when: StoreCondition) async throws -> String {
        let file = try url(key)
        let folder = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw StoreError.unavailable("cannot make \(folder.path): \(error.localizedDescription)")
        }
        let lock = open(file.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw StoreError.unavailable("cannot lock \(key): errno \(errno)") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw StoreError.unavailable("cannot lock \(key): errno \(errno)") }
        defer { flock(lock, LOCK_UN) }

        let current = try? Data(contentsOf: file)
        switch when {
        case .absent where current != nil: throw StoreError.conflict(key: key)
        case .matching(let etag) where current.map(Self.etag) != etag: throw StoreError.conflict(key: key)
        default: break
        }
        let temporary = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.unavailable("cannot write \(key)")
        }
        let written = open(temporary.path, O_RDONLY)
        if written >= 0 { fsync(written); close(written) }
        guard rename(temporary.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw StoreError.unavailable("cannot move \(key) into place: errno \(errno)")
        }
        return Self.etag(data)
    }

    public func delete(_ key: String) async throws {
        let file = try url(key)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(atPath: file.path + ".lock")
    }

    public func list(prefix: String) async throws -> [StoredKey] {
        Self.walk(root, prefix: prefix)
    }

    /// Synchronous, because a directory enumerator cannot be iterated from async code.
    private static func walk(_ root: URL, prefix: String) -> [StoredKey] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        let base = root.resolvingSymlinksInPath().path + "/"
        var keys: [StoredKey] = []
        while let file = walker.nextObject() as? URL {
            let path = file.resolvingSymlinksInPath().path
            guard path.hasPrefix(base), !file.lastPathComponent.hasPrefix("."),
                  !path.hasSuffix(".lock"),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let key = String(path.dropFirst(base.count))
            guard key.hasPrefix(prefix), let data = try? Data(contentsOf: file) else { continue }
            keys.append(StoredKey(key: key, etag: etag(data)))
        }
        return keys.sorted { $0.key < $1.key }
    }

    /// A key names a file under the root and nothing else: no `..`, no absolute path.
    private func url(_ key: String) throws -> URL {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard !key.isEmpty, !key.hasPrefix("/"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else {
            throw StoreError.unavailable("\(key) is not a key this store keeps")
        }
        return root.appendingPathComponent(key)
    }

    static func etag(_ data: Data) -> String { "\"\(ControlAgreement.sha256(data).hexString)\"" }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

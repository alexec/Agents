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
///
/// Listing is paid for by what changed (#174), not by the size of the store: it walks only
/// the folder the prefix names, and keeps each folder's modification time and each file's
/// inode, size and modification time with its tag. A folder whose time is unchanged is
/// taken as it was; in one that changed, only files whose stamp changed are read and
/// hashed again. Every write renames a new file into place, which changes its folder's
/// time; a file edited in place by hand is seen at the next write beside it.
public struct FolderStore: ControlStore {
    public let root: URL
    let index = FolderIndex()

    public init(root: URL) { self.root = root }

    /// Files read and hashed by listing since this store was made: for the tests.
    public var hashedByListing: Int { index.hashed }

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

        // Only a file that is not there is absent (#206): one there and unreadable is
        // neither overwritten as absent nor taken as some other version.
        if when != .always {
            let current: Data?
            do {
                current = try Data(contentsOf: file)
            } catch {
                var info = stat()
                guard lstat(file.path, &info) != 0, errno == ENOENT else {
                    throw StoreError.unavailable("cannot read \(key): \(error.localizedDescription)")
                }
                current = nil
            }
            switch when {
            case .absent where current != nil: throw StoreError.conflict(key: key)
            case .matching(let etag) where current.map(Self.etag) != etag: throw StoreError.conflict(key: key)
            default: break
            }
        }
        let temporary = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try Self.writeSynced(data, to: temporary.path)
        } catch {
            unlink(temporary.path)
            throw StoreError.unavailable("cannot write \(key): \(error)")
        }
        guard rename(temporary.path, file.path) == 0 else {
            let failed = errno
            unlink(temporary.path)
            throw StoreError.unavailable("cannot move \(key) into place: errno \(failed)")
        }
        // The rename is kept only once its folder is synced too.
        let directory = open(folder.path, O_RDONLY)
        guard directory >= 0 else { throw StoreError.unavailable("cannot sync the folder of \(key): errno \(errno)") }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw StoreError.unavailable("cannot sync the folder of \(key): errno \(errno)") }
        let etag = Self.etag(data)
        // Known already, so the next listing need not read it back.
        if let stamp = StoreStamp(file.path) { index.know(key, stamp: stamp, etag: etag) }
        return etag
    }

    /// Writes a new file and syncs it, or throws with the errno that stopped it.
    private static func writeSynced(_ data: Data, to path: String) throws {
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failed: Int32 = 0
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let wrote = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    failed = errno
                    return
                }
                offset += wrote
            }
        }
        if failed == 0, fsync(fd) != 0 { failed = errno }
        if close(fd) != 0, failed == 0 { failed = errno }
        if failed != 0 { throw POSIXError(POSIXErrorCode(rawValue: failed) ?? .EIO) }
    }

    public func delete(_ key: String) async throws {
        let file = try url(key)
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(atPath: file.path + ".lock")
        index.forget(key)
    }

    public func list(prefix: String) async throws -> [StoredKey] {
        // The folder the prefix names, or the one it ends in: `v1/clients/` walks
        // `v1/clients`, `v1/codes/ab` walks `v1/codes` and keeps the keys starting `ab`.
        let folder = prefix.split(separator: "/", omittingEmptySubsequences: true)
            .dropLast(prefix.hasSuffix("/") || prefix.isEmpty ? 0 : 1).joined(separator: "/")
        var keys: [StoredKey] = []
        walk(folder, into: &keys)
        return keys.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
    }

    /// Files left behind by a copy that stopped mid-write, and probes it never deleted:
    /// temporary files, probe keys and locks with no key beside them, all older than
    /// `before`. Returns how many went. Run by the sweep (#174), never on a hot path: it
    /// visits every folder.
    public func removeLeftovers(before: Date) -> Int {
        var removed = 0
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return 0 }
        let cutoff = before.timeIntervalSince1970
        while let relative = walker.nextObject() as? String {
            let path = root.appendingPathComponent(relative).path
            guard let stamp = StoreStamp(path), stamp.isFile, stamp.modified < cutoff else { continue }
            let name = (relative as NSString).lastPathComponent
            let leftover: Bool
            if name.hasPrefix("."), name.hasSuffix(".tmp") {
                leftover = true
            } else if relative.hasPrefix("probe/") {
                leftover = true
            } else if name.hasSuffix(".lock") {
                // Only a lock nobody holds: one held is a write under way.
                guard !FileManager.default.fileExists(atPath: String(path.dropLast(".lock".count))) else { continue }
                let fd = open(path, O_RDWR)
                guard fd >= 0 else { continue }
                defer { close(fd) }
                leftover = flock(fd, LOCK_EX | LOCK_NB) == 0
            } else {
                leftover = false
            }
            if leftover, unlink(path) == 0 {
                removed += 1
                index.forget(relative)
            }
        }
        return removed
    }

    /// One folder and those under it, from what is known where nothing changed.
    private func walk(_ folder: String, into keys: inout [StoredKey]) {
        let path = folder.isEmpty ? root.path : root.appendingPathComponent(folder).path
        // The root may be a link (a temporary folder is); nothing under it is followed.
        guard let stamp = StoreStamp(path, following: folder.isEmpty), stamp.isDirectory else {
            index.forgetFolder(folder)
            return
        }
        let listing: FolderIndex.Listing
        if let known = index.listing(folder), known.stamp == stamp, known.settled {
            listing = known
        } else {
            listing = scan(folder, path: path, stamp: stamp)
        }
        for (name, etag) in listing.files { keys.append(StoredKey(key: Self.join(folder, name), etag: etag)) }
        for name in listing.folders { walk(Self.join(folder, name), into: &keys) }
    }

    /// A folder that changed: its entries again, and a file read only if its stamp moved.
    private func scan(_ folder: String, path: String, stamp: StoreStamp) -> FolderIndex.Listing {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        var files: [(String, String)] = [], folders: [String] = []
        var unreadable = false
        for name in names.sorted() where !name.hasPrefix(".") && !name.hasSuffix(".lock") {
            let key = Self.join(folder, name)
            let file = path + "/" + name
            // Not followed: a link could lead out of the store.
            guard let entry = StoreStamp(file) else { continue }
            if entry.isDirectory {
                folders.append(name)
            } else if entry.isFile {
                if let etag = index.etag(key, stamp: entry) {
                    files.append((name, etag))
                } else if let data = FileManager.default.contents(atPath: file) {
                    let etag = Self.etag(data)
                    index.know(key, stamp: entry, etag: etag, hashed: true)
                    files.append((name, etag))
                } else {
                    // There and unreadable (EACCES, EIO) is listed all the same (#206): left
                    // out, its member would be refused as unknown and a browser delete its
                    // key. The tag is no file's hash, so whoever lists it reads it, fails,
                    // and keeps what they held. It is not remembered: it is tried again.
                    unreadable = true
                    files.append((name, Self.unreadableTag(entry)))
                }
            }
        }
        // A folder changed within the clock's grain of now could change again with the
        // same time; it is scanned again next time rather than trusted. So is one holding
        // a file that could not be read: a chmod changes neither stamp.
        let settled = stamp.modified < Date().timeIntervalSince1970 - 2 && !unreadable
        let listing = FolderIndex.Listing(stamp: stamp, settled: settled, files: files, folders: folders)
        index.keep(folder, listing)
        return listing
    }

    private static func join(_ folder: String, _ name: String) -> String { folder.isEmpty ? name : folder + "/" + name }

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

    /// What a file listed and not readable is tagged with: never a hash, so never matched.
    static func unreadableTag(_ stamp: StoreStamp) -> String {
        "\"unreadable-\(stamp.inode)-\(stamp.size)-\(stamp.seconds).\(stamp.nanoseconds)\""
    }
}

/// What a file or folder is, as `lstat` says: enough to tell it changed without reading it.
struct StoreStamp: Equatable, Sendable {
    var inode: UInt64
    var size: Int64
    var seconds: Int
    var nanoseconds: Int
    var isDirectory: Bool
    var isFile: Bool

    var modified: TimeInterval { TimeInterval(seconds) + TimeInterval(nanoseconds) / 1e9 }

    init?(_ path: String, following: Bool = false) {
        var info = stat()
        guard (following ? stat(path, &info) : lstat(path, &info)) == 0 else { return nil }
        #if canImport(Darwin)
        let time = info.st_mtimespec
        #else
        let time = info.st_mtim
        #endif
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        seconds = Int(time.tv_sec)
        nanoseconds = Int(time.tv_nsec)
        let kind = info.st_mode & S_IFMT
        isDirectory = kind == S_IFDIR
        isFile = kind == S_IFREG
    }
}

/// What a folder store knows of its files between listings (#174), by folder. Shared by
/// every copy of the struct; guarded by a lock, since listing is synchronous file work.
final class FolderIndex: @unchecked Sendable {
    struct Listing {
        var stamp: StoreStamp
        /// Changed long enough ago that the same time means the same entries.
        var settled: Bool
        var files: [(String, String)]
        var folders: [String]
    }

    private let lock = NSLock()
    private var files: [String: [String: (stamp: StoreStamp, etag: String)]] = [:]
    private var folders: [String: Listing] = [:]
    private var hashCount = 0

    var hashed: Int { lock.withLock { hashCount } }

    private static func split(_ key: String) -> (String, String) {
        guard let slash = key.lastIndex(of: "/") else { return ("", key) }
        return (String(key[..<slash]), String(key[key.index(after: slash)...]))
    }

    func etag(_ key: String, stamp: StoreStamp) -> String? {
        let (folder, name) = Self.split(key)
        return lock.withLock { files[folder]?[name].flatMap { $0.stamp == stamp ? $0.etag : nil } }
    }

    func know(_ key: String, stamp: StoreStamp, etag: String, hashed: Bool = false) {
        let (folder, name) = Self.split(key)
        lock.withLock {
            files[folder, default: [:]][name] = (stamp, etag)
            if hashed { hashCount += 1 }
        }
    }

    func forget(_ key: String) {
        let (folder, name) = Self.split(key)
        _ = lock.withLock { files[folder]?.removeValue(forKey: name) }
    }

    func listing(_ folder: String) -> Listing? { lock.withLock { folders[folder] } }

    /// A folder scanned again: files no longer in it are forgotten.
    func keep(_ folder: String, _ listing: Listing) {
        let present = Set(listing.files.map(\.0))
        lock.withLock {
            folders[folder] = listing
            files[folder] = files[folder]?.filter { present.contains($0.key) }
        }
    }

    /// A folder that is gone, and everything under it.
    func forgetFolder(_ folder: String) {
        let inside = folder + "/"
        lock.withLock {
            guard folders[folder] != nil || files[folder] != nil else { return }
            folders = folders.filter { $0.key != folder && !$0.key.hasPrefix(inside) }
            files = files.filter { $0.key != folder && !$0.key.hasPrefix(inside) }
        }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

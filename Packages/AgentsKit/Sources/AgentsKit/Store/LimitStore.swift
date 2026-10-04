import Foundation
import AgentsKitCore

/// The two limits the reader set, kept where the daemon can read them.
///
/// One file, read whole and written whole, on the pattern `ProjectStore` already
/// follows. There are two facts in it and both belong to the person.
///
/// A missing or unreadable file is an empty `CostLimits` — no limit. A daemon that
/// cannot read its own limits must not refuse to work, and it must not invent a limit
/// nobody set: both failures are worse than the thing the file is for.
///
/// Held once read (#177), and read again only when the file's modification date, size
/// or inode moved: one `stat` per question instead of an open, a read and a decode, at
/// every prompt and every cost-bearing usage update. Still read afresh after anyone
/// else writes it.
public final class LimitStore: @unchecked Sendable {
    private let locations: StoreLocations
    private let lock = NSLock()
    private var held: (limits: CostLimits, stamp: FileStamp?)?

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func load() -> CostLimits {
        lock.withLock {
            let stamp = FileStamp(locations.limits)
            if let held, held.stamp == stamp { return held.limits }
            let limits = StoreFile.load(CostLimits.self, at: locations.limits, empty: CostLimits(),
                                        meaning: "no spending limits set")
            // Stamped as it is after the read: a file set aside is gone, and nil.
            held = (limits, FileStamp(locations.limits))
            return limits
        }
    }

    public func save(_ limits: CostLimits) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
            let data = try StoreCoding.encoder.encode(limits)
            try StoreFile.write(data, to: locations.limits)
            held = (limits, FileStamp(locations.limits))
        }
    }
}

/// Which version of a file is on disk, as far as one `stat` can tell: a rename puts a
/// new inode in place, and an edit in place moves the date or the size.
struct FileStamp: Equatable {
    var inode: UInt64
    var size: Int64
    var modified: Date

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        self.size = size
        self.modified = modified
    }
}

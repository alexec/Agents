import Foundation
import AgentsKitCore

/// Every archived agent, slim, with its size on disk: what the daemon reads at start
/// instead of opening each archived record (051, research R3).
///
/// A cache and never the truth. `agent.json` is: an entry whose record is newer than the
/// entry is read again, a directory the index does not name is read in full, and a
/// missing or unreadable index is simply one that names nothing, which is also the first
/// start after 051.
public struct ArchiveIndex: Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        /// Slim: without the options, commands and plans.
        public var agent: Agent
        public var sizeOnDisk: Int
        /// `agent.json`'s modification date when this entry was made.
        public var fileModifiedAt: Date

        public init(agent: Agent, sizeOnDisk: Int, fileModifiedAt: Date) {
            self.agent = agent.isSlim ? agent : agent.slimmed()
            self.sizeOnDisk = sizeOnDisk
            self.fileModifiedAt = fileModifiedAt
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Decoded from the index, it is slim whatever the flag says: the flag is
            // never written.
            agent = try c.decode(Agent.self, forKey: .agent).slimmed()
            sizeOnDisk = try c.decode(Int.self, forKey: .sizeOnDisk)
            fileModifiedAt = try c.decode(Date.self, forKey: .fileModifiedAt)
        }
    }

    struct File: Codable {
        var version = 1
        var writtenAt: Date
        var entries: [Entry]
    }

    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    /// The entries by id, or nil when there is no index this build can read.
    public func load() -> [UUID: Entry]? {
        guard let data = try? Data(contentsOf: locations.archiveIndex) else { return nil }
        guard let file = try? StoreCoding.decoder.decode(File.self, from: data), file.version == 1 else {
            DaemonLog.shared.write("archive.json could not be read; every archived record will be read once")
            StoreCoding.setAside(locations.archiveIndex)
            return nil
        }
        return Dictionary(file.entries.map { ($0.agent.id, $0) }, uniquingKeysWith: { _, newer in newer })
    }

    public func save(_ entries: [UUID: Entry], now: Date = Date()) throws {
        let file = File(writtenAt: now, entries: entries.values.sorted { $0.agent.id.uuidString < $1.agent.id.uuidString })
        try StoreCoding.encoder.encode(file).write(to: locations.archiveIndex, options: .atomic)
    }

    /// The allocated size of everything in an agent's folder, in bytes.
    public static func sizeOnDisk(_ folder: URL) -> Int {
        // Allocated size where the platform says it; the plain size on Linux, whose
        // Foundation does not (037's server daemon builds this too).
        #if canImport(Darwin)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        #else
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        #endif
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            #if canImport(Darwin)
            total += values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            #else
            total += values.fileSize ?? 0
            #endif
        }
        return total
    }

    /// When a record file was last changed, for telling a stale entry from a current one.
    public static func modifiedAt(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

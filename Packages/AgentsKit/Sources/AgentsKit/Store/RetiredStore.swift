import Foundation
import AgentsKitCore

/// What is left of retired agents: one tombstone per line, appended, never rewritten (051).
///
/// Written before anything of the agent is deleted, and synced to the disk before the
/// append returns, so there is no moment when an agent is gone and nothing says so
/// (FR-017). Kept apart from `agents/`, the folder the daemon lists and reads at start,
/// so a retired agent costs start nothing.
public final class RetiredStore: @unchecked Sendable {
    private let locations: StoreLocations
    private let lock = NSLock()

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    /// Every tombstone, by id. A torn last line — a daemon killed mid-append, whose
    /// agent was therefore never deleted — is skipped; any other unreadable line is
    /// counted in the log.
    public func loadAll() -> [UUID: Tombstone] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: locations.retired) else { return [:] }
        var tombstones: [UUID: Tombstone] = [:]
        var unreadable = 0
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for (index, bytes) in lines.enumerated() {
            guard let tombstone = try? StoreCoding.decoder.decode(Tombstone.self, from: Data(bytes)) else {
                if index != lines.count - 1 { unreadable += 1 }
                continue
            }
            tombstones[tombstone.id] = tombstone
        }
        if unreadable > 0 { DaemonLog.shared.write("retired.jsonl: skipped \(unreadable) unreadable line(s)") }
        return tombstones
    }

    /// Appended and synced, or thrown. Nothing may be deleted until this returns.
    public func append(_ tombstone: Tombstone) throws {
        lock.lock(); defer { lock.unlock() }
        var line = try StoreCoding.encoder.encode(tombstone)
        line.append(UInt8(ascii: "\n"))
        let url = locations.retired
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let handle = try StoreCoding.openForAdding(url, appending: false)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // A line torn by a kill would glue itself to this one; end it first.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }
}

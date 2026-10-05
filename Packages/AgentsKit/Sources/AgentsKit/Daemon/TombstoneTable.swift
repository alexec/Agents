import Foundation
import AgentsKitCore

/// What is left of every retired agent, with each project's share of it kept as it
/// changes (#204).
///
/// It used to be a dictionary whose every change threw away the per-project grouping, so
/// the next project summary grouped every tombstone there had ever been again: retiring
/// k agents cost k times all of them. Now a retire moves one project's numbers, and a
/// summary reads them without walking anything.
///
/// Reading and writing by id is the dictionary's, so the rest of the daemon is unchanged.
struct TombstoneTable {
    private(set) var byID: [UUID: Tombstone] = [:]
    /// Each project's numbers, by its standardized folder. Only for folders with a tombstone.
    private(set) var tallies: [URL: TombstoneTally] = [:]
    /// Each project's tombstones, so taking one away can find the others' oldest and newest.
    private var members: [URL: Set<UUID>] = [:]
    /// Moves whenever a folder gains its first tombstone or loses its last (#204).
    private(set) var foldersVersion = 0

    init() {}

    init(_ tombstones: [UUID: Tombstone]) {
        for (id, tombstone) in tombstones { self[id] = tombstone }
    }

    subscript(id: UUID) -> Tombstone? {
        get { byID[id] }
        set {
            if let before = byID.removeValue(forKey: id) { unfile(before) }
            if let newValue {
                byID[id] = newValue
                file(newValue)
            }
        }
    }

    var values: Dictionary<UUID, Tombstone>.Values { byID.values }
    var keys: Dictionary<UUID, Tombstone>.Keys { byID.keys }
    var count: Int { byID.count }
    var isEmpty: Bool { byID.isEmpty }

    /// One project's tombstones, by its folder, without walking anybody else's.
    func inProject(_ folder: URL) -> [Tombstone] {
        (members[Project.standardize(folder)] ?? []).compactMap { byID[$0] }
    }

    private mutating func file(_ tombstone: Tombstone) {
        let folder = Project.standardize(tombstone.project)
        if members[folder] == nil { foldersVersion += 1 }
        members[folder, default: []].insert(tombstone.id)
        tallies[folder, default: TombstoneTally()].add(tombstone)
    }

    private mutating func unfile(_ tombstone: Tombstone) {
        let folder = Project.standardize(tombstone.project)
        members[folder]?.remove(tombstone.id)
        guard let left = members[folder], !left.isEmpty else {
            members[folder] = nil
            tallies[folder] = nil
            foldersVersion += 1
            return
        }
        // Taking one away is rare (nothing does it but a test): the folder's own
        // tombstones are counted again, never anybody else's.
        var tally = TombstoneTally()
        for id in left { if let kept = byID[id] { tally.add(kept) } }
        tallies[folder] = tally
    }
}

/// One project's retired agents in the numbers its summary shows (#204).
struct TombstoneTally: Equatable {
    var count = 0
    var costToDate: [String: Decimal] = [:]
    var oldestCreated: Date?
    var newestActivity: Date?

    mutating func add(_ tombstone: Tombstone) {
        count += 1
        for (currency, amount) in tombstone.costToDate { costToDate[currency, default: 0] += amount }
        oldestCreated = min(oldestCreated ?? tombstone.createdAt, tombstone.createdAt)
        newestActivity = max(newestActivity ?? tombstone.lastActivityAt, tombstone.lastActivityAt)
    }
}

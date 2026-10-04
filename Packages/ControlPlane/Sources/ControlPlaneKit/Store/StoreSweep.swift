import AgentsKitCore
import Foundation

/// What the store keeps, and for how long (#174, contracts/store.md rule 11). Run by every
/// copy once an hour; deleting is plain and a race between two copies changes nothing.
///
/// - `events/<day>/…`: seven days. Nothing reads them back yet; they are for a copy that
///   missed a broadcast, and a week covers any outage worth catching up on.
/// - `codes/<id>.json` and `.spent`: a day after the code expires. Until then a late try
///   is refused as `expired`, not `unknown`.
/// - Tombstones in `clients/` and `hosts/`: seven days after `forgottenAt`. Until then a
///   browser that comes back is told it was forgotten, and deletes its key. One written
///   before that date was kept is given today's, so it goes a week on.
/// - In a folder store, temporary files, probes and unheld locks with no key, an hour old.
///
/// At most `mostPerSweep` deletions a time, so a store that never was swept is caught up
/// over a few hours rather than in one long stall.
public struct StoreSweep: Sendable {
    public static let eventsKept: TimeInterval = 7 * 86_400
    public static let codesKeptAfterExpiry: TimeInterval = 86_400
    public static let tombstonesKept: TimeInterval = 7 * 86_400
    public static let leftoversKept: TimeInterval = 3_600
    public static let every: Duration = .seconds(3_600)
    public static let mostPerSweep = 1_000

    public struct Report: Sendable, Equatable, CustomStringConvertible {
        public var events = 0, codes = 0, tombstones = 0, leftovers = 0, dated = 0
        public var total: Int { events + codes + tombstones + leftovers }
        public var description: String {
            "removed \(events) events, \(codes) code files, \(tombstones) tombstones, \(leftovers) leftovers; dated \(dated) tombstones"
        }
    }

    let records: ControlRecords
    let now: Date
    let most: Int

    public init(records: ControlRecords, now: Date = Date(), most: Int = StoreSweep.mostPerSweep) {
        self.records = records
        self.now = now
        self.most = most
    }

    public func run() async throws -> Report {
        let store = await records.store
        var report = Report()
        var left = most

        // Events, by the day in their key.
        let oldestDay = now.addingTimeInterval(-Self.eventsKept).formatted(Date.ISO8601FormatStyle().year().month().day())
        for entry in try await store.list(prefix: "v1/events/") where left > 0 {
            let day = entry.key.dropFirst("v1/events/".count).prefix { $0 != "/" }
            guard day < oldestDay else { continue }
            try await store.delete(entry.key)
            report.events += 1; left -= 1
        }

        // Codes, by their expiry; a `.spent` whose code is gone goes too.
        let codes = try await store.list(prefix: "v1/codes/").map(\.key)
        let named = Set(codes)
        let expiredBefore = now.addingTimeInterval(-Self.codesKeptAfterExpiry)
        // Two left at least: a code may go with its `.spent`.
        for key in codes where left > 1 {
            if key.hasSuffix(".spent") {
                guard !named.contains(String(key.dropLast(".spent".count)) + ".json") else { continue }
            } else {
                guard let object = try await store.get(key),
                      let stored = try? ControlRecords.decoder.decode(ControlCodes.Stored.self, from: object.data),
                      stored.expires < expiredBefore else { continue }
                let spent = String(key.dropLast(".json".count)) + ".spent"
                if named.contains(spent) { try await store.delete(spent); report.codes += 1; left -= 1 }
            }
            try await store.delete(key)
            report.codes += 1; left -= 1
        }

        // Tombstones, as the records found them.
        let forgottenBefore = now.addingTimeInterval(-Self.tombstonesKept)
        for key in await records.tombstoneKeys where left > 0 {
            guard let object = try await store.get(key),
                  let mark = try? ControlRecords.decoder.decode(Tombstone.self, from: object.data),
                  mark.forgotten == true else { continue }
            guard let at = mark.forgottenAt else {
                if try await date(key, object, in: store) { report.dated += 1 }
                continue
            }
            guard at < forgottenBefore else { continue }
            // Read again just before: a record written over it since is not a tombstone.
            guard try await store.get(key)?.etag == object.etag else { continue }
            try await store.delete(key)
            report.tombstones += 1; left -= 1
        }

        if let folder = store as? FolderStore {
            report.leftovers = folder.removeLeftovers(before: now.addingTimeInterval(-Self.leftoversKept))
        }
        // The records forget the tombstones that went, and see the dated ones.
        if report.tombstones + report.dated > 0 { try await records.load() }
        return report
    }

    /// A tombstone from before `forgottenAt`: given today's date, against the version read.
    private func date(_ key: String, _ object: StoredObject, in store: any ControlStore) async throws -> Bool {
        let data: Data
        if key.hasPrefix(ControlRecords.clientsPrefix) {
            guard var record = try? ControlRecords.decoder.decode(ClientRecord.self, from: object.data) else { return false }
            record.forgottenAt = now
            record.rev += 1
            data = try ControlRecords.encoder.encode(record)
        } else {
            guard var record = try? ControlRecords.decoder.decode(HostRecord.self, from: object.data) else { return false }
            record.forgottenAt = now
            record.rev += 1
            data = try ControlRecords.encoder.encode(record)
        }
        do {
            _ = try await store.put(key, data, when: .matching(object.etag))
            return true
        } catch StoreError.conflict {
            return false
        }
    }

    private struct Tombstone: Decodable {
        var forgotten: Bool?
        var forgottenAt: Date?
    }
}

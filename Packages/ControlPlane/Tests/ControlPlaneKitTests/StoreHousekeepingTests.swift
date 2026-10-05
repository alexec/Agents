import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

/// The store is paid for by what changed, what is dead goes, and control.log says when
/// (#174).
@Suite("Store housekeeping", .timeLimit(.minutes(2)))
struct StoreHousekeepingTests {
    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID().uuidString)")
    }

    static func client(_ n: Int) -> ClientRecord {
        ClientRecord(id: UUID(), name: "Device \(n)", kind: .iPhone, publicKey: Data(repeating: 4, count: 65),
                     paired: Date(), rev: 1)
    }

    static func put(_ record: ClientRecord, in store: some ControlStore) async throws {
        _ = try await store.put(ControlRecords.clientKey(record.id), try ControlRecords.encoder.encode(record), when: .absent)
    }

    /// Makes a file look `age` seconds old.
    static func age(_ path: String, _ age: TimeInterval) throws {
        let then = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: then], ofItemAtPath: path)
    }

    // MARK: Listing

    @Test func onlyChangedRecordsAreReadAgain() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FolderStore(root: root)
        var records: [ClientRecord] = []  // index-ok: forty, made below
        for n in 0..<40 {
            let record = Self.client(n)
            records.append(record)
            try await Self.put(record, in: writer)
        }
        // Elsewhere in the store, never read by a listing of clients.
        for n in 0..<30 { _ = try await writer.put("v1/events/2026-01-01/\(n).json", Data("{}".utf8), when: .absent) }
        #expect(writer.hashedByListing == 0)

        // Another copy on the same folder reads each record once.
        let reader = FolderStore(root: root)
        let first = try await reader.list(prefix: ControlRecords.clientsPrefix)
        #expect(first.count == 40)
        #expect(reader.hashedByListing == 40)
        for entry in first.prefix(3) { #expect(try await reader.get(entry.key)?.etag == entry.etag) }

        // Again, unchanged: nothing read, whether the folder has settled or not.
        _ = try await reader.list(prefix: ControlRecords.clientsPrefix)
        #expect(reader.hashedByListing == 40)
        try Self.age(root.appendingPathComponent("v1/clients").path, 60)
        _ = try await reader.list(prefix: ControlRecords.clientsPrefix)
        _ = try await reader.list(prefix: ControlRecords.clientsPrefix)
        #expect(reader.hashedByListing == 40)

        // One changed by the other copy: that one alone, with its new tag.
        var changed = records[5]
        changed.name = "Renamed"
        changed.rev = 2
        let key = ControlRecords.clientKey(changed.id)
        let held = try #require(try await writer.get(key))
        let etag = try await writer.put(key, try ControlRecords.encoder.encode(changed), when: .matching(held.etag))
        let after = try await reader.list(prefix: ControlRecords.clientsPrefix)
        #expect(reader.hashedByListing == 41)
        #expect(after.first { $0.key == key }?.etag == etag)

        // One deleted: gone from the listing, and nothing read for it.
        try await writer.delete(ControlRecords.clientKey(records[0].id))
        let fewer = try await reader.list(prefix: ControlRecords.clientsPrefix)
        #expect(fewer.count == 39)
        #expect(reader.hashedByListing == 41)
    }

    @Test func aPrefixInsideAFolderKeepsOnlyItsKeys() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FolderStore(root: root)
        _ = try await store.put("v1/codes/ab1.json", Data("1".utf8), when: .absent)
        _ = try await store.put("v1/codes/cd2.json", Data("2".utf8), when: .absent)
        _ = try await store.put("v1/control.json", Data("3".utf8), when: .absent)
        #expect(try await store.list(prefix: "v1/codes/ab").map(\.key) == ["v1/codes/ab1.json"])
        #expect(try await store.list(prefix: "v1/").map(\.key) == ["v1/codes/ab1.json", "v1/codes/cd2.json", "v1/control.json"])
        #expect(try await store.list(prefix: "v1/nothing/").isEmpty)
    }

    @Test func recordsLoadedTwiceReadNothingTheSecondTime() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 0..<25 { try await Self.put(Self.client(n), in: FolderStore(root: root)) }
        let reader = FolderStore(root: root)
        let records = ControlRecords(store: reader)
        try await records.load()
        let once = reader.hashedByListing
        try await records.load()
        #expect(reader.hashedByListing == once)
        #expect(await records.clients.count == 25)
    }

    // MARK: The sweep

    @Test func theSweepRemovesTheDeadAndKeepsTheLive() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FolderStore(root: root)
        let records = ControlRecords(store: store)
        _ = try await records.settings { ControlSettings(name: "test", machineID: "m") }
        let now = Date()
        func day(_ ago: Int) -> String {
            now.addingTimeInterval(-Double(ago) * 86_400).formatted(Date.ISO8601FormatStyle().year().month().day())
        }
        _ = try await store.put("v1/events/\(day(10))/old.json", Data("{}".utf8), when: .absent)
        _ = try await store.put("v1/events/\(day(1))/new.json", Data("{}".utf8), when: .absent)

        func code(_ id: String, expires: Date, spent: Bool) async throws {
            let stored = ControlCodes.Stored(purpose: .client, expires: expires)
            _ = try await store.put(ControlCodes.key(id), try ControlRecords.encoder.encode(stored), when: .absent)
            if spent { _ = try await store.put(ControlCodes.spentKey(id), Data("{}".utf8), when: .absent) }
        }
        try await code("long-gone", expires: now.addingTimeInterval(-2 * 86_400), spent: true)
        try await code("just-expired", expires: now.addingTimeInterval(-600), spent: false)
        try await code("good", expires: now.addingTimeInterval(600), spent: true)
        _ = try await store.put(ControlCodes.spentKey("orphan"), Data("{}".utf8), when: .absent)

        let live = Self.client(1), forgotten = Self.client(2)
        try await records.save(live)
        try await records.save(forgotten)
        try await records.forget(forgotten.id)
        // A tombstone from before forgottenAt was kept.
        var legacy = Self.client(3)
        legacy.forgotten = true
        try await Self.put(legacy, in: store)
        try await records.load()
        #expect(await records.wasForgotten(forgotten.id))

        // Leftovers: an old temporary file goes, a new one stays.
        let folder = root.appendingPathComponent("v1/clients").path
        let oldTemporary = folder + "/.x.json.1.tmp", newTemporary = folder + "/.y.json.2.tmp"
        FileManager.default.createFile(atPath: oldTemporary, contents: Data())
        FileManager.default.createFile(atPath: newTemporary, contents: Data())
        try Self.age(oldTemporary, 2 * 3_600)

        let first = try await StoreSweep(records: records, now: now).run()
        #expect(first.events == 1)
        #expect(first.codes == 3) // long-gone and its .spent, and the orphan .spent
        #expect(first.tombstones == 0)
        #expect(first.dated == 1)
        #expect(first.leftovers == 1)
        let keys = Set(try await store.list(prefix: "v1/").map(\.key))
        #expect(!keys.contains("v1/events/\(day(10))/old.json"))
        #expect(keys.contains("v1/events/\(day(1))/new.json"))
        #expect(!keys.contains(ControlCodes.key("long-gone")) && !keys.contains(ControlCodes.spentKey("long-gone")))
        #expect(!keys.contains(ControlCodes.spentKey("orphan")))
        #expect(keys.contains(ControlCodes.key("just-expired")))
        #expect(keys.contains(ControlCodes.key("good")) && keys.contains(ControlCodes.spentKey("good")))
        #expect(keys.contains(ControlRecords.clientKey(forgotten.id)))
        #expect(!FileManager.default.fileExists(atPath: oldTemporary))
        #expect(FileManager.default.fileExists(atPath: newTemporary))

        // Eight days on: both tombstones (the legacy one was dated today) are older than
        // seven days; the live client and settings stay.
        let later = try await StoreSweep(records: records, now: now.addingTimeInterval(8 * 86_400)).run()
        #expect(later.tombstones == 2)
        let left = Set(try await store.list(prefix: "v1/").map(\.key))
        #expect(!left.contains(ControlRecords.clientKey(forgotten.id)))
        #expect(!left.contains(ControlRecords.clientKey(legacy.id)))
        #expect(left.contains(ControlRecords.clientKey(live.id)))
        #expect(left.contains(ControlRecords.settingsKey))
        #expect(await records.client(live.id) != nil)
        #expect(await !records.wasForgotten(forgotten.id))
        // A device forgotten and paired again after that pairs as new.
        try await records.save(forgotten)
        #expect(await records.client(forgotten.id) != nil)
    }

    @Test func theSweepStopsAtItsBound() async throws {
        let store = MemoryStore()
        let records = ControlRecords(store: store)
        for n in 0..<12 { _ = try await store.put("v1/events/2000-01-01/\(n).json", Data("{}".utf8), when: .absent) }
        let report = try await StoreSweep(records: records, most: 5).run()
        #expect(report.events == 5)
        #expect(try await store.list(prefix: "v1/events/").count == 7)
    }

    // MARK: control.log

    static var stamped: Regex<(Substring, Substring)> { #/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2}) /# }

    @Test func everyLineCarriesTheTimeAndItsZone() throws {
        let root = Self.root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("control.log")
        let log = ControlLog()
        log.take(file, standardStreams: false)
        log.write("listening on 0.0.0.0:8791")
        log.write("store: one\ntwo")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        try #require(lines.count == 3)
        for line in lines { #expect(line.firstMatch(of: Self.stamped) != nil, "\(line)") }
        #expect(lines[0].hasSuffix(" listening on 0.0.0.0:8791"))
        #expect(lines[2].hasSuffix(" two"))
    }

    @Test func theLogRollsPastItsLimit() throws {
        let root = Self.root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("control.log")
        let previous = root.appendingPathComponent("control.previous.log")
        let log = ControlLog()
        log.take(file, limit: 1_000, standardStreams: false)
        for n in 0..<100 { log.write("line \(n) " + String(repeating: "x", count: 40)) }
        let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
        #expect(FileManager.default.fileExists(atPath: previous.path))
        #expect(size(file) <= 1_000 + 100)
        #expect(size(previous) <= 1_000 + 100)
        // The newest line is in the current file, and nothing older than one roll is kept.
        let current = try String(contentsOf: file, encoding: .utf8)
        #expect(current.contains("line 99 "))
        #expect(!(try String(contentsOf: previous, encoding: .utf8)).contains("line 0 "))
    }
}

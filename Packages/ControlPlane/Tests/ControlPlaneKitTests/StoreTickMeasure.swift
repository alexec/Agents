import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

/// What one 15 s backstop costs on a large folder store (#174), and what the sweep leaves
/// of it. Run on purpose, with `AGENTS_MEASURE_STORE=1`; it prints and asserts nothing.
@Suite("Store tick measure", .enabled(if: ProcessInfo.processInfo.environment["AGENTS_MEASURE_STORE"] == "1"))
struct StoreTickMeasure {
    static let clients = 5_000, hosts = 200, eventDays = 30, eventsPerDay = 500, codes = 2_000

    @Test func tick() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tick-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FolderStore(root: root)
        try await Self.seed(store)
        print("seeded: \(Self.files(root)) files, \(Self.bytes(root)) bytes")

        // A reader that has seen none of it, as a copy started on it would be.
        let reader = FolderStore(root: root)
        let records = ControlRecords(store: reader)
        let first = try await Self.measure { try await records.load() }
        print("first load: cpu \(first.cpu) ms, wall \(first.wall) ms, hashed \(reader.hashedByListing)")
        // Settled: nothing written for longer than the clock's grain, as a store at rest is.
        try await Task.sleep(for: .seconds(3))
        var cpu = 0.0, wall = 0.0
        let ticks = 10
        for _ in 0..<ticks {
            let one = try await Self.measure { try await records.load() }
            cpu += one.cpu; wall += one.wall
        }
        print("idle tick: cpu \(cpu / Double(ticks)) ms, wall \(wall / Double(ticks)) ms, hashed \(reader.hashedByListing)")

        // One client changed by another writer between ticks.
        let changed = ControlRecords.clientKey(Self.clientID(7))
        let held = try #require(try await store.get(changed))
        _ = try await store.put(changed, held.data + Data(" ".utf8), when: .matching(held.etag))
        let one = try await Self.measure { try await records.load() }
        print("tick after one change: cpu \(one.cpu) ms, wall \(one.wall) ms, hashed \(reader.hashedByListing)")
        print("clients held: \(await records.clients.count)")

        // Store size over sweeps: each removes at most StoreSweep.mostPerSweep.
        var sweeps = 0
        while true {
            var report = StoreSweep.Report()
            let sweep = try await Self.measure { report = try await StoreSweep(records: records).run() }
            sweeps += 1
            print("sweep \(sweeps): cpu \(sweep.cpu) ms, wall \(sweep.wall) ms; \(report); left \(Self.files(root)) files, \(Self.bytes(root)) bytes")
            if report.total == 0 || sweeps > 40 { break }
        }
        print("hashed by listing in all: \(reader.hashedByListing)")
    }

    static func clientID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static func seed(_ store: FolderStore) async throws {
        let key = Data(repeating: 4, count: 65)
        for n in 0..<clients {
            let record = ClientRecord(id: clientID(n), name: "Device \(n)", kind: .iPhone, publicKey: key,
                                      paired: Date(), rev: 1)
            _ = try await store.put(ControlRecords.clientKey(record.id), try ControlRecords.encoder.encode(record), when: .absent)
        }
        for n in 0..<hosts {
            let record = HostRecord(id: HostID(rawValue: "host-\(n)"), name: "Host \(n)", publicKey: key, rev: 1)
            _ = try await store.put(ControlRecords.hostKey(record.id), try ControlRecords.encoder.encode(record), when: .absent)
        }
        let now = Date()
        for day in 0..<eventDays {
            let at = now.addingTimeInterval(-Double(day) * 86_400)
            let stamp = at.formatted(Date.ISO8601FormatStyle().year().month().day())
            for n in 0..<eventsPerDay {
                let event = ControlEvent(kind: .clientPaired, subject: UUID().uuidString, at: at, by: "copy")
                _ = try await store.put("v1/events/\(stamp)/\(String(format: "%013d", n))-x.json",
                                        try ControlRecords.encoder.encode(event), when: .absent)
            }
        }
        for n in 0..<codes {
            let stored = ControlCodes.Stored(purpose: .client, expires: now.addingTimeInterval(-Double(n % 10) * 86_400))
            _ = try await store.put(ControlCodes.key("code\(n)"), try ControlRecords.encoder.encode(stored), when: .absent)
            if n % 2 == 0 { _ = try await store.put(ControlCodes.spentKey("code\(n)"), Data("{}".utf8), when: .absent) }
        }
    }

    static func measure(_ work: () async throws -> Void) async throws -> (cpu: Double, wall: Double) {
        let cpu0 = cpuMillis(), wall0 = Date()
        try await work()
        return (cpuMillis() - cpu0, Date().timeIntervalSince(wall0) * 1000)
    }

    static func cpuMillis() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }

    static func files(_ root: URL) -> Int {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects.count) ?? 0
    }

    static func bytes(_ root: URL) -> Int {
        var total = 0
        for case let path as String in FileManager.default.enumerator(atPath: root.path) ?? NSEnumerator() {
            total += (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.size] as? Int) ?? 0
        }
        return total
    }
}

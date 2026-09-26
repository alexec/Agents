import AgentsKitCore
import CloudKit
import Foundation

/// T056: prove the private database is reachable from this bundle. One zone, one
/// record, written and read back, and the account status first so a failure names
/// what is wrong (no account, restricted, no container) rather than "failed".
enum Spike {
    static let container = "iCloud.com.alexecollins.agents"

    static func run() async throws {
        let container = CKContainer(identifier: container)
        let status = try await container.accountStatus()
        log("spike: account status \(status.rawValue) (1 is available)")
        let database = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: "spike")
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        log("spike: zone saved")
        let id = CKRecord.ID(recordName: "spike-\(UUID().uuidString)", zoneID: zone.zoneID)
        let record = CKRecord(recordType: "Spike", recordID: id)
        record["at"] = Date() as CKRecordValue
        let saved = try await database.save(record)
        log("spike: wrote \(saved.recordID.recordName)")
        let read = try await database.record(for: saved.recordID)
        log("spike: read back \(read.recordID.recordName) at \(read["at"] as Date? ?? .distantPast)")
        try await database.deleteRecord(withID: read.recordID)
        log("spike: ok — the private database is reachable from this bundle")
    }
}

/// C3: what is in the mailbox, exactly as CloudKit holds it — every field of every item,
/// printed, so the check that nothing legible is in the middle is a check of the bytes
/// rather than of the dashboard's rendering of them.
enum Peek {
    /// `--peek <device id>`: the query is by device, as `empty(device:)`'s is, because
    /// `recordName` is not queryable in a development schema and `device` is.
    static func run(device: String) async throws {
        let database = CKContainer(identifier: Spike.container).privateCloudDatabase
        let zone = CKRecordZone.ID(zoneName: CloudKitMailbox.zoneName, ownerName: CKCurrentUserDefaultName)
        let query = CKQuery(recordType: CloudKitMailbox.recordType,
                            predicate: NSPredicate(format: "%K == %@", CloudKitMailbox.Field.device, device))
        let page = try await database.records(matching: query, inZoneWith: zone, desiredKeys: nil)
        log("peek: \(page.matchResults.count) item(s)")
        for (id, result) in page.matchResults {
            guard let record = try? result.get() else { continue }
            log("peek: record \(id.recordName)")
            for key in record.allKeys().sorted() {
                log("peek:   \(key) = \(String(describing: record[key]).prefix(400))")
            }
        }
    }
}

/// 046 T005: the relay through the real iCloud, both ends in this one process — a phone
/// end with a key of its own, the Mac's end with another, and a pretend daemon that
/// answers every request. Ten round trips timed with the Mac polling as it ships (every
/// second), then one reply big enough to go as an asset, then the zone deleted. What it
/// cannot measure is the phone's radio; that is T006.
enum RelaySpike {
    static func run() async throws {
        let device = UUID()
        let mac = DeviceKey.ephemeral(), phone = DeviceKey.ephemeral()
        let (near, far) = PairedTransport.pair()
        let answering = Task {
            for try await line in far.lines() {
                guard let object = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue,
                      let id = object["id"] else { continue }
                let reply: JSONValue = object["method"]?.stringValue == "big"
                    ? ["jsonrpc": "2.0", "id": id, "result": .string(String(repeating: "x", count: 3_000_000))]
                    : ["jsonrpc": "2.0", "id": id, "result": [:]]
                try far.write(line: String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
            }
        }
        defer { answering.cancel() }
        let host = RelayHostCore(channel: CloudKitRelayChannel(), key: mac, openDaemon: { near })
        await host.pair(device, key: phone.publicKey)
        let hosting = Task { await host.run() }
        defer { hosting.cancel() }

        let opened = ContinuousClock.now
        let transport = RelayTransport(channel: CloudKitRelayChannel(), device: device, key: phone,
                                       macKey: mac.publicKey)
        try await transport.open(timeout: .seconds(30))
        log("relay spike: session open in \(ContinuousClock.now - opened)")
        var lines = transport.lines().makeAsyncIterator()
        var times: [Duration] = []
        for n in 1...10 {
            let sent = ContinuousClock.now
            try transport.write(line: #"{"jsonrpc":"2.0","id":\#(n),"method":"daemon/ping"}"#)
            _ = try await lines.next()
            let took = ContinuousClock.now - sent
            times.append(took)
            log("relay spike: round trip \(n): \(took)")
        }
        log("relay spike: worst \(times.max()!), median \(times.sorted()[times.count / 2])")
        let sent = ContinuousClock.now
        try transport.write(line: #"{"jsonrpc":"2.0","id":99,"method":"big"}"#)
        let big = try await lines.next()
        log("relay spike: a 3 MB reply came back whole (\(big?.utf8.count ?? 0) bytes) in \(ContinuousClock.now - sent)")
        transport.close()
        await host.forget(device)
        log("relay spike: zone deleted; ok")
    }
}

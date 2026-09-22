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

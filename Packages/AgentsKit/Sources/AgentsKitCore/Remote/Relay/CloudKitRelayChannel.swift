// Not on Linux: the server build of agentsd has no CloudKit and no relay (037).
#if canImport(CloudKit)
import CloudKit
import Foundation

/// The real place relayed frames wait: the person's CloudKit **private** database, one
/// zone per device, in the container 005 set up (046, contracts/relay.md).
///
/// The zone is named for the device so each end reads only its own traffic and forgetting
/// a device is one delete (R5). Change tokens are held in memory: an end that restarts
/// reads the zone from the start, and what it finds there is either its own session's
/// (which it knows) or an older one's (which it ignores by session id), so nothing needs
/// to survive a restart but the frames themselves.
public actor CloudKitRelayChannel: RelayChannel {
    public static let recordType = "Frame"
    public static let zonePrefix = "relay-"
    /// Past this, the sealed bytes go as an asset rather than a field: a record holds a
    /// megabyte in all, and this leaves room for the rest of it.
    public static let inlineLimit = 700 * 1024

    enum Field {
        static let session = "session"
        static let direction = "direction"
        static let seq = "seq"
        static let sealed = "sealed"
        static let asset = "asset"
        static let sentAt = "sentAt"
    }

    private let database: CKDatabase
    private var zoneTokens: [UUID: CKServerChangeToken] = [:]
    private var databaseToken: CKServerChangeToken?

    public init(container: CKContainer = CKContainer(identifier: CloudKitMailbox.containerID)) {
        database = container.privateCloudDatabase
    }

    public static func zoneID(_ device: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zonePrefix + device.uuidString, ownerName: CKCurrentUserDefaultName)
    }

    static func device(of zone: CKRecordZone.ID) -> UUID? {
        guard zone.zoneName.hasPrefix(zonePrefix) else { return nil }
        return UUID(uuidString: String(zone.zoneName.dropFirst(zonePrefix.count)))
    }

    public func ensureZone(device: UUID) async throws {
        try await mapped { _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID(device))],
                                                                   deleting: []) }
    }

    public func post(_ frame: FrameRecord, device: UUID) async throws {
        let record = CKRecord(recordType: Self.recordType,
                              recordID: CKRecord.ID(recordName: frame.name, zoneID: Self.zoneID(device)))
        record[Field.session] = frame.session.uuidString
        record[Field.direction] = frame.direction == .toMac ? "toMac" : "toDevice"
        record[Field.seq] = frame.seq
        record[Field.sentAt] = frame.sentAt
        var spill: URL?
        if frame.sealed.count > Self.inlineLimit {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString)")
            try frame.sealed.write(to: url)
            spill = url
            record[Field.asset] = CKAsset(fileURL: url)
            record[Field.sealed] = Data()
        } else {
            record[Field.sealed] = frame.sealed
        }
        defer { if let spill { try? FileManager.default.removeItem(at: spill) } }
        try await mapped {
            let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            if case .failure(let error) = saved[record.recordID] { throw error }
        }
    }

    public func fetchChanges(device: UUID) async throws -> [FrameRecord] {
        let zone = Self.zoneID(device)
        var out: [FrameRecord] = []
        var more = true
        while more {
            let token = zoneTokens[device]
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion],
                          changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await mapped { try await database.recordZoneChanges(inZoneWith: zone, since: token) }
            } catch let error as CKError where error.code == .changeTokenExpired {
                zoneTokens[device] = nil
                continue
            }
            for (_, result) in changes.modificationResultsByID {
                if case .success(let modification) = result, let frame = Self.frame(from: modification.record) {
                    out.append(frame)
                }
            }
            zoneTokens[device] = changes.changeToken
            more = changes.moreComing
        }
        return out.sorted { ($0.session.uuidString, $0.seq) < ($1.session.uuidString, $1.seq) }
    }

    static func frame(from record: CKRecord) -> FrameRecord? {
        guard let sessionText = record[Field.session] as? String, let session = UUID(uuidString: sessionText),
              let directionText = record[Field.direction] as? String,
              let seq = record[Field.seq] as? Int64 else { return nil }
        var sealed = record[Field.sealed] as? Data ?? Data()
        if sealed.isEmpty, let asset = record[Field.asset] as? CKAsset, let url = asset.fileURL {
            sealed = (try? Data(contentsOf: url)) ?? Data()
        }
        guard !sealed.isEmpty else { return nil }
        return FrameRecord(session: session, direction: directionText == "toMac" ? .toMac : .toDevice,
                           seq: seq, sealed: sealed, sentAt: record[Field.sentAt] as? Date ?? Date.distantPast)
    }

    public func changedDevices() async throws -> [UUID] {
        var devices: Set<UUID> = []
        var more = true
        while more {
            let token = databaseToken
            let changes: (modifications: [CKDatabase.DatabaseChange.Modification],
                          deletions: [CKDatabase.DatabaseChange.Deletion],
                          changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await mapped { try await database.databaseChanges(since: token) }
            } catch let error as CKError where error.code == .changeTokenExpired {
                databaseToken = nil
                continue
            }
            for modification in changes.modifications {
                if let device = Self.device(of: modification.zoneID) { devices.insert(device) }
            }
            databaseToken = changes.changeToken
            more = changes.moreComing
        }
        return Array(devices)
    }

    public func delete(_ names: [String], device: UUID) async throws {
        let zone = Self.zoneID(device)
        for start in stride(from: 0, to: names.count, by: 400) {
            let ids = names[start..<min(start + 400, names.count)].map { CKRecord.ID(recordName: $0, zoneID: zone) }
            try await mapped { _ = try await database.modifyRecords(saving: [], deleting: ids) }
        }
    }

    public func deleteZone(device: UUID) async throws {
        zoneTokens[device] = nil
        do {
            try await mapped { _ = try await database.modifyRecordZones(saving: [], deleting: [Self.zoneID(device)]) }
        } catch RelayChannelError.zoneGone {
            // Already gone is gone.
        }
    }

    /// Read each relay zone whole and delete what is older than `date`. Zones stay small —
    /// each end deletes what it has read — so reading one whole is cheap, and it needs no
    /// queryable index in the container's schema.
    public func sweep(olderThan date: Date) async throws {
        let zones = try await mapped { try await database.allRecordZones() }
        for zone in zones {
            guard let device = Self.device(of: zone.zoneID) else { continue }
            var stale: [String] = []
            var token: CKServerChangeToken?
            var more = true
            while more {
                let changes = try await mapped { try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: token) }
                for (id, result) in changes.modificationResultsByID {
                    if case .success(let modification) = result,
                       (modification.record[Field.sentAt] as? Date ?? .distantPast) < date {
                        stale.append(id.recordName)
                    }
                }
                token = changes.changeToken
                more = changes.moreComing
            }
            if !stale.isEmpty { try await delete(stale, device: device) }
        }
    }

    // MARK: The device's side

    /// A silent push whenever the device's zone changes, so a waiting relayed session
    /// looks at once rather than at its next tick (R7). Saved under a stable id, so saving
    /// it again changes nothing. The zone is made first: a subscription to a zone that is
    /// not there is refused.
    public func subscribe(device: UUID) async throws {
        try await ensureZone(device: device)
        let subscription = CKRecordZoneSubscription(zoneID: Self.zoneID(device),
                                                    subscriptionID: Self.subscriptionID(device))
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        try await mapped { _ = try await database.modifySubscriptions(saving: [subscription], deleting: []) }
    }

    public static func subscriptionID(_ device: UUID) -> String { zonePrefix + device.uuidString }

    /// Whether a push is the relay's rather than the mailbox's.
    public static func isRelayPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID?.hasPrefix(zonePrefix) == true
    }

    /// CloudKit's errors, in the words the two ends act on (R7, R12).
    private func mapped<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as CKError {
            throw Self.map(error)
        }
    }

    static func map(_ error: CKError) -> any Error {
        if let seconds = error.retryAfterSeconds { return RelayChannelError.slowDown(seconds) }
        switch error.code {
        case .zoneNotFound, .userDeletedZone: return RelayChannelError.zoneGone
        case .quotaExceeded: return RelayChannelError.full
        case .notAuthenticated, .permissionFailure, .managedAccountRestricted: return RelayChannelError.noAccount
        case .requestRateLimited, .zoneBusy, .serviceUnavailable: return RelayChannelError.slowDown(3)
        case .partialFailure:
            if let first = error.partialErrorsByItemID?.values.first as? CKError { return map(first) }
            return error
        case .changeTokenExpired:
            return error
        default:
            return error
        }
    }
}
#endif

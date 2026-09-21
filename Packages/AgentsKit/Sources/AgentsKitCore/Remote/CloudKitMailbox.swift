import CloudKit
import Foundation

/// The real mailbox: one record per need per device in the CloudKit **private**
/// database, which the Mac and the person's devices share by being the one account.
///
/// The record's name is the need's token under the device's id, so a later post for the
/// same need **replaces** the earlier one rather than sitting beside it, and the
/// subscription's collapse identifier is that same token, so a stale banner is
/// overwritten by the next one for the same need rather than stacking (research §8).
/// Nothing legible is in the record: the headline is the `Envelope`'s ciphertext,
/// base64, and the other fields are ids and flags.
///
/// Two subscriptions per device, because one push cannot be both: an item with
/// `alert` set is pushed with mutable content so `RemoteNotify` can open the envelope
/// and put the words in the banner; a silent item — a move that must not buzz, or a
/// withdrawal — is pushed content-available so the app wakes and shows or removes a
/// local notification itself. The silent half is best effort by Apple's design, which
/// is why the foreground sweep exists.
public struct CloudKitMailbox: Mailbox {
    public static let containerID = "iCloud.com.alexecollins.agents"
    public static let zoneName = "mailbox"
    public static let recordType = "Item"

    public enum Field {
        public static let device = "device"
        public static let needToken = "needToken"
        public static let need = "need"
        public static let envelope = "envelope"
        public static let alert = "alert"
        public static let withdrawn = "withdrawn"
        public static let postedAt = "postedAt"
        /// What a push may carry: everything a device needs to show or remove a banner
        /// without a round trip.
        public static let pushed = [needToken, need, envelope, alert, withdrawn]
    }

    private let database: CKDatabase
    private let zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    public init(container: CKContainer = CKContainer(identifier: CloudKitMailbox.containerID)) {
        database = container.privateCloudDatabase
    }

    /// The zone, made once. Safe to call again.
    public func prepare() async throws {
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
    }

    public static func recordID(device: UUID, token: String, zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(device.uuidString)/\(token)", zoneID: zone)
    }

    public func post(_ item: MailboxItem) async throws {
        let id = Self.recordID(device: item.device, token: item.needID.token, zone: zone)
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record[Field.device] = item.device.uuidString
        record[Field.needToken] = item.needID.token
        record[Field.need] = String(decoding: try JSONEncoder().encode(item.needID), as: UTF8.self)
        record[Field.envelope] = item.envelope.map { String(decoding: try! JSONEncoder().encode($0), as: UTF8.self) } ?? ""
        record[Field.alert] = item.alert ? 1 : 0
        record[Field.withdrawn] = item.envelope == nil ? 1 : 0
        record[Field.postedAt] = item.postedAt
        // All keys, so the record is replaced whole whatever it held.
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    public func empty(device: UUID) async throws {
        let query = CKQuery(recordType: Self.recordType,
                            predicate: NSPredicate(format: "%K == %@", Field.device, device.uuidString))
        var cursor: CKQueryOperation.Cursor?
        var ids: [CKRecord.ID] = []
        repeat {
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let cursor {
                page = try await database.records(continuingMatchFrom: cursor, desiredKeys: [])
            } else {
                page = try await database.records(matching: query, inZoneWith: zone, desiredKeys: [])
            }
            ids += page.matchResults.map { $0.0 }
            cursor = page.queryCursor
        } while cursor != nil
        guard !ids.isEmpty else { return }
        _ = try await database.modifyRecords(saving: [], deleting: ids)
    }

    // MARK: The device's side

    /// The two subscriptions for one device, saved under stable ids so saving them
    /// again changes nothing. Called by the Remote once it is approved.
    public func subscribe(device: UUID) async throws {
        let mine = NSPredicate(format: "%K == %@", Field.device, device.uuidString)
        let loud = CKQuerySubscription(recordType: Self.recordType,
                                       predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                                           mine, NSPredicate(format: "%K == 1", Field.alert)]),
                                       subscriptionID: "loud-\(device.uuidString)",
                                       options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let loudInfo = CKSubscription.NotificationInfo()
        loudInfo.shouldSendMutableContent = true
        loudInfo.soundName = "default"
        loudInfo.title = "An agent needs you"
        loudInfo.desiredKeys = Field.pushed
        loudInfo.collapseIDKey = Field.needToken
        loud.notificationInfo = loudInfo

        let quiet = CKQuerySubscription(recordType: Self.recordType,
                                        predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                                            mine, NSPredicate(format: "%K == 0", Field.alert)]),
                                        subscriptionID: "quiet-\(device.uuidString)",
                                        options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let quietInfo = CKSubscription.NotificationInfo()
        quietInfo.shouldSendContentAvailable = true
        quietInfo.desiredKeys = Field.pushed
        quietInfo.collapseIDKey = Field.needToken
        quiet.notificationInfo = quietInfo

        loud.zoneID = zone
        quiet.zoneID = zone
        _ = try await database.modifySubscriptions(saving: [loud, quiet], deleting: [])
    }

    /// What a push said, read off the notification's fields without a round trip.
    public struct Pushed: Sendable {
        public var needID: NeedID
        public var token: String
        public var envelope: Envelope?
        public var alert: Bool
        public var withdrawn: Bool
    }

    public static func pushed(from userInfo: [AnyHashable: Any]) -> Pushed? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let fields = notification.recordFields,
              let token = fields[Field.needToken] as? String,
              let needText = fields[Field.need] as? String,
              let needID = try? JSONDecoder().decode(NeedID.self, from: Data(needText.utf8))
        else { return nil }
        let envelope = (fields[Field.envelope] as? String)
            .flatMap { $0.isEmpty ? nil : try? JSONDecoder().decode(Envelope.self, from: Data($0.utf8)) }
        return Pushed(needID: needID, token: token, envelope: envelope,
                      alert: (fields[Field.alert] as? Int) == 1,
                      withdrawn: (fields[Field.withdrawn] as? Int) == 1)
    }
}

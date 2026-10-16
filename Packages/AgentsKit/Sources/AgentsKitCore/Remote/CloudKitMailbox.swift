// Not on Linux: the server build of agentsd has no CloudKit and no use for this (037).
#if canImport(CloudKit)
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
        /// The Needs you count across the hosts (#1163), and when it was counted, in
        /// seconds since 1970: a number survives a push's fields where a date may not.
        public static let waiting = "waiting"
        public static let countedAt = "countedAt"
        /// What a push may carry: everything a device needs to show or remove a banner,
        /// and to set its count, without a round trip.
        public static let pushed = [needToken, need, envelope, alert, withdrawn, waiting, countedAt]
    }

    /// The `needToken` of a device's count record (#1163): one per device, replaced as the
    /// count moves, and pushed quietly.
    public static let countToken = "count"

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
        if let waiting = item.waiting {
            record[Field.waiting] = waiting
            record[Field.countedAt] = item.postedAt.timeIntervalSince1970
        }
        // All keys, so the record is replaced whole whatever it held.
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    /// The device's count (#1163): one record under `countToken`, with no alert, so the
    /// quiet subscription pushes it content-available and the app wakes to write it.
    public func post(_ count: MailboxCount) async throws {
        let id = Self.recordID(device: count.device, token: Self.countToken, zone: zone)
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record[Field.device] = count.device.uuidString
        record[Field.needToken] = Self.countToken
        record[Field.need] = ""
        record[Field.envelope] = ""
        record[Field.alert] = 0
        record[Field.withdrawn] = 0
        record[Field.postedAt] = count.countedAt
        record[Field.waiting] = count.waiting
        record[Field.countedAt] = count.countedAt.timeIntervalSince1970
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    // MARK: The device's side

    /// The two subscriptions for one device, saved under stable ids so saving them
    /// again changes nothing. Called by the Remote once it has announced.
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
        /// The whole count as the push left (#1163), nil from an older relay.
        public var count: AttentionCount?
    }

    public static func pushed(from userInfo: [AnyHashable: Any]) -> Pushed? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let fields = notification.recordFields,
              let token = fields[Field.needToken] as? String, token != countToken,
              let needText = fields[Field.need] as? String,
              let needID = try? JSONDecoder().decode(NeedID.self, from: Data(needText.utf8))
        else { return nil }
        let envelope = (fields[Field.envelope] as? String)
            .flatMap { $0.isEmpty ? nil : try? JSONDecoder().decode(Envelope.self, from: Data($0.utf8)) }
        return Pushed(needID: needID, token: token, envelope: envelope,
                      alert: (fields[Field.alert] as? Int) == 1,
                      withdrawn: (fields[Field.withdrawn] as? Int) == 1,
                      count: count(in: fields))
    }

    /// A count push (#1163): the device's count record, and nothing about any need.
    public static func pushedCount(from userInfo: [AnyHashable: Any]) -> AttentionCount? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let fields = notification.recordFields,
              fields[Field.needToken] as? String == countToken else { return nil }
        return count(in: fields)
    }

    private static func count(in fields: [String: Any]) -> AttentionCount? {
        guard let waiting = (fields[Field.waiting] as? NSNumber)?.intValue,
              let seconds = (fields[Field.countedAt] as? NSNumber)?.doubleValue else { return nil }
        return AttentionCount(waiting: waiting, countedAt: Date(timeIntervalSince1970: seconds))
    }
}
#endif

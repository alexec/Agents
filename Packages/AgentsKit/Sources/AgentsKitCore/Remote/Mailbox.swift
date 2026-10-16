import Foundation

/// Something waiting for one device, wherever that device is.
///
/// One item per need per device: a sealed headline and whether the person may be buzzed,
/// or a withdrawal naming only the need. Keyed so that a later item for the same need
/// replaces the earlier one — a stale banner is overwritten by the next, never stacked.
public struct MailboxItem: Hashable, Sendable, Codable {
    public var needID: NeedID
    public var device: UUID
    /// `nil` is a withdrawal: the need is over, or has moved elsewhere.
    public var envelope: Envelope?
    public var alert: Bool
    public var postedAt: Date
    /// How many sessions need the person across the hosts as this was posted (#1163), so
    /// the device writes the count as the truth rather than guessing from one need. Nil
    /// where nobody counted.
    public var waiting: Int?

    public init(needID: NeedID, device: UUID, envelope: Envelope?, alert: Bool, postedAt: Date, waiting: Int? = nil) {
        self.needID = needID
        self.device = device
        self.envelope = envelope
        self.alert = alert
        self.postedAt = postedAt
        self.waiting = waiting
    }
}

/// The Needs you count for one device (#1163): what its widget and badge show, posted
/// whenever it moves, whether or not a need went to that device. A need answered at the
/// Mac, or a finish nobody has read, moves it with no need to post.
public struct MailboxCount: Hashable, Sendable, Codable {
    public var device: UUID
    public var waiting: Int
    public var countedAt: Date

    public init(device: UUID, waiting: Int, countedAt: Date) {
        self.device = device
        self.waiting = waiting
        self.countedAt = countedAt
    }
}

/// The channel that reaches a device the LAN cannot: a place the Mac posts to and the
/// device is told about. The real one is CloudKit's private database with a push
/// subscription; the fake is what every test runs against, because the property under
/// test is what was posted and to whom, never how it travelled.
public protocol Mailbox: Sendable {
    func post(_ item: MailboxItem) async throws
    /// One device's count, in place of the last (#1163).
    func post(_ count: MailboxCount) async throws
}

public extension Mailbox {
    /// A mailbox with nowhere to put a count drops it: the device counts for itself
    /// when it next connects.
    func post(_ count: MailboxCount) async throws {}
}

/// A mailbox that goes nowhere, and remembers everything. For tests.
public actor FakeMailbox: Mailbox {
    public private(set) var posted: [MailboxItem] = []
    public private(set) var counts: [MailboxCount] = []

    public init() {}

    public func post(_ item: MailboxItem) async throws {
        posted.append(item)
    }

    public func post(_ count: MailboxCount) async throws {
        counts.append(count)
    }

    /// What one device would find waiting, latest per need.
    public func waiting(for device: UUID) -> [MailboxItem] {
        var latest: [NeedID: MailboxItem] = [:]
        for item in posted where item.device == device { latest[item.needID] = item }
        return latest.values.sorted { $0.postedAt < $1.postedAt }
    }
}

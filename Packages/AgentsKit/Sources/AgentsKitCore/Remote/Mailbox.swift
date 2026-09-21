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

    public init(needID: NeedID, device: UUID, envelope: Envelope?, alert: Bool, postedAt: Date) {
        self.needID = needID
        self.device = device
        self.envelope = envelope
        self.alert = alert
        self.postedAt = postedAt
    }
}

/// The channel that reaches a device the LAN cannot: a place the Mac posts to and the
/// device is told about. The real one is CloudKit's private database with a push
/// subscription; the fake is what every test runs against, because the property under
/// test is what was posted and to whom, never how it travelled.
public protocol Mailbox: Sendable {
    func post(_ item: MailboxItem) async throws
    /// Everything waiting for one device, discarded unread. What revoking a device
    /// does, and the reason revoking is deletion rather than a flag (FR-021).
    func empty(device: UUID) async throws
}

/// A mailbox that goes nowhere, and remembers everything. For tests.
public actor FakeMailbox: Mailbox {
    public private(set) var posted: [MailboxItem] = []
    public private(set) var emptied: [UUID] = []

    public init() {}

    public func post(_ item: MailboxItem) async throws {
        posted.append(item)
    }

    public func empty(device: UUID) async throws {
        emptied.append(device)
        posted.removeAll { $0.device == device }
    }

    /// What one device would find waiting, latest per need.
    public func waiting(for device: UUID) -> [MailboxItem] {
        var latest: [NeedID: MailboxItem] = [:]
        for item in posted where item.device == device { latest[item.needID] = item }
        return latest.values.sorted { $0.postedAt < $1.postedAt }
    }
}

/// No mailbox at all: what a daemon has until the bridge hands it one, and what a test
/// that is not about mailboxes runs with.
public struct NoMailbox: Mailbox {
    public init() {}
    public func post(_ item: MailboxItem) async throws {}
    public func empty(device: UUID) async throws {}
}

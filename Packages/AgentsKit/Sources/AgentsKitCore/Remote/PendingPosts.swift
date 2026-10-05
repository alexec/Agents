import Foundation

/// The relay's notices that did not post, kept to try again (#172).
///
/// A post that failed (iCloud unreachable, a CloudKit throttle) used to be logged and
/// dropped, so a phone never heard of a need raised while iCloud was away, nor of its
/// withdrawal, and kept a stale notice. Kept here instead, one per device and need: a
/// later word about the same need replaces the earlier one, so a retry never posts a need
/// that has since been withdrawn, and a later post that succeeded takes it out. Bounded:
/// past `limit` the oldest is let go, and said.
public struct PendingPosts: Sendable {
    public struct Key: Hashable, Sendable {
        public var device: UUID
        public var needID: NeedID
    }

    public let limit: Int
    private var items: [Key: MailboxItem] = [:]
    private var order: [Key] = []

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public static func key(_ item: MailboxItem) -> Key { Key(device: item.device, needID: item.needID) }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Keep `item` to post again, in place of anything kept for the same need. Returns
    /// what was let go to stay within the limit.
    @discardableResult
    public mutating func keep(_ item: MailboxItem) -> MailboxItem? {
        let key = Self.key(item)
        if let kept = items[key], kept.postedAt > item.postedAt { return nil }
        if items.updateValue(item, forKey: key) == nil { order.append(key) }
        guard order.count > limit else { return nil }
        let oldest = order.removeFirst()
        return items.removeValue(forKey: oldest)
    }

    /// Posted: what was waiting for that need, made no later than `item`, is over. A newer
    /// item kept meanwhile is left, so it is posted too.
    public mutating func posted(_ item: MailboxItem) {
        let key = Self.key(item)
        guard let kept = items[key], kept.postedAt <= item.postedAt else { return }
        items[key] = nil
        order.removeAll { $0 == key }
    }

    /// What is waiting, oldest first.
    public var waiting: [MailboxItem] { order.compactMap { items[$0] } }

    /// The version still owed for this need. A retry snapshot may have been superseded
    /// by a withdrawal while another mailbox post was suspended.
    public func current(_ item: MailboxItem) -> MailboxItem? {
        guard let current = items[Self.key(item)], current.postedAt >= item.postedAt else { return nil }
        return current
    }
}

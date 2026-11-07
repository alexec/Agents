import Foundation

/// At most `limit` values, and at most `costLimit` of their cost (#3650), the one least
/// recently read or written let go first (#175).
///
/// For what a client keeps only so as not to ask again — a page's pictures — and which
/// would otherwise grow with everything ever looked at. Small by design: a lookup is a
/// dictionary read, and only a write past the limit walks the keys.
public struct LRUCache<Key: Hashable, Value> {
    public let limit: Int
    public let costLimit: Int
    private var values: [Key: (value: Value, used: UInt64, cost: Int)] = [:]
    private var clock: UInt64 = 0
    /// The cost of every value held, as it was set.
    public private(set) var cost = 0

    public init(limit: Int, costLimit: Int = .max) {
        self.limit = max(1, limit)
        self.costLimit = costLimit
    }

    public var count: Int { values.count }
    public var keys: [Key] { Array(values.keys) }

    /// The value, counted as used.
    public mutating func value(for key: Key) -> Value? {
        guard let held = values[key] else { return nil }
        clock += 1
        values[key] = (held.value, clock, held.cost)
        return held.value
    }

    /// The value, without counting it as used.
    public func peek(_ key: Key) -> Value? { values[key]?.value }

    /// Kept with its cost: what counts towards `costLimit`, such as a picture's bytes. A
    /// value that costs more than `costLimit` on its own is not kept.
    public mutating func set(_ value: Value, for key: Key, cost: Int = 0) {
        clock += 1
        remove(key)
        values[key] = (value, clock, cost)
        self.cost += cost
        while values.count > limit || self.cost > costLimit,
              let oldest = values.min(by: { $0.value.used < $1.value.used })?.key {
            remove(oldest)
        }
    }

    @discardableResult
    public mutating func remove(_ key: Key) -> Value? {
        guard let held = values.removeValue(forKey: key) else { return nil }
        cost -= held.cost
        return held.value
    }

    public mutating func removeAll() {
        values.removeAll()
        cost = 0
    }
}

extension LRUCache: Sendable where Key: Sendable, Value: Sendable {}

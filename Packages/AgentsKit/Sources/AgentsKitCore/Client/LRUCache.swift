import Foundation

/// At most `limit` values, the one least recently read or written let go first (#175).
///
/// For what a client keeps only so as not to ask again — a page's pictures — and which
/// would otherwise grow with everything ever looked at. Small by design: a lookup is a
/// dictionary read, and only a write past the limit walks the keys.
public struct LRUCache<Key: Hashable, Value> {
    public let limit: Int
    private var values: [Key: (value: Value, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public var count: Int { values.count }
    public var keys: [Key] { Array(values.keys) }

    /// The value, counted as used.
    public mutating func value(for key: Key) -> Value? {
        guard let held = values[key] else { return nil }
        clock += 1
        values[key] = (held.value, clock)
        return held.value
    }

    /// The value, without counting it as used.
    public func peek(_ key: Key) -> Value? { values[key]?.value }

    public mutating func set(_ value: Value, for key: Key) {
        clock += 1
        values[key] = (value, clock)
        guard values.count > limit,
              let oldest = values.min(by: { $0.value.used < $1.value.used })?.key else { return }
        values[oldest] = nil
    }

    @discardableResult
    public mutating func remove(_ key: Key) -> Value? {
        values.removeValue(forKey: key)?.value
    }

    public mutating func removeAll() {
        values.removeAll()
    }
}

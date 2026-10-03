import Foundation

/// A log line that would be said again and again, said once and then counted (#168).
///
/// A caller turned away every five seconds wrote the same line 25,000 times in two and a
/// half days, two thirds of the daemon's log, and the log rolls at 4 MB: it pushed out the
/// history anybody would want. Now the first time for a key is said; after that it is
/// counted, and said again with the count at most once every `every`.
public struct RepeatedNotice: Sendable {
    public enum Say: Equatable, Sendable {
        /// The first time for this key, or the first after it was forgotten.
        case first
        /// `times` more since `since`, when it was last said.
        case again(times: Int, since: Date)
    }

    public let every: TimeInterval
    /// How many keys are remembered: a pid that never comes back is forgotten.
    public let keep: Int
    private var seen: [String: (said: Date, more: Int)] = [:]

    public init(every: TimeInterval = 3600, keep: Int = 256) {
        self.every = every
        self.keep = keep
    }

    /// What to say for `key` at `now`, or nil to say nothing.
    public mutating func note(_ key: String, at now: Date) -> Say? {
        guard let last = seen[key] else {
            forget(before: now)
            seen[key] = (now, 0)
            return .first
        }
        if now.timeIntervalSince(last.said) < every {
            seen[key] = (last.said, last.more + 1)
            return nil
        }
        seen[key] = (now, 0)
        return .again(times: last.more + 1, since: last.said)
    }

    /// Room for a new key: what was last said longer ago than `every` goes, and while
    /// that is not enough, the oldest.
    private mutating func forget(before now: Date) {
        guard seen.count >= keep else { return }
        seen = seen.filter { now.timeIntervalSince($0.value.said) < every }
        while seen.count >= keep, let oldest = seen.min(by: { $0.value.said < $1.value.said })?.key {
            seen[oldest] = nil
        }
    }
}

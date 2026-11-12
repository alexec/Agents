import Foundation

/// The PRs the agents worked on that landed, by the hour and the day, by repository (#4596):
/// `velocity/history`, counted on each ask from the host's lineage store, shaped as
/// ``UsageHistory`` is so the same chart code draws it.
public struct VelocityHistory: Codable, Sendable, Hashable {
    /// `yyyy-MM-ddTHH` in the host's own calendar, then repository (`github:alexec/agents`).
    public var hours: [String: [String: VelocityBucket]]
    /// `yyyy-MM-dd` in the host's own calendar, then repository.
    public var days: [String: [String: VelocityBucket]]
    /// The host's hour when this was read.
    public var now: String
    /// The zone those stamps are in, an IANA identifier (#1267). Nil from a host too old
    /// to say, read as the viewer's own.
    public var timeZone: String?

    public init(hours: [String: [String: VelocityBucket]] = [:],
                days: [String: [String: VelocityBucket]] = [:], now: String = "", timeZone: String? = nil) {
        self.hours = hours
        self.days = days
        self.now = now
        self.timeZone = timeZone
    }
}

/// The PRs that landed in one hour or day in one repository: `merged` is every one, merged
/// reverts included; `reverted` is the merged reverts among them.
public struct VelocityBucket: Codable, Sendable, Hashable {
    public var merged: Int
    public var reverted: Int

    public init(merged: Int = 0, reverted: Int = 0) {
        self.merged = merged
        self.reverted = reverted
    }
}

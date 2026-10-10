import Foundation

/// One detail a kind of event carries, as the catalogue describes it (073): whether a
/// wait or a trigger may narrow the event by it, and, for one that may, the values it
/// can have.
///
/// Every detail is shown (the events page, a woken agent's message, a workflow agent's
/// prompt); only a few are filters (#574): `branch` on `branch.moved` and `why` on
/// `person.away` and `person.back`. What lets `parse` refuse `agent.finished` narrowed
/// by `outcome`, or `why: asleep`, rather than accept a filter nobody uses.
public struct EventDetail: Hashable, Sendable {
    public var key: String
    /// Whether a wait or a trigger may narrow the event by it.
    public var isFilter: Bool
    /// The values a filter on it may have, or `nil` when any value will do.
    public var values: [String]?

    public init(_ key: String, isFilter: Bool = false, values: [String]? = nil) {
        self.key = key
        self.isFilter = isFilter
        self.values = values
    }
}

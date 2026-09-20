import Foundation

/// The record of a need having been put in front of the person somewhere.
///
/// One `Delivery` per outstanding `Need`, created when the ladder first answers for it
/// and destroyed when the need is met — nothing outlives what it belongs to. That is what
/// makes FR-003, at most one live notification per need across every surface, a thing
/// that can be checked rather than hoped.
///
/// Changing `to` is a **move**, and a move does not touch `alertedAt` unless the re-alert
/// interval has passed. That sentence is the whole of FR-018: a need that follows the
/// person from the Mac to the iPad to the phone is shown on each, and buzzes on the first.
public struct Delivery: Hashable, Sendable {
    public var needID: NeedID
    /// Where it should be showing. `nil` means nowhere can be reached, or the person is
    /// watching the conversation and nothing should show.
    public var to: Surface?
    /// When the person was last actually buzzed about this need.
    public var alertedAt: Date
    /// How many times. Read by SC-006's assertion, and by nothing else.
    public var alertCount: Int

    public init(needID: NeedID, to: Surface?, alertedAt: Date, alertCount: Int) {
        self.needID = needID
        self.to = to
        self.alertedAt = alertedAt
        self.alertCount = alertCount
    }
}

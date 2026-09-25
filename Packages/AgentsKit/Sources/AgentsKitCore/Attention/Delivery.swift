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
///
/// `Codable` since 025, because this is written down now: the daemon restarts on every
/// build of this app, and a delivery lost with it is a person alerted a second time about
/// something that has not changed. What is stored is these four fields and nothing more —
/// **no headline, no title, no tool name**. What the need *says* lives on `Need`, which is
/// derived every time it is asked for; a second copy of it on disk would be the one thing
/// 021's FR-001 forbids.
public struct Delivery: Hashable, Sendable, Codable {
    public var needID: NeedID
    /// Where it should be showing. `nil` means nowhere can be reached, or the person is
    /// watching the conversation and nothing should show.
    public var to: Surface?
    /// When the person was last actually buzzed about this need.
    public var alertedAt: Date
    /// How many times. Read by SC-006's assertion, and by nothing else.
    public var alertCount: Int
    /// Set while a banner decided for a device has not yet been handed to anything that
    /// can carry it, holding whether it was to buzz. `nil` once it has gone, and always
    /// for a delivery to the Mac.
    ///
    /// On disk with the rest, so a banner decided while the bridge was away — or the
    /// daemon before it — still goes when a carrier arrives. Without it the delivery
    /// said "shown on the phone" about a banner nothing had carried, and nothing would
    /// ever post it again: the next decision sees the same destination and moves nothing.
    public var unsentAlert: Bool?

    public init(needID: NeedID, to: Surface?, alertedAt: Date, alertCount: Int,
                unsentAlert: Bool? = nil) {
        self.needID = needID
        self.to = to
        self.alertedAt = alertedAt
        self.alertCount = alertCount
        self.unsentAlert = unsentAlert
    }
}

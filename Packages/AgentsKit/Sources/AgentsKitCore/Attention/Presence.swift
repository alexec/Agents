import Foundation

/// What the daemon believes about where the person is: one record per connected surface,
/// held in memory and never written down. What a person is doing right now is not a fact
/// worth keeping.
///
/// `heardAt` is stamped by the daemon's own clock and never by the sender, by requirement
/// rather than convenience: a device with a fast clock must not win every race, and a
/// report arriving over a live connection needs no timestamp from the far end.
///
/// The three derived properties take `now` and the thresholds as parameters rather than
/// reading a clock, which is what lets every rule about them be exhausted in a unit test
/// with no phone in the room.
public struct Presence: Hashable, Sendable {
    public var surface: Surface
    /// The conversation on screen, if any.
    public var watching: UUID?
    /// In front of the person: frontmost on the Mac, foreground and unlocked on a device.
    public var active: Bool
    public var heardAt: Date

    public init(surface: Surface, watching: UUID?, active: Bool, heardAt: Date) {
        self.surface = surface
        self.watching = watching
        self.active = active
        self.heardAt = heardAt
    }

    /// A surface not heard from is not evidence of anything.
    public func isRecent(now: Date, thresholds: AttentionThresholds) -> Bool {
        now.timeIntervalSince(heardAt) < thresholds.deviceStaleness
    }

    /// The Mac rung: in front of the person, and touched recently enough to still be.
    public func isHere(now: Date, thresholds: AttentionThresholds) -> Bool {
        active && now.timeIntervalSince(heardAt) < thresholds.macIdle
    }

    /// The silence rung: this conversation, in front of the person, on this surface.
    public func isWatching(_ agentID: UUID) -> Bool {
        active && watching == agentID
    }
}

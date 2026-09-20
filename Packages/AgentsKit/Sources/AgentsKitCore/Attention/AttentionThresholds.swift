import Foundation

/// The four numbers the routing of a notification turns on, in one place.
///
/// Together so they move together or not at all: each is a judgement about how long a
/// person's silence means what it seems to mean, and a change to one that leaves the
/// others behind is a set of thresholds that no longer describe the same person.
/// Injectable, so every test names its own and none of them sleeps; no caller anywhere
/// may write a literal duration instead of reading one of these.
///
/// The figures are research §9's. `macIdle` is FR-007: how long the Mac may go untouched
/// before the person is taken to be away from it. `deviceStaleness` is FR-008: how long
/// since a device was heard from before it stops being evidence of where the person is.
/// `settlingPause` is FR-014: how long a person at the Mac is given to look before
/// anything is delivered to them. `reAlertInterval` is FR-018: how often the person may
/// be buzzed afresh about one need as it moves between surfaces.
public struct AttentionThresholds: Hashable, Sendable {
    public var macIdle: TimeInterval
    public var deviceStaleness: TimeInterval
    public var settlingPause: TimeInterval
    public var reAlertInterval: TimeInterval

    public init(macIdle: TimeInterval = 120,
                deviceStaleness: TimeInterval = 600,
                settlingPause: TimeInterval = 20,
                reAlertInterval: TimeInterval = 300) {
        self.macIdle = macIdle
        self.deviceStaleness = deviceStaleness
        self.settlingPause = settlingPause
        self.reAlertInterval = reAlertInterval
    }

    public static let standard = AttentionThresholds()
}

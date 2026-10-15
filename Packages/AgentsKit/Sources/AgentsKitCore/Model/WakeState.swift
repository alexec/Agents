import Foundation

extension DaemonAPI {
    /// Why the Mac is, or is not, being kept awake.
    ///
    /// A derived fact no window can work out for itself: the agent half it can see, but
    /// the power half is knowable only to the daemon, and a second decider is the
    /// disease 019 was written to cure. Broadcast when it moves and fetchable on
    /// connect, exactly as `CostState` is.
    ///
    /// This is also where the count lives. The power assertion's own reason string
    /// deliberately carries no number — it is written once, when the verdict moves, and
    /// a count in it goes stale the moment a second agent starts. This is re-sent
    /// freely, so it can afford to be exact.
    public struct WakeState: Codable, Hashable, Sendable {
        /// The assertion is held right now (FR-015).
        public var isHolding: Bool
        /// How many agents are `starting` or `running`. Zero when nothing is working.
        public var agentsInFlight: Int
        /// Work **is** in flight, but the battery floor released the hold (FR-016).
        ///
        /// The field that makes "nothing is running" and "running, but your battery is
        /// low" different sentences. Without it the person learns nothing from either.
        public var heldBackByBattery: Bool
        /// The charge behind the two flags above, for the words. Nil on a Mac with no
        /// battery.
        public var batteryPercent: Int?
        /// When the current hold was taken. Nil when not holding.
        public var since: Date?
        /// When a grace hold will end. Nil while an agent is working, and whenever
        /// the Mac is not being held. An older window that does not know the field
        /// still reads the rest.
        public var graceUntil: Date?
        /// The hold is for the power, not for an agent: the Mac is on power and the
        /// person chose to keep it awake there (#992). False when not holding.
        public var onPower: Bool

        public init(isHolding: Bool,
                    agentsInFlight: Int,
                    heldBackByBattery: Bool,
                    batteryPercent: Int?,
                    since: Date?,
                    graceUntil: Date? = nil,
                    onPower: Bool = false) {
            self.isHolding = isHolding
            self.agentsInFlight = agentsInFlight
            self.heldBackByBattery = heldBackByBattery
            self.batteryPercent = batteryPercent
            self.since = since
            self.graceUntil = graceUntil
            self.onPower = onPower
        }

        /// A daemon from before #992 sends no `onPower`: it never holds for the power.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isHolding = try c.decode(Bool.self, forKey: .isHolding)
            agentsInFlight = try c.decode(Int.self, forKey: .agentsInFlight)
            heldBackByBattery = try c.decode(Bool.self, forKey: .heldBackByBattery)
            batteryPercent = try c.decodeIfPresent(Int.self, forKey: .batteryPercent)
            since = try c.decodeIfPresent(Date.self, forKey: .since)
            graceUntil = try c.decodeIfPresent(Date.self, forKey: .graceUntil)
            onPower = try c.decodeIfPresent(Bool.self, forKey: .onPower) ?? false
        }

        /// Nothing held and nothing working. What a window shows before it has heard
        /// anything, and what it goes back to.
        public static let idle = WakeState(isHolding: false, agentsInFlight: 0,
                                           heldBackByBattery: false,
                                           batteryPercent: nil, since: nil)

        /// Whether there is anything at all to say. Nil `wakeState` and this being
        /// false are drawn the same way — as nothing (FR-015).
        ///
        /// `isHolding` and `heldBackByBattery` are never both true: one means the Mac
        /// is being kept awake, the other means it would be but for the battery.
        public var hasSomethingToSay: Bool { isHolding || heldBackByBattery }
    }
}

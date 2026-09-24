import Foundation

/// Whether the Mac should be held awake, and if not, why not.
public enum WakeVerdict: Hashable, Sendable {
    /// Hold it. A turn is in flight and the power allows.
    case hold
    /// Nothing is computing. The ordinary case, and the one the person never sees.
    case idle
    /// A turn **is** in flight, but the battery is at or below the floor (FR-010).
    ///
    /// Kept apart from `idle` for one reason and one only: FR-016 requires that the
    /// person be told these are different situations. "Nothing is running" and
    /// "running, but your battery is low" must not read the same, or they learn
    /// nothing from either.
    ///
    /// So do not collapse this into `idle` because the two lead to the same call on
    /// `Wakefulness`. They lead to different words.
    case batteryTooLow(percent: Int)
}

public enum Wake {
    /// The reserve below which a laptop on battery is left to sleep, even mid-turn.
    ///
    /// One figure, not a setting. The spec's Assumptions say why: the hold is narrow
    /// enough not to need an escape hatch, and if that proves wrong it is a follow-up
    /// rather than a prerequisite.
    public static let batteryFloorPercent = 20

    /// The whole of this feature's logic, as one pure function over its two inputs.
    ///
    /// Pure so it can be exhausted in tests with no daemon, no agent and no hardware —
    /// which is the point of the `PowerSource` seam.
    public static func verdict(workInFlight: Bool, power: PowerReading) -> WakeVerdict {
        // FR-001/FR-002: nothing computing, nothing held. Asked first because it is
        // the common case and because no power reading can override it — a Mac plugged
        // into the wall with no agents working is still an ordinary Mac.
        guard workInFlight else { return .idle }
        // FR-009: on mains, the charge is not our business.
        if power.isOnMains { return .hold }
        // FR-012: a Mac with no battery behaves as though on mains. Reached when
        // something is providing battery power but no source would give a reading, so
        // it is not quite dead code even on a desktop.
        guard let percent = power.batteryPercent else { return .hold }
        // FR-010, and the floor is **inclusive**: the requirement says "reaches or
        // falls below", so 20 is too low and only 21 and up hold. Strictly greater
        // than, therefore — the easiest line in this file to get subtly wrong, and the
        // reason `WakeVerdictTests` walks both sides of it.
        return percent > batteryFloorPercent ? .hold : .batteryTooLow(percent: percent)
    }
}

extension WakeVerdict {
    /// Whether this verdict means the assertion is held. The single place the three
    /// cases are collapsed to the two states `Wakefulness` has.
    public var isHolding: Bool {
        if case .hold = self { return true }
        return false
    }
}

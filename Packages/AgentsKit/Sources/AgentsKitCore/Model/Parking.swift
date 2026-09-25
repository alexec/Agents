import Foundation

/// A chat the person has put down on purpose, to come back to (040).
///
/// Not a state and not an ending: it is kept beside both, so taking it away puts the
/// chat back exactly where its ending says. Two values rather than a date and a flag,
/// because a date and a flag can say both at once.
public enum Parking: Codable, Hashable, Sendable {
    /// Parked while a turn was in flight. The turn runs to its end, and the daemon makes
    /// this `parked` the moment it does. Until then the chat is grouped as it would be
    /// without it.
    case whenTurnEnds(since: Date)
    /// Parked. The chat sits under Parked until the person unparks it or prompts it.
    case parked(at: Date)

    public var isParked: Bool {
        if case .parked = self { return true }
        return false
    }

    /// When it was parked, if it is.
    public var parkedAt: Date? {
        if case .parked(let at) = self { return at }
        return nil
    }
}

/// Which of the two buttons a chat offers, decided once for every device (040, FR-012).
public enum ParkAction: Sendable, Hashable {
    case park
    case unpark
}

public extension Agent {
    /// `unpark` for a chat parked or marked to park, `park` for any other chat that is
    /// not archived, and nothing for an archived one.
    var parkAction: ParkAction? {
        if parking != nil { return .unpark }
        return state == .archived ? nil : .park
    }
}

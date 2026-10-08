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

/// Where an agent asked, on the call that ended its turn, to be put once the turn is
/// over. Parking keeps the chat in the list, to come back to. Archiving is for a
/// workflow's run alone, and only when the workflow's author allowed it with
/// `when-done:` (#433): a session a person started stays where they can open it and
/// see whether it was useful.
public enum AfterTurn: String, Codable, Hashable, Sendable {
    case park
    case archive

    /// What an agent sent, if it is one of the two. Anything else is refused rather
    /// than read as nothing: an ask the agent thinks it made and did not is worse than
    /// being told.
    public init?(wire: String) {
        self.init(rawValue: wire.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether it may go with an ending. Parking keeps the chat to come back to, so
    /// `partly_done` may too — but not an ending that asks the person for something
    /// (a parked chat asks for nothing), nor `blocked` (a parked chat never wakes,
    /// and a blocked one has to). Archiving puts the work out of sight, so only an
    /// ending with nothing left in it goes with it.
    public func goes(with outcome: WorkOutcome) -> Bool {
        switch (self, outcome) {
        case (.park, .done), (.park, .nothingToDo), (.park, .partlyDone): return true
        case (.archive, .done), (.archive, .nothingToDo): return true
        default: return false
        }
    }

    /// Said when `goes(with:)` is false, by both the service and the daemon.
    public var refusal: String {
        switch self {
        case .park: "Nothing was recorded: park only goes with done, nothing_to_do or partly_done."
        case .archive: "Nothing was recorded: archive only goes with done or nothing_to_do."
        }
    }

    /// Said when `afterwards` is neither.
    public static let unknown = "Nothing was recorded: afterwards has to be park or archive."

    /// Said when an agent asks to archive itself and its workflow did not allow it, or
    /// no workflow started it.
    public static let archiveNotAllowed = """
        Nothing was recorded: only a workflow's run can archive itself, and only when \
        its workflow says when-done: archive-allowed or archive. Leave afterwards out, \
        or say park.
        """
}

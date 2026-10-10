import Foundation

/// An agent's ask that its session be archived, waiting for the person's OK (#584).
///
/// A mark on the row, like unread, and never a group: the session stays where its
/// ending puts it (usually Done) until the person archives it. Kept beside the state
/// and the ending and replacing neither, so taking it away changes nothing else.
/// Replaces parking (040), which hid a finished session in a group of its own.
public enum ArchiveRequest: Codable, Hashable, Sendable {
    /// Asked while a turn was in flight. The turn runs to its end, and the daemon makes
    /// this `requested` the moment it does, if the ending goes with it. Until then
    /// nothing is shown.
    case whenTurnEnds(since: Date)
    /// Asked. The row carries the mark until the person archives the session or sends
    /// it something, or a later turn ends needing them.
    case requested(at: Date)

    public var isRequested: Bool {
        if case .requested = self { return true }
        return false
    }

    /// When it was asked, if it has been.
    public var requestedAt: Date? {
        if case .requested(let at) = self { return at }
        return nil
    }
}

public extension Agent {
    /// Whether the row carries the Asks to archive mark: asked, and not archived yet.
    var asksToArchive: Bool {
        archiveRequest?.isRequested == true && state != .archived
    }
}

/// Where an agent asked, with a tool it called during its turn, to be put once the turn
/// is over. A request to archive waits for the person's OK, unless something may
/// already archive the session without asking (#584): its workflow, or the agent that
/// started it. Archiving outright is for a workflow's run alone, and only when the
/// workflow's author allowed it with `when-done:` (#433).
public enum AfterTurn: String, Codable, Hashable, Sendable {
    case requestArchive = "request_archive"
    case archive

    /// What an agent sent, if it is one of the two. Anything else is refused rather
    /// than read as nothing: an ask the agent thinks it made and did not is worse than
    /// being told.
    public init?(wire: String) {
        let word = wire.trimmingCharacters(in: .whitespacesAndNewlines)
        // `park`, as a record or a caller from before #584 says it.
        self.init(rawValue: word == "park" ? Self.requestArchive.rawValue : word)
    }

    public init(from decoder: any Decoder) throws {
        let word = try decoder.singleValueContainer().decode(String.self)
        guard let after = AfterTurn(wire: word) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown afterwards \(word)"))
        }
        self = after
    }

    /// Whether it may go with an ending. A request keeps the session in the list until
    /// the person agrees, so `partly_done` may too — but not an ending that asks the
    /// person for something (that session wants them again), nor `blocked` (a blocked
    /// one has to be woken). Archiving puts the work out of sight, so only an ending
    /// with nothing left in it goes with it.
    public func goes(with outcome: WorkOutcome) -> Bool {
        switch (self, outcome) {
        case (.requestArchive, .done), (.requestArchive, .nothingToDo), (.requestArchive, .partlyDone): return true
        case (.archive, .done), (.archive, .nothingToDo): return true
        default: return false
        }
    }

    /// Said when `goes(with:)` is false, by both the service and the daemon.
    public var refusal: String {
        switch self {
        case .requestArchive:
            "Nothing was recorded: a request to archive only goes with done, nothing_to_do or partly_done."
        case .archive: "Nothing was recorded: archive only goes with done or nothing_to_do."
        }
    }

    /// Said when `afterwards` is neither.
    public static let unknown = "Nothing was recorded: afterwards has to be request_archive or archive."

    /// Said when an agent asks to archive itself and its workflow did not allow it, or
    /// no workflow started it.
    public static let archiveNotAllowed = """
        Nothing was recorded: only a workflow's run can archive itself, and only when \
        its workflow says when-done: archive-allowed or archive. Call request_archive \
        with no id instead.
        """
}

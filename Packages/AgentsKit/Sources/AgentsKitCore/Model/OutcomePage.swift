import Foundation

/// One line of the chat as the person reads it.
///
/// What they asked, and what came of it. The work in between — every tool call, every
/// "let me look at…", the plan, the permissions it was given — is one line under the
/// ask that opens to all of it. The record keeps everything; this is what is drawn.
public enum OutcomeRow: Identifiable, Hashable, Sendable {
    case item(TranscriptItem)
    /// The work of one turn, folded. `id` is the first folded item's, so a row the
    /// reader has opened stays open while the turn goes on.
    case steps(id: UUID, items: [TranscriptItem], started: Date?, ended: Date?)

    public var id: UUID {
        switch self {
        case .item(let item): return item.id
        case .steps(let id, _, _, _): return id
        }
    }

    public var isSteps: Bool {
        if case .steps = self { return true }
        return false
    }

    /// How many steps a folded row stands for: each tool call, and each other thing.
    public var stepCount: Int {
        guard case .steps(_, let items, _, _) = self else { return 0 }
        return items.reduce(0) { count, item in
            if case .toolRun(_, let calls) = item { return count + calls.count }
            return count + 1
        }
    }

    /// Whether this folded row holds the entry with that id, for a jump from elsewhere.
    public func holds(_ entryID: UUID) -> Bool {
        guard case .steps(_, let items, _, _) = self else { return false }
        return items.contains { $0.id == entryID }
    }
}

extension Array where Element == TranscriptItem {
    /// The page as asks and outcomes.
    ///
    /// A turn starts at something the person typed. In it, the agent's last message is
    /// the outcome and stays on the page, as does anything the person has to see: their
    /// own answers to its questions, an error, a stop that was not a plain ending. The
    /// rest folds into one row, drawn straight under the ask. A turn with no message
    /// keeps the agent's report of how it went instead.
    public func outcomes() -> [OutcomeRow] {
        var rows: [OutcomeRow] = []
        var turn: [TranscriptItem] = []
        for item in self {
            if item.isPersonsAsk {
                rows += Self.fold(turn)
                turn = [item]
            } else {
                turn.append(item)
            }
        }
        rows += Self.fold(turn)
        return rows
    }

    private static func fold(_ turn: [TranscriptItem]) -> [OutcomeRow] {
        guard !turn.isEmpty else { return [] }
        var rest = turn[...]
        var rows: [OutcomeRow] = []
        var asked: Date?
        if let first = rest.first, first.isPersonsAsk {
            rows.append(.item(first))
            asked = first.at
            rest = rest.dropFirst()
        }
        let outcome = rest.lastIndex(where: \.isAgentMessage)
            ?? rest.lastIndex(where: \.isWorkReport)
        var kept: [TranscriptItem] = []
        var folded: [TranscriptItem] = []
        for index in rest.indices {
            let item = rest[index]
            if index == outcome || item.staysOnThePage { kept.append(item) } else { folded.append(item) }
        }
        if let first = folded.first {
            let dates = turn.compactMap(\.at)
            rows.append(.steps(id: first.id, items: folded,
                               started: asked ?? dates.first, ended: dates.last))
        }
        return rows + kept.map(OutcomeRow.item)
    }
}

extension TranscriptItem {
    var isPersonsAsk: Bool {
        if case .entry(let entry) = self, case .userMessage(_, _, .person) = entry.kind { return true }
        return false
    }

    var isAgentMessage: Bool {
        if case .entry(let entry) = self, case .agentMessage = entry.kind { return true }
        return false
    }

    var isWorkReport: Bool {
        if case .entry(let entry) = self, case .workReported = entry.kind { return true }
        return false
    }

    /// When it was written. A run of tool calls carries no date of its own.
    var at: Date? {
        if case .entry(let entry) = self { return entry.at }
        return nil
    }

    /// Kept out of the fold wherever it falls: what the person said, and what went wrong.
    var staysOnThePage: Bool {
        guard case .entry(let entry) = self else { return false }
        switch entry.kind {
        case .elicitationAnswered(_, _, let answers):
            return !answers.isEmpty
        case .notice(let notice):
            return notice.isError
        case .stateChanged(.stopped, let reason):
            switch reason {
            case .endTurn, .daemonGone, nil: return false
            default: return true
            }
        default:
            return false
        }
    }
}

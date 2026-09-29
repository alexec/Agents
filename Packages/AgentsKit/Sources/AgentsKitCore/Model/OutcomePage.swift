import Foundation

extension Array where Element == TranscriptItem {
    /// The page as asks and where each one got to.
    ///
    /// A turn starts at something the person typed. Of everything the agent did in it,
    /// the page keeps the last block: the last thing it said, or the tool call it made
    /// last, which while it works is what it is doing now. Kept as well, wherever they
    /// fall: the person's own answers to its questions, an error, a stop that was not a
    /// plain ending. The agent's report of how it went is for the list, not the chat.
    /// The record keeps everything; this is what is drawn.
    public func outcomes() -> [TranscriptItem] {
        var page: [TranscriptItem] = []
        var turn: [TranscriptItem] = []
        for item in self {
            if item.isPersonsAsk {
                page += Self.fold(turn)
                turn = [item]
            } else {
                turn.append(item)
            }
        }
        return page + Self.fold(turn)
    }

    private static func fold(_ turn: [TranscriptItem]) -> [TranscriptItem] {
        let last = turn.lastIndex { !$0.isPersonsAsk && $0.isBlock }
        return turn.indices.compactMap { index in
            let item = turn[index]
            return item.isPersonsAsk || index == last || item.staysOnThePage ? item : nil
        }
    }
}

extension TranscriptItem {
    var isPersonsAsk: Bool {
        if case .entry(let entry) = self, case .userMessage(_, _, .person) = entry.kind { return true }
        return false
    }

    /// Something the agent said or did that can stand as where the turn got to. Not
    /// its report (the list's), and not a change of state (the row's).
    var isBlock: Bool {
        guard case .entry(let entry) = self else { return true }
        switch entry.kind {
        case .workReported, .stateChanged: return false
        default: return true
        }
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

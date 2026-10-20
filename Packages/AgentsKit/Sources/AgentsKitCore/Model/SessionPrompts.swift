import Foundation

/// One row of a session's Prompts list (#1658): a prompt the person sent, and how its turn went.
public struct SessionPrompt: Identifiable, Hashable, Sendable {
    /// How a turn ended that did not end as asked: the mark on its row.
    public enum Ending: String, Hashable, Sendable {
        /// Stopped by the person, by the agent that started it, or at its cost limit.
        case stopped
        /// Anything else that ended it early: a crash, a refusal, a sandbox that did not start.
        case failed
    }

    /// The prompt's entry: where the transcript scrolls to, and what Branch from here names.
    public var id: UUID
    /// Its place among the person's prompts, from 1.
    public var number: Int
    public var text: String
    public var at: Date
    /// What its turn cost, as its runtime reported it. Nil when none was reported.
    public var cost: Cost?
    /// From the prompt to the last thing its turn did. Nil while the turn is going.
    public var seconds: Int?
    public var ending: Ending?

    /// The first line with words on it: what a row shows.
    public var title: String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// The Prompts list (#1658): every prompt the person sent in a session, oldest first, each
/// with its turn's cost, time and ending. The page has its own copy (`sessionPrompts` in
/// `Web/src/model/sessionPrompts.ts`), held to `Fixtures/web/prompts/`.
public enum SessionPrompts {
    /// The stored turns and the entries held after them, which may overlap the last turn.
    /// `isRunning` is whether the last turn is still going.
    public static func of(turns: [TurnSummary], entries: [TranscriptEntry], isRunning: Bool) -> [SessionPrompt] {
        // A turn for each ask, in order; a held copy of a turn replaces its stored one.
        struct Turn { var ask: TranscriptEntry; var cost: Cost?; var lastAt: Date?; var ending: SessionPrompt.Ending? }
        var order: [UUID] = []
        var byAsk: [UUID: Turn] = [:]
        func keep(_ turn: Turn) {
            if byAsk[turn.ask.id] == nil { order.append(turn.ask.id) }
            byAsk[turn.ask.id] = turn
        }
        for turn in turns {
            guard let ask = turn.ask else { continue }
            let outcome = turn.outcome ?? []
            keep(Turn(ask: ask, cost: turn.usage?.cost, lastAt: outcome.map(\.at).max(), ending: ending(of: outcome)))
        }
        // The held entries cut at each ask: the person's, or another agent's (#560), not the app's.
        var chunk: [TranscriptEntry] = []
        func close() {
            guard let ask = chunk.first, isAsk(ask) else { return }
            var cost: Cost?
            for case .usageRecorded(let usage) in chunk.map(\.kind) {
                if let more = usage.cost { cost = cost.map { $0.adding(more) ?? $0 } ?? more }
            }
            keep(Turn(ask: ask, cost: cost, lastAt: chunk.count > 1 ? chunk.last?.at : nil, ending: ending(of: chunk)))
        }
        for entry in entries {
            if isAsk(entry) {
                close()
                chunk = []
            }
            chunk.append(entry)
        }
        close()
        var prompts: [SessionPrompt] = []
        for (index, id) in order.enumerated() {
            guard let turn = byAsk[id], case .userMessage(let text, _, .person) = turn.ask.kind else { continue }
            let going = isRunning && index == order.count - 1
            prompts.append(SessionPrompt(
                id: id, number: prompts.count + 1, text: text, at: turn.ask.at, cost: turn.cost,
                seconds: going ? nil : turn.lastAt.map { max(0, Int($0.timeIntervalSince(turn.ask.at).rounded())) },
                ending: going ? nil : turn.ending))
        }
        return prompts
    }

    static func isAsk(_ entry: TranscriptEntry) -> Bool {
        if case .userMessage(_, _, let from) = entry.kind { return from != .app }
        return false
    }

    /// The prompts whose words hold `query`, whatever their case; all of them for none.
    public static func filtered(_ prompts: [SessionPrompt], by query: String) -> [SessionPrompt] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return prompts }
        return prompts.filter { $0.text.lowercased().contains(query) }
    }

    /// How a turn's entries say it ended, the latest that says: a stop, a sandbox that did
    /// not start, or a finish (nothing to mark).
    static func ending(of entries: [TranscriptEntry]) -> SessionPrompt.Ending? {
        for entry in entries.reversed() {
            switch entry.kind {
            case .stateChanged(.stopped, let reason):
                switch reason {
                case .cancelled, .stoppedByAgent, .costLimit: return .stopped
                case .endTurn, .daemonGone, nil: return nil
                default: return .failed
                }
            case .stateChanged(.finished, _):
                return nil
            case .sandboxFailure:
                return .failed
            default:
                continue
            }
        }
        return nil
    }
}

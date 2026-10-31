import Foundation
import Synchronization

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

    /// Branch from Here's help (#1871), on its menu items: the branch shares the folder, so its
    /// record goes back and the files do not. The host's note and the page say the same.
    public static let branchHelp = "Start a new session from just before this prompt, with the prompt in its bar to change. The files stay as they are now."

    /// The first line with words on it: what a row shows.
    public var title: String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// The grey line under a row's title: "$0.14 · 3m · 14:05", its cost to the cent (a
    /// turn's cost is mostly under a unit, which `money(in:)` rounds away), its length as the Time page says one, and when it was sent, with
    /// the day when that is not today. A part with nothing to say is left out. The page has
    /// its own copy (`promptLine` in `Web/src/model/sessionPrompts.ts`).
    public func detail(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if let cost { parts.append(cost.amount.formatted(Self.currencyStyle(cost.currency))) }
        if let seconds { parts.append(TimeChart.words(Double(seconds))) }
        parts.append(ActivityWords.sent(at, now: now, timeZone: timeZone))
        return parts.joined(separator: " · ")
    }

    /// One currency style per currency (#1850), not one per row each time it is drawn.
    private static func currencyStyle(_ code: String) -> Decimal.FormatStyle.Currency {
        currencyStyles.withLock { styles in
            if let style = styles[code] { return style }
            let style = Decimal.FormatStyle.Currency(code: code).precision(.fractionLength(2))
            styles[code] = style
            return style
        }
    }

    private static let currencyStyles = Mutex<[String: Decimal.FormatStyle.Currency]>([:])
}

/// The Prompts list (#1658): every prompt the person sent in a session, oldest first, each
/// with its turn's cost, time and ending. The page has its own copy (`sessionPrompts` in
/// `Web/src/model/sessionPrompts.ts`), held to `Fixtures/web/prompts/`.
public enum SessionPrompts {
    /// The stored turns and the entries held after them, which may overlap the last turn.
    /// `isRunning` is whether the last turn is still going. `earlier` is how many of the
    /// person's prompts come before the turns: the first is numbered after them (#1862).
    public static func of(turns: [TurnSummary], entries: [TranscriptEntry], isRunning: Bool,
                          earlier: Int = 0) -> [SessionPrompt] {
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
                id: id, number: earlier + prompts.count + 1, text: text, at: turn.ask.at, cost: turn.cost,
                seconds: going ? nil : turn.lastAt.map { max(0, Int($0.timeIntervalSince(turn.ask.at).rounded())) },
                ending: going ? nil : turn.ending))
        }
        return prompts
    }

    /// `of`, worked out again only when what it reads changes (#1850): the open Prompts list
    /// asks on every body, which is every keystroke in its filter and every streamed entry.
    /// Arrays that share their storage compare at once, so an unchanged chat costs nothing.
    @MainActor
    public final class Memo {
        private var key: (turns: [TurnSummary], entries: [TranscriptEntry], isRunning: Bool, earlier: Int)?
        private var prompts: [SessionPrompt] = []
        /// How many times `of` ran: for tests.
        public private(set) var worked = 0

        public init() {}

        public func of(turns: [TurnSummary], entries: [TranscriptEntry], isRunning: Bool, earlier: Int = 0) -> [SessionPrompt] {
            if let key, key.isRunning == isRunning, key.earlier == earlier, key.turns == turns, key.entries == entries {
                return prompts
            }
            worked += 1
            prompts = SessionPrompts.of(turns: turns, entries: entries, isRunning: isRunning, earlier: earlier)
            key = (turns, entries, isRunning, earlier)
            return prompts
        }
    }

    /// How many of the person's prompts these turns start with: what the chat lets go of
    /// when it trims its oldest turns.
    public static func count(in turns: some Sequence<TurnSummary>) -> Int {
        turns.count { turn in
            if case .userMessage(_, _, .person)? = turn.ask?.kind { return true }
            return false
        }
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

    /// The row chosen after Up (`down` false) or Down in a list of `count` rows, from `at`:
    /// the newest (the last) while none is chosen, and no further than either end (#1870).
    /// The page has its own copy (`movedTo` in `Web/src/model/sessionPrompts.ts`).
    public static func moved(from at: Int?, count: Int, down: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let at else { return count - 1 }
        return max(0, min(count - 1, at + (down ? 1 : -1)))
    }

    /// How a turn's entries say it ended, the latest that says: a stop, a sandbox that did
    /// not start, or a finish (nothing to mark).
    static func ending(of entries: [TranscriptEntry]) -> SessionPrompt.Ending? {
        for entry in entries.reversed() {
            switch entry.kind {
            case .stateChanged(.stopped, let reason):
                switch reason {
                case .cancelled, .stoppedByAgent, .stoppedByAdmin, .costLimit: return .stopped
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

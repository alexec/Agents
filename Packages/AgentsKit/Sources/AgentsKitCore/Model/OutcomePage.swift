import Foundation

/// How much of a turn is drawn (069). The app keeps one of these as the level every turn
/// starts at; a turn opened or closed by hand holds its own until the chat is left.
public enum TurnDetail: String, CaseIterable, Codable, Hashable, Sendable {
    /// The ask, the answers, the reply and how it went.
    case outcome
    /// And every step between them, one line each.
    case steps
    /// And every call opened, and the agent's thinking.
    case details

    public var title: String {
        switch self {
        case .outcome: return "Outcome"
        case .steps: return "Steps"
        case .details: return "Details"
        }
    }

    /// What the level shows, said beside it in the menu so nobody has to try all three.
    public var summary: String {
        switch self {
        case .outcome: return "What was asked and how it went"
        case .steps: return "Every step, one line each"
        case .details: return "Every call opened, and thinking"
        }
    }

    public var showsSteps: Bool { self != .outcome }

    /// Where the phone keeps its choice. The Mac scopes its own by root.
    public static let phoneDefaultsKey = "turnDetail"
}

/// One turn of a conversation: what the person asked, and everything up to the next ask.
///
/// Drawn at one of three levels (069). Its outcome — the answers, the reply and how it
/// went — is drawn at every one; the steps between are a click away.
public struct ChatTurn: Identifiable, Hashable, Sendable {
    /// The ask's id, or the first item's for what came before any ask.
    public var id: UUID
    public var ask: TranscriptItem?
    /// Everything drawn after the ask, in order. Empty for a turn known only by its
    /// summary until its entries are fetched.
    public var items: [TranscriptItem]
    /// A stored turn's outcome and step count, drawn before its entries are in hand.
    public var storedOutcome: [TranscriptItem]?
    public var storedStepCount: Int?
    /// Where it sits in the transcript, for a turn known only by its summary.
    public var range: Range<Int>?

    public init(id: UUID, ask: TranscriptItem?, items: [TranscriptItem],
                storedOutcome: [TranscriptItem]? = nil, storedStepCount: Int? = nil,
                range: Range<Int>? = nil) {
        self.id = id
        self.ask = ask
        self.items = items
        self.storedOutcome = storedOutcome
        self.storedStepCount = storedStepCount
        self.range = range
    }

    /// A stored summary, drawn before its entries are in hand. One written before 069
    /// has no outcome, and its concise blocks stand in: 069 is after the #58 cut-off.
    public init(_ summary: TurnSummary) {
        let outcome = summary.outcome ?? summary.concise ?? summary.last.map { [$0] } ?? []
        self.init(id: summary.id,
                  ask: summary.ask.map(TranscriptItem.entry),
                  items: [],
                  storedOutcome: outcome.map(TranscriptItem.entry),
                  storedStepCount: summary.steps,
                  range: summary.start..<summary.end)
    }

    /// Whether this is a stored turn whose entries have not been fetched.
    public var isSummaryOnly: Bool { items.isEmpty && range != nil }
}

/// A turn's items, read for drawing.
public struct TurnParts: Hashable, Sendable {
    /// The answers, the reply and how it went, in order.
    public var outcome: [TranscriptItem]
    /// How many step lines there are behind the control. Thinking is not counted.
    public var stepCount: Int
    /// The latest step, while the turn runs and has said nothing after it.
    public var live: TranscriptItem?

    /// `items` is everything drawn after the ask. `isLive` is whether the turn is still
    /// going: its reply is only a reply once nothing follows it.
    public init(_ items: [TranscriptItem], isLive: Bool) {
        let shown = Self.drawn(items, isLive: isLive).filter { !$0.isThought }
        let reply = Self.reply(in: shown, isLive: isLive)
        var outcome: [TranscriptItem] = []
        var reports: [TranscriptItem] = []
        var steps = 0
        for (index, item) in shown.enumerated() {
            if item.isReport {
                reports.append(item)
            } else if reply.contains(index) || item.isOutcome {
                outcome.append(item)
            } else if case .toolRun(_, let calls) = item {
                steps += calls.count
            } else {
                steps += 1
            }
        }
        // The report is the turn's last line, whatever the agent said after it.
        self.outcome = outcome + reports
        self.stepCount = steps
        self.live = isLive && reply.isEmpty ? shown.last(where: { !$0.isOutcome }) : nil
    }

    /// What a turn draws of its items, thinking aside. A passing line — "Picked the
    /// conversation back up." — is only news while its turn is going; once the turn
    /// is over it is neither a step nor something standing between the reply and the
    /// end of the turn.
    public static func drawn(_ items: [TranscriptItem], isLive: Bool) -> [TranscriptItem] {
        items.filter { $0.isInTurn && (isLive || !$0.isPassing) }
    }

    /// The reply: what the agent said at the end, after its last step. Claude often
    /// says a closing line after its report, and that belongs with the reply rather
    /// than standing in for it. A finished turn that ended on a step still has its
    /// last message as the reply; a running one is still on its way.
    static func reply(in items: [TranscriptItem], isLive: Bool) -> [Int] {
        var run: [Int] = []
        for index in items.indices.reversed() {
            if items[index].isAgentMessage { run.insert(index, at: 0) }
            else if !items[index].isOutcome { break }
        }
        if !run.isEmpty || isLive { return run }
        return items.lastIndex(where: \.isAgentMessage).map { [$0] } ?? []
    }
}

/// What is kept of a turn once it is over, so a conversation opens from its turns rather
/// than from every entry of it (`turns.jsonl`, beside the transcript).
public struct TurnSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The transcript's index of the turn's first entry, and one past its last.
    public var start: Int
    public var end: Int
    public var ask: TranscriptEntry?
    /// The last work block, retained for clients built before 069 (after the #58
    /// cut-off of 051).
    public var last: TranscriptEntry?
    /// The latest work and its context, retained for clients built before 069, likewise.
    public var concise: [TranscriptEntry]?
    /// The answers, the reply and how it went (069). Nil in a summary written before.
    public var outcome: [TranscriptEntry]?
    /// How many step lines the turn has behind its control (069).
    public var steps: Int?
    /// What the turn used, as its runtime reported it (#465): every report in the turn,
    /// added up, so turns can be compared across agents and before and after a change.
    /// Nil when the runtime reported none, and in a summary written before.
    public var usage: TurnUsage?

    public init(id: UUID, start: Int, end: Int, ask: TranscriptEntry?, last: TranscriptEntry?,
                concise: [TranscriptEntry]? = nil, outcome: [TranscriptEntry]? = nil,
                steps: Int? = nil, usage: TurnUsage? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.ask = ask
        self.last = last
        self.concise = concise
        self.outcome = outcome
        self.steps = steps
        self.usage = usage
    }

    /// The turn made of these entries, the first at `start` in the transcript.
    public static func of(_ entries: [TranscriptEntry], start: Int) -> TurnSummary {
        let ask = entries.first.flatMap { TranscriptItem.entry($0).isPersonsAsk ? $0 : nil }
        let items = TranscriptEntry.display(entries)
        let last = items.last(where: \.isBlock).flatMap(\.concise)
        let concise = items.conciseTurnItems().compactMap(\.concise)
        let parts = TurnParts(Array(items.dropFirst(ask == nil ? 0 : 1)), isLive: false)
        return TurnSummary(id: ask?.id ?? entries.first?.id ?? UUID(), start: start,
                           end: start + entries.count, ask: ask, last: last, concise: concise,
                           outcome: parts.outcome.compactMap(\.concise), steps: parts.stepCount,
                           usage: TurnUsage.total(of: entries))
    }

    /// Cut a run of the transcript, the first entry at `start`, into turns. Each ask
    /// starts one. Every turn but the last is over; the last may still be going, and is
    /// returned apart, by where it starts.
    public static func split(_ entries: [TranscriptEntry], start: Int) -> (closed: [TurnSummary], openStart: Int) {
        var closed: [TurnSummary] = []
        var turnStart = 0
        for (offset, entry) in entries.enumerated() where offset > turnStart && TranscriptItem.entry(entry).isPersonsAsk {
            closed.append(of(Array(entries[turnStart..<offset]), start: start + turnStart))
            turnStart = offset
        }
        return (closed, start + turnStart)
    }
}

extension Array where Element == TranscriptItem {
    /// The page cut into turns. A turn starts at each thing the person typed.
    public func turns() -> [ChatTurn] {
        turns(reusing: [])
    }

    /// The same cut, keeping a turn from `earlier` while the items it was folded from
    /// are still the ones in front. A streamed chunk changes the tail; the turns
    /// before it are the same values, so a row that compares them has nothing to
    /// redraw (#285). The first turn that differs, and everything after it, is folded
    /// again: a page put in front shifts the rest.
    public func turns(reusing earlier: [ChatTurn]) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var current: [TranscriptItem] = []
        var reuse = true
        func close() {
            guard let first = current.first else { return }
            let index = turns.count
            if reuse, index < earlier.count, earlier[index].matches(current) {
                turns.append(earlier[index])
            } else {
                reuse = false
                let ask = first.isPersonsAsk ? first : nil
                turns.append(ChatTurn(id: first.id, ask: ask,
                                      items: Array(current.dropFirst(ask == nil ? 0 : 1))))
            }
            current = []
        }
        for item in self {
            if item.isPersonsAsk {
                close()
                current = [item]
            } else {
                current.append(item)
            }
        }
        close()
        return turns
    }
}

extension Array where Element == TurnSummary {
    /// Keep one row for each turn, in its original position, with the latest copy's
    /// outcome. Pages can overlap when a reconnect catches up with turns already held.
    public func keepingLastTurnWithEachID() -> [TurnSummary] {
        var positions: [UUID: Int] = [:]
        var unique: [TurnSummary] = []
        for turn in self {
            if let position = positions[turn.id] {
                unique[position] = turn
            } else {
                positions[turn.id] = unique.count
                unique.append(turn)
            }
        }
        return unique
    }
}

extension Array where Element == ChatTurn {
    /// A live transcript can overlap its last stored turn after reconnecting. Keep one
    /// row at that position and let the live copy supply its current contents.
    public func keepingLastTurnWithEachID() -> [ChatTurn] {
        var positions: [UUID: Int] = [:]
        var unique: [ChatTurn] = []
        for turn in self {
            if let position = positions[turn.id] {
                unique[position] = turn
            } else {
                positions[turn.id] = unique.count
                unique.append(turn)
            }
        }
        return unique
    }
}

extension ChatTurn {
    /// Whether this turn is the fold of `slice`, ask and all.
    fileprivate func matches(_ slice: [TranscriptItem]) -> Bool {
        if let ask {
            return slice.first == ask && Array(slice.dropFirst()) == items
        }
        return slice == items
    }
}

extension TranscriptItem {
    public var isPersonsAsk: Bool {
        if case .entry(let entry) = self, case .userMessage(_, _, .person) = entry.kind { return true }
        return false
    }

    var isAgentMessage: Bool {
        if case .entry(let entry) = self, case .agentMessage = entry.kind { return true }
        return false
    }

    /// Something that says how the turn went, or the person's own answer: drawn at every
    /// level (069). A stop, a failure, an error, the agent's report.
    public var isOutcome: Bool {
        guard case .entry(let entry) = self else { return false }
        switch entry.kind {
        // An answer to a question is the person's say in how it went. A permission
        // choice is a step: "You chose Yes" says nothing about the outcome.
        case .elicitationAnswered, .workReported, .sandboxFailure:
            return true
        // A view is what the call is for (#187): drawn at every level, as a reply is.
        case .appView:
            return true
        case .stateChanged(let state, _):
            return state == .stopped
        case .notice(let notice):
            return notice.isError
        default:
            return false
        }
    }

    /// Whether a turn draws it at all. A state the turn passed through — working,
    /// waiting on you — is said by the row and the prompt while it is true, and is not
    /// a step. A stop is kept: it is how the turn went.
    public var isInTurn: Bool {
        if case .entry(let entry) = self, case .stateChanged(let state, _) = entry.kind {
            return state == .stopped
        }
        return true
    }

    var isReport: Bool {
        if case .entry(let entry) = self, case .workReported = entry.kind { return true }
        return false
    }

    /// A tool call or something the agent said. And a sandbox that could not start
    /// (064), which ends its turn and must be seen to be answered. Kept for the
    /// summaries older clients read.
    public var isBlock: Bool {
        switch self {
        case .toolRun: return true
        case .entry(let entry):
            switch entry.kind {
            case .agentMessage, .sandboxFailure: return true
            default: return false
            }
        }
    }

    /// Answers to questions and permission choices are the person's input mid-turn.
    public var isUserInput: Bool {
        guard case .entry(let entry) = self else { return false }
        switch entry.kind {
        case .elicitationAnswered, .permissionAnswered: return true
        default: return false
        }
    }

    /// This item as a summary keeps text whole, and a tool run's last call with
    /// only its description.
    var concise: TranscriptEntry? {
        switch self {
        case .entry(let entry):
            return entry
        case .toolRun(let id, let calls):
            guard var call = calls.last else { return nil }
            call.content = []
            call.locations = []
            call.rawOutput = nil
            call.raw = nil
            call.rawInput = call.describedAs.map { .object(["description": .string($0)]) }
            return TranscriptEntry(id: id, kind: .toolCall(call))
        }
    }
}

extension Array where Element == TranscriptItem {
    /// The pre-069 concise turn, still written for older clients: answers wherever they
    /// occurred, plus the latest work and the text before it when that work is a call.
    func conciseTurnItems() -> [TranscriptItem] {
        guard let last = lastIndex(where: \.isBlock) else { return filter(\.isUserInput) }
        var selected = Set([last])
        if last > 0, case .toolRun = self[last],
           case .entry(let entry) = self[last - 1], case .agentMessage = entry.kind {
            selected.insert(last - 1)
        }
        return enumerated().compactMap { index, item in
            selected.contains(index) || item.isUserInput ? item : nil
        }
    }
}

extension ToolCall {
    /// What the agent said the call was for, when it said.
    public var describedAs: String? {
        guard let text = rawInput?["description"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The one line a tool call is drawn as in a turn.
    public var turnLine: String {
        if let describedAs { return describedAs }
        if let kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !kind.isEmpty {
            let label: String
            switch kind {
            case "read": label = "Read file"
            case "edit": label = "Edit file"
            case "delete": label = "Delete file"
            case "move": label = "Move file"
            case "search": label = "Search files"
            case "execute": label = "Run command"
            case "fetch": label = "Fetch data"
            case "other": label = Self.readableToolName(name) ?? "Used a tool"
            default: label = Self.readableToolName(name) ?? Self.readableToolName(kind) ?? "Used a tool"
            }
            if let name = Self.readableToolName(name), !label.localizedCaseInsensitiveContains(name) {
                return "\(label) (\(name))"
            }
            return label
        }
        return Self.readableToolName(name) ?? "Used a tool"
    }

    private static func readableToolName(_ value: String?) -> String? {
        guard let value else { return nil }
        let words = value
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "[_./-]+", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return words.map { $0.capitalized }.joined(separator: " ")
    }
}

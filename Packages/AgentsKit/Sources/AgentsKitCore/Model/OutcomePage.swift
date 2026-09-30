import Foundation

/// One turn of a conversation: what the person asked, and everything up to the next ask.
///
/// Drawn concise by default: the ask, every answer, and the latest work. When that work
/// is a tool call, the text immediately before it is shown too.
public struct ChatTurn: Identifiable, Hashable, Sendable {
    /// The ask's id, or the first item's for what came before any ask.
    public var id: UUID
    public var ask: TranscriptItem?
    /// Every tool call and text block, in order. Empty for a turn known only by its
    /// summary until its entries are fetched.
    public var blocks: [TranscriptItem]
    /// The latest work block, also kept for summaries written by older builds.
    public var last: TranscriptItem?
    /// The work and answers visible while this turn is concise, in transcript order.
    public var concise: [TranscriptItem]
    /// Where it sits in the transcript, for a turn known only by its summary.
    public var range: Range<Int>?

    public init(id: UUID, ask: TranscriptItem?, blocks: [TranscriptItem], last: TranscriptItem?,
                concise: [TranscriptItem]? = nil,
                range: Range<Int>? = nil) {
        self.id = id
        self.ask = ask
        self.blocks = blocks
        self.last = last
        self.concise = concise ?? blocks.conciseTurnItems()
        self.range = range
    }

    /// A stored summary, drawn before its entries are in hand.
    public init(_ summary: TurnSummary) {
        self.init(id: summary.id,
                  ask: summary.ask.map(TranscriptItem.entry),
                  blocks: [],
                  last: summary.last.map(TranscriptItem.entry),
                  concise: summary.concise?.map(TranscriptItem.entry)
                    ?? summary.last.map { [.entry($0)] } ?? [],
                  range: summary.start..<summary.end)
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
    /// The last work block, retained for summaries written by older builds.
    public var last: TranscriptEntry?
    /// Optional so summaries written before concise turns kept context still decode.
    public var concise: [TranscriptEntry]?

    public init(id: UUID, start: Int, end: Int, ask: TranscriptEntry?, last: TranscriptEntry?,
                concise: [TranscriptEntry]? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.ask = ask
        self.last = last
        self.concise = concise
    }

    /// The turn made of these entries, the first at `start` in the transcript.
    public static func of(_ entries: [TranscriptEntry], start: Int) -> TurnSummary {
        let ask = entries.first.flatMap { TranscriptItem.entry($0).isPersonsAsk ? $0 : nil }
        let items = TranscriptEntry.display(entries)
        let last = items.last(where: \.isBlock).flatMap(\.concise)
        let concise = items.conciseTurnItems().compactMap(\.concise)
        return TurnSummary(id: ask?.id ?? entries.first?.id ?? UUID(), start: start,
                           end: start + entries.count, ask: ask, last: last, concise: concise)
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
        var turns: [ChatTurn] = []
        var current: [TranscriptItem] = []
        func close() {
            guard let first = current.first else { return }
            let ask = first.isPersonsAsk ? first : nil
            let blocks = current.filter { $0.isBlock || $0.isUserInput }
            turns.append(ChatTurn(id: first.id, ask: ask, blocks: blocks,
                                  last: blocks.last(where: \.isBlock)))
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

extension TranscriptItem {
    var isPersonsAsk: Bool {
        if case .entry(let entry) = self, case .userMessage(_, _, .person) = entry.kind { return true }
        return false
    }

    /// A tool call or something the agent said: all a turn draws besides the ask. And a
    /// sandbox that could not start (064), which ends its turn and must be seen to be
    /// answered, so it is the block a concise turn shows.
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
    /// Keep answers wherever they occurred, plus the latest work and its immediate
    /// preceding text when the latest work is a tool call.
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
    public var turnLine: String { describedAs ?? "Used a tool" }
}

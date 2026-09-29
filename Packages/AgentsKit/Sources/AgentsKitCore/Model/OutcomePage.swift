import Foundation

/// One turn of a conversation: what the person asked, and everything up to the next ask.
///
/// Drawn concise by default: the ask, and the last block of the rest. A block is a tool
/// call or something the agent said; nothing else in a turn is drawn. Clicked, a turn is
/// drawn normal: the ask and every block in it.
public struct ChatTurn: Identifiable, Hashable, Sendable {
    /// The ask's id, or the first item's for what came before any ask.
    public var id: UUID
    public var ask: TranscriptItem?
    /// Every tool call and text block, in order. Empty for a turn known only by its
    /// summary until its entries are fetched.
    public var blocks: [TranscriptItem]
    /// The one a concise turn shows.
    public var last: TranscriptItem?
    /// Where it sits in the transcript, for a turn known only by its summary.
    public var range: Range<Int>?

    public init(id: UUID, ask: TranscriptItem?, blocks: [TranscriptItem], last: TranscriptItem?,
                range: Range<Int>? = nil) {
        self.id = id
        self.ask = ask
        self.blocks = blocks
        self.last = last
        self.range = range
    }

    /// A stored summary, drawn before its entries are in hand.
    public init(_ summary: TurnSummary) {
        self.init(id: summary.id,
                  ask: summary.ask.map(TranscriptItem.entry),
                  blocks: [],
                  last: summary.last.map(TranscriptItem.entry),
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
    /// The last block, cut down to what a concise turn draws: a tool call keeps its
    /// description and nothing it produced.
    public var last: TranscriptEntry?

    public init(id: UUID, start: Int, end: Int, ask: TranscriptEntry?, last: TranscriptEntry?) {
        self.id = id
        self.start = start
        self.end = end
        self.ask = ask
        self.last = last
    }

    /// The turn made of these entries, the first at `start` in the transcript.
    public static func of(_ entries: [TranscriptEntry], start: Int) -> TurnSummary {
        let ask = entries.first.flatMap { TranscriptItem.entry($0).isPersonsAsk ? $0 : nil }
        let items = TranscriptEntry.display(entries)
        let last = items.last(where: \.isBlock).flatMap(\.concise)
        return TurnSummary(id: ask?.id ?? entries.first?.id ?? UUID(), start: start,
                           end: start + entries.count, ask: ask, last: last)
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
            let blocks = current.filter(\.isBlock)
            turns.append(ChatTurn(id: first.id, ask: ask, blocks: blocks, last: blocks.last))
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

    /// A tool call or something the agent said: all a turn draws besides the ask.
    public var isBlock: Bool {
        switch self {
        case .toolRun: return true
        case .entry(let entry):
            if case .agentMessage = entry.kind { return true }
            return false
        }
    }

    /// This block as a summary keeps it: text whole, a tool call as its last call with
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

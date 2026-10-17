import Foundation

/// A run of turns, and the cards that wait after it (#973).
///
/// A waiting card (a permission, a form, a guarded change, an ask to archive) is drawn
/// where it was asked, not after the whole conversation: what came after it is drawn
/// below it.
public struct ChatStretch<Card> {
    /// The turns before `cards`. A turn a card arrived in shows as two: the part up to
    /// the card, and the rest after it, with no ask.
    public var turns: [ChatTurn]
    /// The cards asked at this place, in the order they were given.
    public var cards: [Card]

    public init(turns: [ChatTurn], cards: [Card]) {
        self.turns = turns
        self.cards = cards
    }
}

extension TranscriptItem {
    /// When it was said or done. Nil for a run of tool calls, which keeps no time: it
    /// goes with what is next to it.
    public var at: Date? {
        if case .entry(let entry) = self { return entry.at }
        return nil
    }
}

extension Array where Element == ChatTurn {
    /// The turns, cut at each card's place: after the last thing said or done before
    /// its request arrived, so the first thing with a later time is below it.
    ///
    /// Something with no time (a run of tool calls) stays on the side of the card it
    /// was on: before it when the next thing with a time is later than the card, as the
    /// call that raised a permission is.
    ///
    /// The host's own record of a question (`permissionAsked`, a form asked, the state
    /// going to waiting) is written a moment after the request: anything within
    /// `recordGrace` of it counts as before it, so the record is above its card.
    ///
    /// One stretch with no cards when there are none. The last stretch has no cards
    /// when turns came after the last card; it has cards, and no stretch follows it,
    /// when the last card is newer than everything.
    public func placing<Card>(_ cards: [Card], at time: (Card) -> Date) -> [ChatStretch<Card>] {
        guard !cards.isEmpty else { return [ChatStretch(turns: self, cards: [])] }
        // Each card's place, as the first thing to draw below it.
        var groups: [Place: [Card]] = [:]
        for card in cards {
            groups[place(of: time(card)), default: []].append(card)
        }
        var stretches: [ChatStretch<Card>] = []
        var turns: [ChatTurn] = []
        var at = Place(turn: 0, item: -1)
        for place in groups.keys.sorted() {
            // The turns wholly before this place, and the part of the turn it cuts.
            turns += cut(from: at, to: place)
            stretches.append(ChatStretch(turns: turns, cards: groups[place] ?? []))
            turns = []
            at = place
        }
        turns += cut(from: at, to: Place(turn: count, item: -1))
        if !turns.isEmpty { stretches.append(ChatStretch(turns: turns, cards: [])) }
        return stretches
    }

    /// How long after a request its own record may be written and still count as before it.
    static var recordGrace: TimeInterval { 0.5 }

    /// A place between things in the transcript: before the ask of `turn` when `item`
    /// is -1, before `items[item]` of it otherwise. `turn == count` is the end.
    private struct Place: Hashable, Comparable {
        var turn: Int
        var item: Int

        static func < (a: Place, b: Place) -> Bool {
            (a.turn, a.item) < (b.turn, b.item)
        }
    }

    /// From the end back, the earliest of the things after `time`. Cards are almost
    /// always recent, so this reads only the tail.
    private func place(of asked: Date) -> Place {
        let time = asked.addingTimeInterval(Self.recordGrace)
        var place = Place(turn: count, item: -1)
        for turn in indices.reversed() {
            let row = self[turn]
            for item in row.items.indices.reversed() {
                guard let at = row.items[item].at else { continue }
                if at > time {
                    place = Place(turn: turn, item: item)
                } else {
                    return place
                }
            }
            if let at = row.ask?.at {
                if at > time { place = Place(turn: turn, item: -1) } else { return place }
            }
        }
        return place
    }

    /// The turns between two places, a turn cut by either drawn in part. The part after
    /// a cut is a turn of its own, named by its first item.
    private func cut(from start: Place, to end: Place) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var turn = start.turn
        while turn < Swift.min(end.turn + 1, count) {
            let row = self[turn]
            let from = turn == start.turn ? start.item : -1
            let to = turn == end.turn ? end.item : row.items.count
            turn += 1
            // Before the ask is the place between turns: nothing of this one yet.
            if to == -1 { break }
            if from == -1 && to == row.items.count {
                turns.append(row)
            } else if from == -1 {
                // A turn with no ask, cut before its first item: none of it is before.
                if row.ask == nil && to == 0 { continue }
                turns.append(ChatTurn(id: row.id, ask: row.ask, items: [TranscriptItem](row.items[0..<to])))
            } else if from < to {
                turns.append(ChatTurn(id: row.items[from].id, ask: nil, items: [TranscriptItem](row.items[from..<to])))
            }
        }
        return turns
    }
}

/// Where a conversation just opened is placed when not at its end (#1287).
public enum ChatOpeningPlace: Equatable, Sendable {
    /// The cards of this stretch: the first asked, when it was asked before the end.
    case cards(stretch: Int)
    /// This turn's ask, at the top of the pane.
    case turn(UUID)
    /// The last turn's ask, which is before the page in hand: a turn longer than the
    /// opening page opens on its tail. Page back until it is in hand.
    case askBefore
}

extension Array {
    /// Where the reader needs the conversation opened (#1287): at the first card waiting
    /// when anything came after it, else, unread, at the ask of the last turn, else at the
    /// end (nil). Unread is one mark on the agent, set only by a finish nobody watched, so
    /// the last turn is the first unread one. A card at the end is the end. A last turn
    /// with no ask in hand is the tail of a turn longer than the opening page: its ask is
    /// before it (`askBefore`).
    public func openingPlace<Card>(unread: Bool) -> ChatOpeningPlace? where Element == ChatStretch<Card> {
        if let first = firstIndex(where: { !$0.cards.isEmpty }) {
            return first == count - 1 ? nil : .cards(stretch: first)
        }
        guard unread, let last = last?.turns.last else { return nil }
        return last.ask != nil ? .turn(last.id) : .askBefore
    }
}

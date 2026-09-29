import Foundation

/// Some of a conversation's finished turns, oldest first, and where the turn still in
/// progress starts in the transcript.
public struct TurnsPage: Codable, Hashable, Sendable {
    public var turns: [TurnSummary]
    /// The position of the first of `turns` among all the finished ones.
    public var firstTurn: Int
    /// The transcript's index of the first entry of the turn after the last finished
    /// one: where `agents/transcript` is asked to start.
    public var openStart: Int

    public init(turns: [TurnSummary], firstTurn: Int, openStart: Int) {
        self.turns = turns
        self.firstTurn = firstTurn
        self.openStart = openStart
    }

    public var hasMoreBefore: Bool { firstTurn > 0 }
}

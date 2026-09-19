import Foundation

/// A page of a transcript, newest last. Never the whole thing.
///
/// Here rather than beside the store that reads it, because it is what
/// `agents/transcript` answers with, and the client asking may be a phone that has
/// never seen the file. A conversation with an hour in it opens at its end and asks
/// backwards, which is what `firstIndex` is for.
public struct TranscriptPage: Codable, Hashable, Sendable {
    /// The index of the first entry in `entries` within the whole transcript, so the
    /// app can ask for the page before this one.
    public var firstIndex: Int
    public var total: Int
    public var entries: [TranscriptEntry]

    public init(firstIndex: Int, total: Int, entries: [TranscriptEntry]) {
        self.firstIndex = firstIndex
        self.total = total
        self.entries = entries
    }

    public var hasMoreBefore: Bool { firstIndex > 0 }
}

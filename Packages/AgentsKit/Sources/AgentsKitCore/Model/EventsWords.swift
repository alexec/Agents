import Foundation

/// The words of the sidebar's Events row, in the half the window and the Remote both hold,
/// so the two say it one way. The web page's `eventsWaitingLine` says the same.
public enum EventsWords {
    /// The Events row's grey line: how many sessions wait for an event, "4 sessions waiting".
    /// Nil when none waits, so the row has no line. It has no time: a wait's age says nothing
    /// about when it ends.
    public static func waitingLine(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 session waiting" : "\(count) sessions waiting"
    }
}

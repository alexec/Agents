import Foundation

/// How often Agents Host's window looks at what is running, and how hard (#134).
///
/// A full look asks launchd about both jobs and `agents-control` for its clients and hosts:
/// four processes or more. A cheap look starts none: `kill(pid, 0)` on the processes the last
/// full look found, the files they write, and the kept socket to this Mac's host. The window
/// takes a cheap look every `tick` while it can be seen, and a full one only when something
/// gives it cause: it has just come into view, a process it knew has gone, a job it expects
/// isn't running (backing off while that stays so), or the counts are a minute old in the
/// key window, five minutes in one behind. Out of sight it looks at nothing.
public struct HostRefreshPolicy: Sendable, Equatable {
    public enum Look: Sendable, Equatable {
        case none, cheap, full
    }

    public static let tick: Duration = .seconds(5)
    /// How old the counts may get in the key window, and in a window that is only visible.
    public static let keyEvery: TimeInterval = 60
    public static let behindEvery: TimeInterval = 300
    /// While a job it expects stays missing: launchd asked again after 5 s, 10, 20, 40, then
    /// every minute.
    public static let firstRetry: TimeInterval = 5
    public static let longestRetry: TimeInterval = 60

    public private(set) var lastFull: Date?
    private var seen = false
    private var retry = firstRetry

    public init() {}

    /// What to do on this tick. `lost` is a process the last full look found that is gone;
    /// `missing` a job the role wants running that the last full look didn't find.
    public mutating func look(at now: Date, visible: Bool, key: Bool, lost: Bool, missing: Bool) -> Look {
        guard visible else {
            seen = false
            return .none
        }
        let cameIntoView = !seen
        seen = true
        if !missing { retry = Self.firstRetry }
        guard let lastFull, !cameIntoView, !lost else { return .full }
        let age = now.timeIntervalSince(lastFull)
        if missing, age >= retry {
            retry = min(retry * 2, Self.longestRetry)
            return .full
        }
        return age >= (key ? Self.keyEvery : Self.behindEvery) ? .full : .cheap
    }

    /// A full look happened: on a tick, or on demand after Start, Stop or any other action.
    public mutating func lookedFully(at now: Date) {
        lastFull = now
    }
}

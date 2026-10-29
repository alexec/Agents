import Foundation

/// Slow set-up done ahead of the moment it is needed (P20261029-1).
///
/// Voice mode's echo cancellation takes about a second to switch on, and it is set up when
/// the first prompt bar draws, so that a press listens at once. `start` runs `work`;
/// `wait` waits for a run that has not ended, so a press does not start a second one. A
/// failed run is not tried again until `retry` (the route changed, or the person pressed).
@MainActor
public final class ReadyAhead {
    public enum State: Equatable, Sendable { case idle, running, ready, failed }

    public private(set) var state: State = .idle
    /// Why the last run failed, for the log.
    public private(set) var error: (any Error)?
    /// How long the last run took.
    public private(set) var took: Duration?
    private let work: @Sendable () throws -> Void

    public init(_ work: @escaping @Sendable () throws -> Void) {
        self.work = work
    }

    /// Starts the work, unless it runs, is done, or failed and was not retried.
    public func start() {
        guard state == .idle || state == .failed else { return }
        state = .running
        let started = ContinuousClock.now
        do {
            try work()
            state = .ready
        } catch {
            self.error = error
            state = .failed
        }
        took = ContinuousClock.now - started
    }

    /// Whether the work is done, once a run that has not ended has. Starts nothing.
    public func wait() async -> Bool {
        state == .ready
    }

    /// A failed run may be tried again by the next `start`: the route changed, or the
    /// person pressed. Does nothing otherwise.
    public func retry() {
        guard state == .failed else { return }
        state = .idle
    }
}

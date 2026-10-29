import Foundation

/// Slow set-up done ahead of the moment it is needed (P20261029-1).
///
/// Voice mode's echo cancellation takes about a second to switch on, and it is set up when
/// the first prompt bar draws, so that a press listens at once. On the main thread, that
/// second stopped the window at every launch. `start` runs `work` on a thread of its own;
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
    private var run: Task<Duration, any Error>?

    public init(_ work: @escaping @Sendable () throws -> Void) {
        self.work = work
    }

    /// Starts the work on a thread of its own and returns at once, unless it runs, is done,
    /// or failed and was not retried.
    public func start() {
        guard state == .idle else { return }
        state = .running
        let work = self.work
        let run = Task.detached(priority: .userInitiated) { () throws -> Duration in
            let started = ContinuousClock.now
            try work()
            return ContinuousClock.now - started
        }
        self.run = run
        Task { await settle(run) }
    }

    /// Whether the work is done, once a run that has not ended has. Starts nothing.
    public func wait() async -> Bool {
        if let run { await settle(run) }
        return state == .ready
    }

    private func settle(_ finished: Task<Duration, any Error>) async {
        let result = await finished.result
        // Settled already, by the other of `start` and `wait`.
        guard run == finished else { return }
        run = nil
        switch result {
        case .success(let took):
            self.took = took
            state = .ready
        case .failure(let error):
            self.error = error
            state = .failed
        }
    }

    /// A failed run may be tried again by the next `start`: the route changed, or the
    /// person pressed. Does nothing otherwise.
    public func retry() {
        guard state == .failed else { return }
        state = .idle
    }
}

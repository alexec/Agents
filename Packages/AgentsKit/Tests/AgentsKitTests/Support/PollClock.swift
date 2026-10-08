import Foundation

/// A clock for poll loops that a test moves by hand (#383): each `sleep` records how long
/// it was asked to wait, then waits for `tick()`. Cancelling a sleeper ends its wait.
final class PollClock: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [Duration] = []
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]

    /// Every wait asked for, in order.
    var asked: [Duration] { lock.withLock { waits } }
    /// How many are waiting for a tick now.
    var sleeping: Int { lock.withLock { sleepers.count } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { return done.resume(throwing: CancellationError()) }
                    lock.withLock {
                        waits.append(duration)
                        sleepers[id] = done
                    }
                }
            } onCancel: {
                lock.withLock { sleepers.removeValue(forKey: id) }?.resume(throwing: CancellationError())
            }
        }
    }

    /// Wake every sleeper.
    func tick() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let all = Array(sleepers.values)
            sleepers = [:]
            return all
        }
        for done in all { done.resume() }
    }
}

/// A wall clock a test moves by hand, for a core's `now`.
final class MovableNow: @unchecked Sendable {
    private let lock = NSLock()
    private var at = Date()

    var now: @Sendable () -> Date { { [self] in lock.withLock { at } } }

    func advance(_ seconds: TimeInterval) { lock.withLock { at = at.addingTimeInterval(seconds) } }
}

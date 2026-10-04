import Foundation

/// The loop that goes back for a host that went away, and what a call lost with the
/// connection waits on (#208).
///
/// Three things it holds to, each of which the Remote once got wrong:
///
/// - **It never waits on itself.** An attempt catches up, and catching up can send
///   (a start whose answer was lost). A send that then lost the link waited for the
///   reconnect loop it was running inside, which never ended, so the app never
///   reconnected until it was quit. A wait from inside the loop's own attempt now
///   answers false at once.
/// - **Every wait is bounded.** A send waits at most its patience for the host to come
///   back, then hears false; the loop goes on without it. The draft is kept, and the
///   send's `sendID` or `requestID` makes the person's retry the same send.
/// - **Stopped is for good.** A new pairing stops the old model's loop: nothing starts
///   it again, a wait in progress hears false, and an attempt in flight ends the loop.
///
/// The attempt and the clock are given, so all of it is tested without a device.
@MainActor
public final class ReconnectLoop {
    /// How one attempt went.
    public enum Outcome: Sendable, Equatable {
        /// Connected, and still connected once it had caught up.
        case connected
        /// No answer: wait, then try again.
        case failed
        /// Nothing to dial any more (forgotten by the control plane): the loop ends.
        case forgotten
    }

    public typealias Attempt = @MainActor () async -> Outcome
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let backoff: Backoff
    private let sleep: Sleep
    private let attempt: Attempt
    private var loop: Task<Void, Never>?
    /// Which loop is running, so a task inside an older one is not taken for inside this.
    private var generation = 0
    private var waiters: [Int: Waiter] = [:]
    private var nextWaiter = 0
    /// Set by `stop()`, and never cleared: this loop's owner has been replaced.
    public private(set) var isStopped = false

    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timer: Task<Void, Never>
    }

    /// The loop, and its run, a task is part of: set around each attempt and inherited by
    /// every task the attempt starts, so a send made from inside it is recognised.
    private struct Mark: Equatable, Sendable {
        let loop: ObjectIdentifier
        let generation: Int
    }
    @TaskLocal private static var inside: Mark?

    public init(backoff: Backoff, sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                attempt: @escaping Attempt) {
        self.backoff = backoff
        self.sleep = sleep
        self.attempt = attempt
    }

    /// Whether a loop is going back for the host now.
    public var isRunning: Bool { loop != nil }

    /// Whether the calling task is part of the running loop's own attempt.
    public var isInsideLoop: Bool {
        loop != nil && Self.inside == Mark(loop: ObjectIdentifier(self), generation: generation)
    }

    /// Keep trying until the host answers, or the owner is stopped or forgotten. A loop
    /// already running is left to it: this returns at once rather than waiting on it.
    public func run() async {
        guard let started = begin() else { return }
        await started.value
    }

    /// The host did not answer a call: wait for it to come back, at most `patience`.
    /// True when it is back. False at once from inside the loop's own attempt, which the
    /// loop would otherwise never finish; false once stopped; false when out of patience.
    public func waitForHost(within patience: Duration) async -> Bool {
        guard !isStopped, !isInsideLoop else { return false }
        guard loop != nil || begin() != nil else { return false }
        let id = nextWaiter
        nextWaiter += 1
        let sleep = self.sleep
        return await withCheckedContinuation { continuation in
            let timer = Task { [weak self] in
                try? await sleep(patience)
                guard !Task.isCancelled else { return }
                self?.settle(id, false)
            }
            waiters[id] = Waiter(continuation: continuation, timer: timer)
        }
    }

    /// End it for good: the loop is cancelled, every wait hears false, and nothing starts
    /// it again.
    public func stop() {
        isStopped = true
        loop?.cancel()
        loop = nil
        backoff.settle()
        for id in Array(waiters.keys) { settle(id, false) }
    }

    private func begin() -> Task<Void, Never>? {
        guard !isStopped, loop == nil else { return nil }
        generation += 1
        let mark = Mark(loop: ObjectIdentifier(self), generation: generation)
        let backoff = self.backoff
        let started = Task { [weak self] in
            var connected = false
            while !Task.isCancelled {
                guard let self, !self.isStopped else { return }
                backoff.trying()
                let outcome = await Self.$inside.withValue(mark) { await self.attempt() }
                if outcome == .connected { connected = true; break }
                if outcome == .forgotten || self.isStopped { break }
                await backoff.wait()
            }
            // Stopped or cancelled: `stop()` has already answered every wait.
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            // Back from the first wait only once this connection has lasted (#172).
            if connected { backoff.connected() } else { backoff.settle() }
            self.loop = nil
            for id in Array(self.waiters.keys) { self.settle(id, connected) }
        }
        loop = started
        return started
    }

    private func settle(_ id: Int, _ answer: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: answer)
    }
}

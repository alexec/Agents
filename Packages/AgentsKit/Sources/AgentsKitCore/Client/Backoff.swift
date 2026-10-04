import Foundation

/// The wait between tries to reach something that went away, which a wake or a network
/// change cuts short (#82).
///
/// A second, then twice as long each time up to `longest`. Without anything to cut it
/// short, a Mac that woke or a phone that found Wi-Fi sat out whatever was left of the
/// wait, up to half a minute, before it looked again.
///
/// `nudge()` is the something: the wait in progress ends now, and the next is a second
/// again. A nudge while a try is in flight does not start another beside it; it is kept,
/// and the wait after that try is skipped, because the try may have been doomed by the
/// very change the nudge is about.
///
/// Each wait is taken between half and all of its length at random (#172), by the same
/// `ReconnectSchedule` Agents Host's link waits by (#168): a host restart drops every
/// client at once, and without the spread they all came back in step. And a connection
/// is only trusted to reset the wait once it has lasted `healthyAfter`: one the far end
/// takes and drops at once (a host that is still starting, a control plane that admits
/// and then refuses) used to start every round from a second again.
public final class Backoff: @unchecked Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// What a nudge did.
    public enum Nudged: Equatable, Sendable {
        /// A wait was in progress, and is over.
        case cutShort
        /// A try was in flight: the wait after it, if it fails, is skipped.
        case afterThisTry
        /// Nothing was going on: no loop is going back for anything.
        case idle
    }

    public let first: Duration
    public let longest: Duration
    /// How long a connection must last before a later loss starts from `first` again.
    public let healthyAfter: Duration
    private let sleep: Sleep
    private let jitter: @Sendable () -> Double
    private let now: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    private var next: Duration
    private var state = State.idle
    private var nudgedDuringTry = false
    private var connectedAt: ContinuousClock.Instant?

    private enum State {
        case idle
        case trying
        case waiting(Task<Void, Never>, cutShort: Bool)
    }

    public init(first: Duration = .seconds(1), longest: Duration = .seconds(30),
                healthyAfter: Duration = .seconds(10),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                jitter: @escaping @Sendable () -> Double = ReconnectSchedule.randomJitter,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.first = first
        self.longest = longest
        self.healthyAfter = healthyAfter
        self.next = first
        self.jitter = jitter
        self.now = now
        self.sleep = sleep
    }

    public var schedule: ReconnectSchedule { ReconnectSchedule(first: first, longest: longest) }

    /// How long the next wait will be, before jitter: it is slept between half and all of it.
    public var nextWait: Duration { lock.withLock { next } }

    /// A try is starting. After a connection that lasted `healthyAfter`, from `first`.
    public func trying() {
        lock.withLock {
            endConnection()
            state = .trying
        }
    }

    /// Under the lock: the connection `connected()` noted is over, and if it lasted, the
    /// waits start again from the first.
    private func endConnection() {
        guard let connectedAt else { return }
        if now() - connectedAt >= healthyAfter { next = first }
        self.connectedAt = nil
    }

    /// Wait before the next try: the current wait, then double it for the one after.
    /// Ends early on a nudge, or when the calling task is cancelled.
    public func wait() async {
        let nap: Task<Void, Never>? = lock.withLock {
            if nudgedDuringTry {
                nudgedDuringTry = false
                state = .trying
                return nil
            }
            endConnection()
            let sleep = self.sleep
            let duration = ReconnectSchedule.jittered(next, jitter())
            let nap = Task<Void, Never> { try? await sleep(duration) }
            state = .waiting(nap, cutShort: false)
            return nap
        }
        guard let nap else { return }
        await withTaskCancellationHandler { await nap.value } onCancel: { nap.cancel() }
        lock.withLock {
            if case .waiting(_, true) = state {
                next = first
            } else {
                next = schedule.doubled(next)
            }
            state = .trying
        }
    }

    /// No longer going back: the next loss starts from the first wait.
    public func settle() {
        lock.withLock {
            next = first
            nudgedDuringTry = false
            connectedAt = nil
            state = .idle
        }
    }

    /// Connected. The next loss starts from the first wait if this connection lasted
    /// `healthyAfter`, and from where the waits had got to if it did not.
    public func connected() {
        lock.withLock {
            nudgedDuringTry = false
            connectedAt = now()
            state = .idle
        }
    }

    /// The device woke, or the network changed: try now.
    @discardableResult
    public func nudge() -> Nudged {
        let (nudged, nap): (Nudged, Task<Void, Never>?) = lock.withLock {
            next = first
            switch state {
            case .idle:
                return (.idle, nil)
            case .trying:
                nudgedDuringTry = true
                return (.afterThisTry, nil)
            case .waiting(let nap, _):
                state = .waiting(nap, cutShort: true)
                return (.cutShort, nap)
            }
        }
        nap?.cancel()
        return nudged
    }
}

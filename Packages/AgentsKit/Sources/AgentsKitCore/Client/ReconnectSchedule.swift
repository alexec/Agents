import Foundation

/// How long anything that lost its connection waits before it dials again: the same for
/// every client, so that none of them storms (#168, #172).
///
/// `first`, then twice as long after each failure up to `longest`, each wait taken
/// between half and all of that at random. Without the spread, everything that lost a
/// host at the same moment (a restart drops the window, the Remote, the bridge and every
/// helper together) dialled again in step, and the refusals of a full listen backlog
/// came in step with them.
public struct ReconnectSchedule: Sendable, Equatable {
    public var first: Duration
    public var longest: Duration

    public init(first: Duration, longest: Duration) {
        self.first = first
        self.longest = longest
    }

    /// The wait before the try after `failures` failed ones (1 or more), before jitter.
    public func nominal(afterFailures failures: Int) -> Duration {
        var wait = first
        for _ in 1..<max(failures, 1) {
            wait = min(wait * 2, longest)
            if wait == longest { break }
        }
        return min(wait, longest)
    }

    /// The wait that follows `wait`.
    public func doubled(_ wait: Duration) -> Duration { min(wait * 2, longest) }

    /// `wait` spread over its upper half: `jitter`, from 0 to 1 (clamped), picks the point
    /// between half and all of it.
    public static func jittered(_ wait: Duration, _ jitter: Double) -> Duration {
        wait * (0.5 + 0.5 * min(max(jitter, 0), 1))
    }

    public static func randomJitter() -> Double { .random(in: 0...1) }
}

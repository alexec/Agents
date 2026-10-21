import Foundation

/// When a chat paused by a spent allowance carries on by itself (#1859). The daemon keeps
/// it on the agent's record and sends "continue" in the same chat at `at`, or as soon as a
/// turn on that runtime works or the person marks it available.
public struct ContinueWhenBack: Codable, Hashable, Sendable {
    /// The provider's reset time, or the app's next check of the runtime.
    public var at: Date
    /// Whether `at` is the time the provider said; false when it is only the next check.
    public var resetKnown: Bool

    public init(at: Date, resetKnown: Bool) {
        self.at = at
        self.resetKnown = resetKnown
    }
}

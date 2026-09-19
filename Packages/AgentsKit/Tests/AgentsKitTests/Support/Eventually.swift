import Foundation
import Testing
@testable import AgentsKit

/// Wait for something to become true, rather than sleeping long enough that it usually
/// has.
///
/// Almost everything in this suite crosses a boundary that takes an unknowable moment:
/// the daemon broadcasts on another task, a runtime answers on its own queue, a
/// workflow fires detached, a `DispatchSource` wakes when the kernel gets round to it.
/// The tempting way to test that is to sleep for longer than it usually takes and then
/// assert. It works on a quiet machine and it is why this suite failed a different
/// test on every run: under a full parallel suite, "usually" stops being true, and the
/// sleep that was three times the typical wait is suddenly half the real one.
///
/// A poll is not slower in practice. The timeout is generous because it is only ever
/// reached when the test is failing anyway; the ordinary path returns on the first or
/// second look, which makes the suite quicker than the sleeps it replaces.
///
/// What this does **not** replace is a sleep that proves a thing did *not* happen.
/// Those are honest: there is no condition to wait for, and time passing is the whole
/// assertion. They are also not a source of flakiness — a slow machine makes them pass
/// more readily, not less.
enum Eventually {
    /// How long to keep looking before giving up. Generous on purpose: it costs
    /// nothing when the condition holds and is only paid by a test that was going to
    /// fail.
    static let timeout = Duration.seconds(10)

    /// How often to look. Short enough to feel instant, long enough not to spin.
    static let interval = Duration.milliseconds(10)
}

/// Wait until `condition` holds, or record a failure.
///
/// - Parameter description: what was being waited for, said in the failure. Worth
///   filling in: "the agent finished" reads better in a log than "condition never
///   held".
@discardableResult
func eventually(_ description: @autoclosure @Sendable () -> String = "the condition",
                within: Duration = Eventually.timeout,
                sourceLocation: SourceLocation = #_sourceLocation,
                _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: within)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: Eventually.interval)
    }
    // One last look. Between the final sleep and the clock check there is a window in
    // which the condition can come true, and a test that fails in it fails for no
    // reason the reader can act on.
    if await condition() { return true }
    Issue.record("\(description()) never became true, waited \(within)",
                 sourceLocation: sourceLocation)
    return false
}

/// Wait until `produce` returns something, and hand it back.
///
/// The optional-shaped half of `eventually`, for the common case of waiting for a
/// notification or a record to appear and then asserting things about it. Returns nil
/// having already recorded the failure, so a caller can `guard` without reporting it
/// twice.
func eventuallySome<T: Sendable>(_ description: @autoclosure @Sendable () -> String = "a value",
                                 within: Duration = Eventually.timeout,
                                 sourceLocation: SourceLocation = #_sourceLocation,
                                 _ produce: @Sendable () async -> T?) async -> T? {
    let deadline = ContinuousClock.now.advanced(by: within)
    while ContinuousClock.now < deadline {
        if let found = await produce() { return found }
        try? await Task.sleep(for: Eventually.interval)
    }
    if let found = await produce() { return found }
    Issue.record("\(description()) never arrived, waited \(within)",
                 sourceLocation: sourceLocation)
    return nil
}

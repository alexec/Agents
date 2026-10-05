import Foundation
import Testing

/// Wait for `work` to finish, or record that it did not and stop waiting.
///
/// For an await with nothing of its own to end it: a stream that should finish, a close
/// that should complete. Left unbounded, one that never comes holds the test, and the
/// whole run with it, with nothing to say where (#225). Bounded, the test fails in its
/// own name and says what it was waiting for.
///
/// `work` is cancelled at the limit, so it must be something that ends on cancellation,
/// as iterating an `AsyncStream` does.
///
/// - Returns: whether it finished.
@discardableResult
func finishes(_ description: @autoclosure @Sendable () -> String,
              within limit: Duration = Eventually.timeout,
              sourceLocation: SourceLocation = #_sourceLocation,
              _ work: @escaping @Sendable () async -> Void) async -> Bool {
    let finished = await withTaskGroup(of: Bool.self) { group in
        group.addTask { await work(); return true }
        group.addTask { try? await Task.sleep(for: limit); return false }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    if !finished {
        Issue.record("\(description()) did not finish, waited \(limit)", sourceLocation: sourceLocation)
    }
    return finished
}

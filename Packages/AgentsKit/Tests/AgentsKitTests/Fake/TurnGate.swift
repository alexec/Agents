import Foundation

/// Holds a fake agent's turn open until the test says it may end.
///
/// A turn that lasts a fixed stretch of real time (`Script.turnDelay`) is a race with
/// the test: on a busy machine the turn is over before the test has done the thing it
/// meant to do while it was running, and the test fails for no reason in the code. A
/// gated turn cannot end until `open()` is called, however slow the machine.
///
/// Once opened it stays open: every turn waiting on it ends, and so does every later
/// one. A test that wants a second turn held opens a second gate.
final class TurnGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0

    /// Let every turn held here end, now and from now on.
    func open() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in resumed { continuation.resume() }
    }

    /// How many turns have reached the gate, so a test can know a turn is under way.
    var turnsArrived: Int { lock.withLock { arrivals } }

    /// Called by the fake agent: returns when the gate is open.
    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed: Bool = lock.withLock {
                arrivals += 1
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }
}

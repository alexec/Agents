import Foundation

/// The one claim on the Mac's idle sleep.
///
/// At most one is ever held, however many agents are working (FR-006). Not a pool, not
/// one per agent: the Mac is either being held awake or it is not.
///
/// A protocol so a test can assert *taken once*, *released once*, and — the one that
/// matters — *never taken at all* for an agent that is only waiting on a person.
public protocol Wakefulness: AnyObject, Sendable {
    func hold(reason: String)
    func release()
}

/// The real one.
///
/// `beginActivity` with `.idleSystemSleepDisabled` and **nothing else**. Adding
/// `.idleDisplaySleepDisabled` would break FR-007: the screen is not ours to hold, and
/// a Mac working through the night is meant to be a dark, locked Mac.
///
/// Two things were verified in a spike before this was planned, both in
/// `specs/024-keep-host-awake/research.md` §1–§2:
///
/// 1. This works from a process shaped like `agentsd` — no AppKit, no `NSApplication`,
///    no run loop, no entitlement. That is the fact the whole feature rests on, because
///    the window is precisely what is not there when the person has walked away.
/// 2. The `reason` string is carried verbatim into `pmset -g assertions`, so it is
///    written for a person reading a terminal at midnight rather than for a log.
public final class ProcessInfoWakefulness: Wakefulness, @unchecked Sendable {
    /// Guards `token`. `hold` and `release` are called from the daemon actor today, but
    /// this type is a `class` handed about as an existential and is cheap to make safe
    /// on its own terms rather than by assumption.
    private let lock = NSLock()
    private var token: (any NSObjectProtocol)?

    public init() {}

    public func hold(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        // Holding while already held does nothing. `reviseWakefulness` leans on this
        // and on the matching no-op in `release`: without them, the second call would
        // begin a second activity and drop the first token on the floor, and the
        // assertion would leak for the lifetime of the process.
        guard token == nil else { return }
        #if canImport(Darwin)
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled], reason: reason)
        #endif
        // A Linux server has no idle sleep to hold off (037): nothing to take.
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard let held = token else { return }
        token = nil
        #if canImport(Darwin)
        ProcessInfo.processInfo.endActivity(held)
        #endif
    }

    deinit {
        // An abandoned holder inside a **live** process, which is a different case
        // from the one below and needs the opposite treatment. The kernel only drops
        // assertions when the process dies; a `DaemonCore` that is simply let go —
        // which happens hundreds of times in a test run — would otherwise leave its
        // assertion held for the life of the process that made it.
        //
        // In production there is one core per process and this never fires before
        // exit. It is here so that running the suite does not quietly keep the
        // developer's Mac awake.
        #if canImport(Darwin)
        if let held = token { ProcessInfo.processInfo.endActivity(held) }
        #endif
    }

    // No cleanup path anywhere for a hold left behind by
    // a daemon that died.
    //
    // This is deliberate and it is verified: the kernel owns the assertion and drops it
    // when the process dies, however it dies. Verified with `kill -9` — the assertion
    // was gone from `pmset -g assertions` immediately, with nothing to clear up
    // (research.md §2, FR-013).
    //
    // So there is nothing to persist, nothing to sweep at start-up, and nothing to
    // reconcile. The instinct to write that recovery code is strong; every line of it
    // would be a liability, because the only thing it could do is act on a record of a
    // hold that no longer exists (024 T027).
}

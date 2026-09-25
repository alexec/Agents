import Foundation

extension DaemonCore {
    /// What counts as work in hand.
    ///
    /// A permission waiting on an answer counts, and that is the point: the question
    /// can arrive while no window is open, and something has to stay alive holding it.
    ///
    /// **Not to be confused with `hasWorkInFlight`** (`DaemonCore+Wakefulness.swift`),
    /// which is one line long, looks like this one, and deliberately answers the
    /// opposite way about the very state named above. This asks *may the daemon exit*,
    /// so an agent blocked on a person counts — exiting under an unanswered question
    /// would abandon it. That one asks *is the CPU busy*, so the same agent does not
    /// count: holding the Mac awake all night for a permission prompt nobody answered
    /// is the one thing 024 must not do.
    ///
    /// Neither is a bug to be fixed into the other. The pair is cross-referenced in
    /// both directions on purpose, because whoever finds only one of them will assume
    /// the other is a mistake (024 FR-003).
    public var isHoldingAgents: Bool {
        if !live.isEmpty { return true }
        // An agent on its way back up after a restart has no runtime yet and is not in
        // any state that says it is busy. Exiting under one would abandon the work a
        // moment before picking it up again.
        if !resuming.isEmpty { return true }
        if !pendingPermissions.isEmpty { return true }
        if !drafts.isEmpty { return true }
        // A queued prompt whose runtime is still starting. Nothing is in `live` yet
        // and the agent reads as settled, so without this a slow start with no window
        // open lets the daemon go, and the words are never sent.
        if !sending.isEmpty { return true }
        // A shell with a build running in it is work, the same as an agent mid-turn.
        // Exiting under one would kill the build, which is the whole thing FR-026
        // promises will not happen (FR-027).
        if shells.busyCount > 0 { return true }
        // A clone with no window open is still somebody's project on its way. Exiting
        // under it would throw the download away (027).
        if !clones.isEmpty { return true }
        // Somebody waiting for a lease (036). Only a running daemon can let them
        // through when it comes free, so a line keeps it up. A lease nobody is waiting
        // for does not: when it runs out there is nothing to do but free it, and the
        // next daemon to start does that as it reads the book (research R10).
        if leaseBook.hasWaiters { return true }
        // An agent waiting on events (042). Nothing but a running daemon can hear its
        // event, and a daemon that goes takes the Mac's wake, a pull request's change
        // and every other agent's news with it.
        if agents.values.contains(where: { $0.eventWait?.isOpen == true }) { return true }
        return agents.values.contains { $0.state.holdsRuntime }
    }

    public var shouldExit: Bool {
        connectionCount == 0 && !isHoldingAgents
    }

    /// Wait until there is nothing left to do and nobody watching.
    ///
    /// The grace period is there so that quitting the app and opening it again does not
    /// race the daemon out of existence, and so an agent that finishes with no window
    /// open leaves a moment for one to appear.
    public func runUntilIdle(grace: Duration = .seconds(10),
                             checkEvery: Duration = .milliseconds(500)) async {
        var idleSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            // The same tick that asks whether to exit also lets go of shells nobody
            // has touched for hours (FR-028).
            reapIdleShells()
            if shouldExit {
                let start = idleSince ?? ContinuousClock.now
                idleSince = start
                if ContinuousClock.now - start >= grace { return }
            } else {
                idleSince = nil
            }
            try? await Task.sleep(for: checkEvery)
        }
    }
}

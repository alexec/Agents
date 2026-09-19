import Foundation

extension DaemonCore {
    /// What counts as work in hand.
    ///
    /// A permission waiting on an answer counts, and that is the point: the question
    /// can arrive while no window is open, and something has to stay alive holding it.
    public var isHoldingAgents: Bool {
        if !live.isEmpty { return true }
        if !pendingPermissions.isEmpty { return true }
        if !drafts.isEmpty { return true }
        // A shell with a build running in it is work, the same as an agent mid-turn.
        // Exiting under one would kill the build, which is the whole thing FR-026
        // promises will not happen (FR-027).
        if shells.busyCount > 0 { return true }
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

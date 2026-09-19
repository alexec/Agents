import Foundation

extension DaemonCore {
    /// Read the record and tell the truth about it.
    ///
    /// The daemon owns every agent process, so a daemon that has only just started owns
    /// none: anything the record calls running or waiting died with the last daemon, or
    /// with the logout, or with the Mac. Those become stopped, with `daemonGone` saying
    /// which kind of ending it was.
    ///
    /// This runs before the socket accepts anything, so no window ever sees a state we
    /// already know to be a lie.
    @discardableResult
    public func recover() async -> [UUID] {
        await loadFromDisk()
        var recovered: [UUID] = []
        for (id, agent) in agents where agent.state.holdsRuntime {
            var updated = agent
            updated.state = .stopped
            updated.endedReason = .daemonGone
            agents[id] = updated
            try? await store.save(updated)
            await record(.runtimeNote("This agent was working when the daemon stopped, so it stopped too. Send it a message to pick it up."),
                         for: id)
            await record(.stateChanged(.stopped, reason: .daemonGone), for: id)
            recovered.append(id)
        }
        return recovered
    }
}

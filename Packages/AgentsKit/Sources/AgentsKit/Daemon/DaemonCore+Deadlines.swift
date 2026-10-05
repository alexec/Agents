import Foundation

/// A turn whose runtime has gone silent (#166).
///
/// The handshake, a new session and a pick-up each have a deadline on the call itself
/// (`ACPSession`); a turn cannot, because a turn can rightly take hours. What it cannot
/// rightly do is say nothing at all with nothing pending — no tool call open, no question
/// on the person, no command the app is running for it — for as long as `silence`. That
/// runtime is ended, the agent says why, and its running place is given back.
///
/// One watch for every turn rather than one per turn: it runs while a turn does, looks
/// at each in turn, and stops when there are none.
extension DaemonCore {
    /// Started with every turn; a no-op while the watch is already going.
    func watchForSilence() {
        guard silenceWatch == nil else { return }
        silenceWatch = Task { [weak self] in
            while !Task.isCancelled, let pause = await self?.lookForSilence() {
                try? await Task.sleep(for: pause)
            }
        }
    }

    /// One look at every turn under way. The pause before the next, or nil once there is
    /// no turn to watch, which ends the watch. Looked at from `instant`, which is now
    /// unless a test looks from later rather than waiting (#225).
    func lookForSilence(at instant: ContinuousClock.Instant = .now) async -> Duration? {
        let watched = turnTasks.keys.compactMap { id in live[id].map { (id, $0) } }
        guard !watched.isEmpty else {
            silenceWatch = nil
            return nil
        }
        for (id, session) in watched where !silencedTurns.contains(id) {
            guard let quiet = await session.silence(at: instant), quiet >= session.deadlines.silence,
                  live[id] === session, turnTasks[id] != nil else { continue }
            await endSilentTurn(id, session: session)
        }
        // Often enough to end one within a quarter of its deadline, and at most a minute.
        let shortest = watched.map { $0.1.deadlines.silence }.min() ?? .seconds(60)
        return min(shortest / 4, .seconds(60))
    }

    /// Said first, then ended. Ending the process fails the turn's `session/prompt`, and
    /// the turn's failure does the rest as for any runtime that falls over: the ending,
    /// the running place, the runtime let go (#163), what was queued.
    private func endSilentTurn(_ agentID: UUID, session: ACPSession) async {
        silencedTurns.insert(agentID)
        let name = agents[agentID].flatMap { RuntimeCatalog.runtime(id: $0.runtimeID)?.name } ?? "The runtime"
        let late = RuntimeDidNotAnswer(phase: .turn, after: session.deadlines.silence)
        await record(.runtimeNote(RuntimeNote.endedLate(name, late)), for: agentID)
        DaemonLog.shared.write("agent \(agentID): \(late) with nothing pending; ending it")
        await session.end(gracePeriod: .seconds(2))
    }
}

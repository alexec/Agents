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
    /// already know to be a lie. Bringing them back is `pickUpAfterRestart`, which runs
    /// after it, for the opposite reason.
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
            // What it was doing, kept for as long as it takes to tell it: an agent cut
            // off mid-turn and one cut off holding a question open have different
            // things to be told.
            interrupted[id] = agent.state
            await record(.runtimeNote("This agent was working when the daemon stopped, so it stopped too."),
                         for: id)
            await record(.stateChanged(.stopped, reason: .daemonGone), for: id)
            recovered.append(id)
        }
        return recovered
    }

    /// Start every agent the last daemon was holding, and tell each one what happened.
    ///
    /// `recover` is the truth about the moment the daemon came back: they stopped,
    /// because their processes did. This is the other half of it. Nobody decided to
    /// abandon that work — an update, a crash, a Mac restarted underneath it — so the
    /// agent is picked back up rather than left sitting there for somebody to notice.
    ///
    /// Nothing here is a special kind of restart. It sends the agent a prompt, and
    /// `prompt` already knows how to start a runtime, continue the conversation and
    /// begin a turn, exactly as it does when the words are typed. What the prompt says
    /// is that the app restarted, because an agent picking up a turn it cannot remember
    /// the end of needs telling why what it was doing stops half way down the page.
    ///
    /// It returns at once and the work happens behind it: starting a runtime takes
    /// seconds, and the socket is open by now, so a window watches them come back
    /// rather than connecting to find it already over.
    public func pickUpAfterRestart(_ ids: [UUID]) {
        let mine = ids.filter { interrupted[$0] != nil }
        guard !mine.isEmpty else { return }
        // Marked before anything is awaited. `isHoldingAgents` reads this, and until a
        // runtime is up there is nothing else to say these agents are work in hand —
        // an idle daemon would otherwise exit out from under the restart.
        resuming.formUnion(mine)
        Task { await pickUpEachInTurn(mine) }
    }

    /// One at a time, in the order they were found. Half a dozen runtimes starting at
    /// once is half a dozen node processes, and a Mac that notices.
    private func pickUpEachInTurn(_ ids: [UUID]) async {
        for id in ids {
            await pickUp(id)
            resuming.remove(id)
        }
    }

    private func pickUp(_ id: UUID) async {
        guard let was = interrupted.removeValue(forKey: id) else { return }
        // Archived since, deleted since, or already spoken to by somebody who got here
        // first. Any of those and this is not ours to do.
        guard let agent = agents[id], agent.state == .stopped,
              agent.endedReason == .daemonGone, agent.queuedPrompts.isEmpty else { return }
        let text = Self.wordsAboutTheRestart(was)
        do {
            try await prompt(DaemonAPI.PromptRequest(agentID: id, text: text))
            DaemonLog.shared.write("picked agent \(id) back up after the restart")
        } catch {
            let why = (error as? JSONRPCError)?.message ?? error.localizedDescription
            // The words go back out of the queue. They are about this minute — an agent
            // told next week that the app has just restarted is being told something
            // untrue — so a prompt that could not be sent now is not one to keep.
            if var agent = agents[id] {
                agent.queuedPrompts.removeAll { $0.text == text }
                changed(agent)
            }
            await record(.runtimeNote("Could not pick this agent back up: \(why) Send it a message to pick it up yourself."),
                         for: id)
            DaemonLog.shared.write("could not pick agent \(id) back up: \(why)")
        }
    }

    /// What an agent is told about its own restart.
    ///
    /// In brackets and in the app's voice, the way a workflow says why it started
    /// something: it is the app talking, not the user, and an agent reading its own
    /// history back should be able to tell which.
    static func wordsAboutTheRestart(_ was: AgentState) -> String {
        switch was {
        case .waitingOnUser:
            return """
                (The app restarted while you were waiting for an answer, so the turn you were in the middle of was cut off and the question you had asked went with it. Everything above is still yours. Ask it again if you still need it; otherwise carry on from where you left off, checking what you had actually finished rather than assuming the last thing you tried worked.)
                """
        default:
            return """
                (The app restarted while you were working, so the turn you were in the middle of was cut off. Everything above is still yours. Carry on from where you left off, checking what you had actually finished rather than assuming the last thing you tried worked.)
                """
        }
    }
}

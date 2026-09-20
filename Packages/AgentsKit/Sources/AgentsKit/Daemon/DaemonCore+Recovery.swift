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
    ///
    /// Every ending here goes through `move`, the same as every other ending in the
    /// app. It did not always: this loop used to write the state and the reason by
    /// hand, for two good reasons that are now rules the transition itself knows —
    /// `daemonGone` never clears the pick-up count, and an agent about to be picked
    /// back up fires no stopped trigger. What that bypass cost was every *other*
    /// consequence of an ending, so a workflow set to run when an agent stops did not
    /// run when six agents stopped because the Mac restarted.
    @discardableResult
    public func recover() async -> [UUID] {
        await loadFromDisk()
        // `agents` is a Dictionary, whose order is nobody's. Most recently active
        // first, because pick-up is one at a time and the chat the person last left
        // running should not wait behind every runtime ahead of it.
        //
        // `holdsRuntime` sweeps up `starting` for free, which is FR-007: an agent cut
        // off before its first turn began had its process die with the last daemon in
        // exactly the way a working one did, and is owed the same ending.
        let wereWorking = agents.values
            .filter { $0.state.holdsRuntime }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        var recovered: [UUID] = []
        for agent in wereWorking {
            let id = agent.id
            // Before the move, so the transcript reads in the order it happened: the
            // explanation, and then the ending it explains.
            await record(.runtimeNote("This agent was working when the daemon stopped, so it stopped too."),
                         for: id)
            // Through the funnel, like every other ending. This is the whole of what
            // 020 closes: the record, the broadcast, the transcript line, the project
            // counts and the triggers all happen here now, because they all hang off
            // `move` and this is no longer the one caller that went round it.
            await move(id, on: .foundDead)
            // Re-read: `mayBePickedUpAfterRestart` is a question about the record
            // after the ending, not the one this loop was handed.
            guard let updated = agents[id] else { continue }
            // A chat brought back last time and cut off again before it reached the
            // end of a turn is the likeliest reason this daemon went. It keeps the
            // ending it actually had — `daemonGone` is what happened to it — and why
            // it was left where it is goes in the transcript instead.
            guard updated.mayBePickedUpAfterRestart else {
                await record(.runtimeNote("This agent was picked back up after the last restart and did not get to the end of a turn, so it has been left alone this time. Send it a message to start it again."),
                             for: id)
                DaemonLog.shared.write("left agent \(id) alone: already picked back up once without finishing a turn")
                continue
            }
            // What it was doing, kept for as long as it takes to tell it: an agent cut
            // off mid-turn and one cut off holding a question open have different
            // things to be told.
            interrupted[id] = agent.state
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
        // The whole batch at once, before any of it begins, so a window shows every
        // chat that is coming back rather than lighting them one row at a time.
        for id in mine { sayResuming(id, true) }
        Task { await pickUpEachInTurn(mine) }
    }

    /// One at a time, most recently active first, which is the order `recover`
    /// returns them in. Half a dozen runtimes starting at once is half a dozen node
    /// processes, and a Mac that notices — and while they queue, the chat the person
    /// was last watching is the one worth having back first.
    private func pickUpEachInTurn(_ ids: [UUID]) async {
        for id in ids {
            // Withdrawn by `stop` while it waited its turn. Nothing to pick up, and
            // it has already been said to have left the queue.
            guard resuming.contains(id) else { continue }
            await pickUp(id)
            leaveTheQueue(id)
        }
    }

    /// Out of the queue, and said to be out of it. Every `true` is followed by a
    /// `false`, which is what the contract promises a window that is drawing a chat
    /// as coming back.
    func leaveTheQueue(_ id: UUID) {
        guard resuming.remove(id) != nil else { return }
        sayResuming(id, false)
    }

    /// Everything still queued to be picked back up. What `agents/resuming` answers.
    public func stillResuming() -> [UUID] { Array(resuming) }

    func sayResuming(_ id: UUID, _ isResuming: Bool) {
        broadcast(DaemonAPI.Notification.agentResuming,
                  DaemonAPI.ResumingNotification(agentID: id, isResuming: isResuming))
    }

    private func pickUp(_ id: UUID) async {
        guard let was = interrupted.removeValue(forKey: id) else { return }
        // Archived since, deleted since, or started again by somebody who got here
        // first: any turn since would have moved the state off `.stopped` or the
        // reason off `daemonGone`. Words already queued are *not* a reason to stand
        // down — `prompt` appends every prompt to `queuedPrompts`, so testing that
        // once meant a chat somebody had typed at was silently never brought back.
        guard var agent = agents[id], agent.mayBePickedUpAfterRestart else { return }
        // An agent cut off before its first turn is the one case with nothing to
        // explain: its conversation never began, so there is no interruption to
        // describe and nothing above for it to carry on from. What it needs is the
        // words it was created with, which are still on its queue — sending a note
        // about the restart first would spend a whole turn saying nothing.
        //
        // A `starting` record written before those words were queued has an empty
        // queue, and still gets the note, which is why that arm of
        // `wordsAboutTheRestart` exists.
        let stillHasItsFirstWords = was == .starting && !agent.queuedPrompts.isEmpty
        let text = Self.wordsAboutTheRestart(was)
        // Written down before the words go, never after. A daemon killed part-way
        // through starting a runtime has already recorded that it tried, and the next
        // daemon does not try the same chat again.
        agent.restartPickUps += 1
        changed(agent)
        do {
            if stillHasItsFirstWords {
                try await sendNextQueued(to: id)
            } else {
                try await promptFirst(DaemonAPI.PromptRequest(agentID: id, text: text))
            }
            DaemonLog.shared.write("picked agent \(id) back up after the restart")
        } catch {
            let why = (error as? JSONRPCError)?.message ?? error.localizedDescription
            // The words go back out of the queue. They are about this minute — an agent
            // told next week that the app has just restarted is being told something
            // untrue — so a prompt that could not be sent now is not one to keep.
            // Only our own words. What the person typed stays where it is — it was
            // never about this minute, and losing it is the thing this whole path
            // exists to prevent.
            if !stillHasItsFirstWords, var agent = agents[id] {
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
        case .starting:
            // Cut off before its first turn began, so there is nothing above for it to
            // carry on from — every other arm here tells the agent its turn was
            // interrupted and that what is above is still its own, and both halves of
            // that would be false. This switch has a `default:` and would have
            // compiled silently; it was visited by hand.
            return """
                (The app restarted before this conversation had begun, so nothing you were asked has reached you until now. There is no history above this — start the work from here.)
                """
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

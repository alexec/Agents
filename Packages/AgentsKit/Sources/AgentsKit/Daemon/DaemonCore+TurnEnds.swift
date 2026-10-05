import Foundation

/// How long a runtime is given to end its turn after the agent has called `finish_turn`
/// (#139). Claude's adapter ends the prompt by itself within a second or two of the
/// call, and these never come into it.
public struct FinishGrace: Sendable {
    /// Quiet after the call, or after the last words or thoughts that followed it,
    /// before the app ends the turn. Words reset it, so a closing message is never cut
    /// off half way; a tool call does not, because a tool call is the agent carrying on.
    public var quiet: Duration = .seconds(10)
    /// The most a turn is given after the call, however much it is still saying.
    public var longest: Duration = .seconds(60)
    /// How long a runtime asked to cancel has to answer before the app stops waiting
    /// for it and ends the turn without its answer.
    public var afterCancel: Duration = .seconds(10)

    public init(quiet: Duration = .seconds(10), longest: Duration = .seconds(60),
                afterCancel: Duration = .seconds(10)) {
        self.quiet = quiet
        self.longest = longest
        self.afterCancel = afterCancel
    }
}

/// A turn whose agent has said it is over, while its runtime is still in it.
struct FinishedTurn {
    /// The turn the call was made in: a later turn is never ended for it.
    let turn: Task<Void, Never>
    let reportedAt: ContinuousClock.Instant
    /// The call, or the last words or thoughts after it.
    var heardAt: ContinuousClock.Instant
    /// Set once the app has asked the runtime to cancel, so the `cancelled` it answers
    /// with reads as the turn the agent ended, not one somebody stopped.
    var cancelled = false
    var watch: Task<Void, Never>?
}

/// `finish_turn` ends the turn, on every runtime (#139).
///
/// Claude's adapter ends the prompt soon after the call. Copilot, Codex and OpenCode
/// did not: Codex went into its own `wait` with nothing to wait on, OpenCode worked on
/// for six minutes, and until the prompt came back the agent read as working, held a
/// running place, and nobody waiting on it was resumed. So the app ends the turn when
/// the agent says it is over: given a moment for a closing message, it sends
/// `session/cancel`, takes the `cancelled` that comes back as the ordinary ending, and
/// if even that does not come, ends the turn without it.
extension DaemonCore {
    /// Called when an ending has been recorded. Nothing to do when no turn is in flight
    /// (a report from between turns), and a second call in the same turn counts as
    /// something heard, not a new clock.
    func watchTheEnd(of agentID: UUID) {
        guard let turn = turnTasks[agentID], live[agentID] != nil else { return }
        let now = ContinuousClock.now
        if var watched = finishedTurns[agentID], watched.turn == turn {
            watched.heardAt = now
            finishedTurns[agentID] = watched
            return
        }
        finishedTurns.removeValue(forKey: agentID)?.watch?.cancel()
        var watched = FinishedTurn(turn: turn, reportedAt: now, heardAt: now)
        watched.watch = Task { [weak self] in await self?.endTheTurnIfStillGoing(agentID, turn: turn) }
        finishedTurns[agentID] = watched
    }

    /// Words or thoughts from a turn the agent has already ended: a closing message is
    /// given its time.
    func heardAfterTheEnd(_ kind: TranscriptEntry.Kind, agentID: UUID) {
        guard finishedTurns[agentID]?.cancelled == false else { return }
        switch kind {
        case .agentMessage, .agentThought: finishedTurns[agentID]?.heardAt = .now
        default: break
        }
    }

    /// Let the watch go: the turn ended, was stopped, or another began. Says whether the
    /// app had asked the runtime to cancel it.
    @discardableResult
    func endWatch(_ agentID: UUID) -> Bool {
        guard let watched = finishedTurns.removeValue(forKey: agentID) else { return false }
        watched.watch?.cancel()
        return watched.cancelled
    }

    /// Whether the app's own ending has already been given for this session's turn, so
    /// the prompt's late answer is let go. Asked once per answer.
    func turnAlreadyEnded(for session: ACPSession) -> Bool {
        endedForTheRuntime.remove(ObjectIdentifier(session)) != nil
    }

    private func endTheTurnIfStillGoing(_ agentID: UUID, turn: Task<Void, Never>) async {
        let clock = ContinuousClock()
        while true {
            guard !Task.isCancelled, let watched = finishedTurns[agentID], turnTasks[agentID] == turn else { return }
            if let finishQuietWait {
                // The test's quiet: words heard while it waited start it again.
                await finishQuietWait()
                if finishedTurns[agentID]?.heardAt == watched.heardAt { break }
                continue
            }
            let due = min(watched.heardAt + finishGrace.quiet, watched.reportedAt + finishGrace.longest)
            if clock.now >= due { break }
            try? await clock.sleep(until: due)
        }
        guard !Task.isCancelled, turnTasks[agentID] == turn, let session = live[agentID] else { return }
        finishedTurns[agentID]?.cancelled = true
        let runtimeName = agents[agentID].flatMap { RuntimeCatalog.runtime(id: $0.runtimeID)?.name } ?? "The runtime"
        DaemonLog.shared.write("agent \(agentID): \(runtimeName) still in its turn after finish_turn; cancelling it")
        await record(.runtimeNote("\(runtimeName) was still going after the agent ended its turn, so the app ended it there."),
                     for: agentID)
        await refuseOpenQuestions(of: agentID, on: session)
        await session.cancel()
        try? await clock.sleep(for: finishGrace.afterCancel)
        guard !Task.isCancelled, turnTasks[agentID] == turn, finishedTurns[agentID] != nil else { return }
        // Not even a cancel ended it (Codex in its own `wait` may not hear one). The turn
        // is ended here, and the runtime let go with it, as an ending of its own would.
        DaemonLog.shared.write("agent \(agentID): \(runtimeName) did not answer the cancel; ending the turn without it")
        endedForTheRuntime.insert(ObjectIdentifier(session))
        turnTasks.removeValue(forKey: agentID)
        // Taken off without cancelling it: this is that task, and the ending below
        // has awaits of its own that a cancelled task would cut short.
        finishedTurns.removeValue(forKey: agentID)
        await finishTurn(agentID: agentID, result: TurnResult(reason: .endTurn, rawStopReason: nil))
    }

    /// A question the agent asked after it said it was done goes unanswered, as it would
    /// on a stop: said in the conversation, taken off every screen, refused to the runtime.
    private func refuseOpenQuestions(of agentID: UUID, on session: ACPSession) async {
        for (id, pending) in pendingPermissions where pending.agentID == agentID {
            pendingPermissions.removeValue(forKey: id)
            await record(.runtimeNote(RuntimeNote.questionWentUnanswered), for: agentID)
            await session.answerPermission(id: pending.request.id, optionID: nil)
            broadcast(DaemonAPI.Notification.agentPermission,
                      DaemonAPI.PermissionNotification(agentID: agentID, request: nil, requestID: id))
        }
        for (id, pending) in elicitations where pending.agentID == agentID {
            elicitations.removeValue(forKey: id)
            await record(.runtimeNote(RuntimeNote.questionWentUnanswered), for: agentID)
            await session.answerElicitation(id: pending.request.id, outcome: .cancel)
            broadcast(DaemonAPI.Notification.agentElicitation,
                      DaemonAPI.ElicitationNotification(agentID: agentID, requestID: id, request: nil))
        }
    }
}

extension DaemonCore {
    /// For a test that cannot wait the real seconds.
    func setFinishGrace(_ grace: FinishGrace, quietWait: (@Sendable () async -> Void)? = nil) {
        finishGrace = grace
        finishQuietWait = quietWait
    }
}

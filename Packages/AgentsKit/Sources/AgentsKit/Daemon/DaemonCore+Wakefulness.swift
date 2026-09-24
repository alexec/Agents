import Foundation

extension DaemonCore {
    /// Whether any agent is mid-turn, which is the only agent-side reason to hold the
    /// Mac awake (FR-002).
    ///
    /// **This has two dangerous neighbours and is neither of them.** All three ask a
    /// question about roughly "is something happening", all three are one line long,
    /// and they disagree about `waitingOnUser` — which is exactly the state that makes
    /// the difference:
    ///
    /// - `isHoldingAgents` (`DaemonCore+Lifetime.swift`) asks **may the daemon exit**.
    ///   It counts an agent waiting on a person, a busy shell, a pending permission, a
    ///   draft and a resuming agent, because exiting under any of those would abandon
    ///   work. Right for its question; catastrophic for this one.
    /// - `AgentState.hasTurnInFlight` asks **is the conversation busy**, so a second
    ///   prompt queues rather than racing the first. It counts `waitingOnUser` because
    ///   a permission question is asked in the *middle* of a turn.
    /// - This one asks **is the CPU busy**.
    ///
    /// An agent blocked on a person is excluded deliberately (FR-003). Holding the Mac
    /// awake all night for an unanswered question is the one abuse this feature must
    /// not commit, and it is what reusing either neighbour would do.
    var hasWorkInFlight: Bool {
        agents.values.contains { $0.state == .starting || $0.state == .running }
    }

    /// How many, for the words. Same rule as `hasWorkInFlight` and derived from the
    /// same place, so the two can never disagree about what counts.
    var agentsInFlight: Int {
        agents.values.count { $0.state == .starting || $0.state == .running }
    }

    /// Take or let go of the Mac's idle sleep, according to what is happening now.
    ///
    /// Called from three places, and from nowhere else:
    ///
    /// 1. `changed(_:)` — every agent write worth telling a window about. This is what
    ///    meets FR-004's five seconds *by construction*: the release happens in the
    ///    same call that records the turn ending, not on a timer.
    /// 2. `tickWorkflows(now:)` — every 15 seconds, for the power source changing under
    ///    us, and as a backstop for any agent-side cause nobody thought of.
    /// 3. The end of `Daemon.start()` — so a daemon restarting under resumed agents
    ///    holds from its first moment rather than from their next state change.
    ///
    /// **Idempotence is load-bearing.** `changed(_:)` runs on every token of streamed
    /// output, so this is called constantly, and it must do nothing at all — and cost
    /// nothing — when nothing has moved. Two guards do that: the cheap in-memory
    /// answer is computed first and the IOKit read is skipped unless it could change
    /// anything, and `apply` then compares before acting.
    ///
    /// The verdict is re-derived every time rather than remembered, which is FR-014:
    /// what is remembered is only what was last *acted on*, so a change can be spotted.
    func reviseWakefulness(readingPower forcePowerRead: Bool = false) {
        let inFlight = hasWorkInFlight

        // Nothing computing. The verdict is `.idle` whatever the machine says about
        // its power, so do not pay IOKit to tell us — this is the common case and it
        // is reached on every token of every stream.
        guard inFlight else { return apply(.idle) }

        // Work in flight, and we already have a power-informed answer about work in
        // flight. Only the power moving could change the verdict now, and watching for
        // that is the 15-second tick's job (FR-011), which calls this with
        // `readingPower: true`.
        //
        // This guard is why the IOKit call is not in the hot path. A read measures
        // ~65µs, which sounds like nothing until you notice `changed(_:)` runs on
        // every streamed token *and* is isolated to this actor — so without this,
        // every agent's updates would queue behind a synchronous IOKit call made on
        // behalf of another agent's token.
        if !forcePowerRead, let last = lastWakeVerdict, last != .idle { return }

        let reading = power.read()
        lastPowerReading = reading
        apply(Wake.verdict(workInFlight: true, power: reading))
    }

    /// Act on a verdict, and only when it has moved.
    ///
    /// The comparison is the whole of the idempotence `reviseWakefulness` promises,
    /// and `ProcessInfoWakefulness` is idempotent underneath it as well — belt and
    /// braces, because a leaked assertion is invisible until somebody's battery is
    /// flat.
    private func apply(_ verdict: WakeVerdict) {
        guard verdict != lastWakeVerdict else { return }
        lastWakeVerdict = verdict

        if verdict.isHolding {
            // Set before the broadcast below reads it. Only moved when the hold is
            // *taken*, not on every revise, so "since" means since this hold began and
            // not since the last time anything was reconsidered.
            holdingSince = now()
            wakefulness.hold(reason: Self.wakeReason)
            // No count here either, for the reason `wakeReason` gives: this line is
            // written when the *verdict* moves, so a count in it is the count at the
            // moment the first agent started and says nothing about the two that
            // joined afterwards. The walk found it reading "1 agent" while three ran.
            DaemonLog.shared.write("holding the Mac awake: a turn is in flight")
        } else {
            holdingSince = nil
            wakefulness.release()
            DaemonLog.shared.write("letting the Mac sleep: \(Self.wakeWords(for: verdict))")
        }

        // Here and only here — the change branch. `reviseWakefulness` is reached on
        // every token of every stream, so a broadcast on the early-return path would
        // be a notification per token (T036, FR-015).
        broadcastWakeState()
    }

    /// Let the Mac go, whatever the agents' records still say.
    ///
    /// Called from `shutDown()` and nowhere else. **Deliberately not
    /// `reviseWakefulness()`**, and the difference is the whole point of it existing:
    /// `shutDown` leaves an agent that was mid-turn reading `running` on disk on
    /// purpose, so the next daemon finds it and records it as `foundDead` rather than
    /// pretending it finished. Revising here would see work in flight, decide to keep
    /// holding, and hold right up until the process died.
    ///
    /// The kernel would take the assertion away a moment later anyway — that is
    /// verified, and it is why no cleanup path exists for the *unclean* case (FR-013).
    /// This is the belt to that braces: on the path where we are going knowingly, we
    /// say so ourselves, so `pmset` tells the truth for the seconds a shutdown takes
    /// rather than naming a process that is on its way out (US2-5).
    func letGoOfTheMac() {
        guard lastWakeVerdict?.isHolding == true else { return }
        wakefulness.release()
        lastWakeVerdict = nil
        holdingSince = nil
        DaemonLog.shared.write("letting the Mac sleep: the daemon is going")
        // Any window still connected is about to lose the socket anyway, but a window
        // that outlives this daemon and reconnects to another must not be left showing
        // a hold that nobody holds.
        broadcastWakeState()
    }

    /// What the windows are told, and what `wake/state` answers.
    ///
    /// Derived fresh every time rather than stored. The count is exact here precisely
    /// because this can be re-sent as often as it likes — unlike the assertion's reason
    /// string, which is written once and would go stale (see `wakeReason`).
    func currentWakeState() -> DaemonAPI.WakeState {
        let verdict = lastWakeVerdict ?? .idle
        var heldBack = false
        // The charge from the last reading we actually took, not a fresh one: this is
        // called for every window that connects, and asking IOKit here would put a
        // synchronous read on that path for a number that moves by the minute.
        var percent = lastPowerReading?.batteryPercent
        if case .batteryTooLow(let charge) = verdict {
            heldBack = true
            // The verdict's own figure wins when there is one, because it is the charge
            // the decision was made on.
            percent = charge
        }
        return DaemonAPI.WakeState(isHolding: verdict.isHolding,
                                   agentsInFlight: agentsInFlight,
                                   heldBackByBattery: heldBack,
                                   batteryPercent: percent,
                                   since: verdict.isHolding ? holdingSince : nil)
    }

    func broadcastWakeState() {
        broadcast(DaemonAPI.Notification.wakeChanged, currentWakeState())
    }

    /// The window asking on connect, because it heard no broadcast for a hold that was
    /// already in place when it opened.
    public func wakeState() -> DaemonAPI.WakeState { currentWakeState() }

    /// What `pmset -g assertions` will show, verbatim.
    ///
    /// Not a log line: this string is carried into the system's own assertion list, so
    /// it is written for a person at a terminal at midnight wondering why their Mac is
    /// awake. It names us, and it says what for.
    ///
    /// **It deliberately carries no count**, and that is a correction the Phase 3 walk
    /// forced. The first version said "Agents: 2 agents are mid-turn", and with three
    /// real agents running it read "1 agent" — because `reviseWakefulness` acts only
    /// when the *verdict* moves, and the verdict is `.hold` whether one agent is
    /// working or five. The count was written once, by whichever agent started first,
    /// and then went stale.
    ///
    /// The count could be kept true by ending the assertion and beginning another
    /// whenever it changed, but that is a swap in the one place a gap must never open,
    /// bought for a number in a diagnostic tool. A standing count belongs in
    /// `WakeState.agentsInFlight`, which is broadcast and can be re-sent freely.
    ///
    /// So this says only what it can always say truthfully: who is holding, and why.
    /// Distinguishable on purpose from the assertion 005 §10 will one day hold in the
    /// bridge, which is a different process holding for a different reason — its poll
    /// loop, not an agent's turn.
    static let wakeReason = "Agents: a turn is in flight"

    /// Why we are not holding, for the daemon's log. FR-017's other half.
    static func wakeWords(for verdict: WakeVerdict) -> String {
        switch verdict {
        case .hold: return "a turn is in flight"
        case .idle: return "nothing is mid-turn"
        case .batteryTooLow(let percent): return "battery at \(percent)%, at or below the floor"
        }
    }
}

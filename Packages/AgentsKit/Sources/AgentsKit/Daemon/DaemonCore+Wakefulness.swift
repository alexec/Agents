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
        loadWakeSettingsIfNeeded()
        let settings = wakeSettings
        let inFlight = hasWorkInFlight

        // Off means never held, even with an agent mid-turn. The time they chose stays
        // in the file for when they turn it back on.
        if !settings.keepsAwake {
            graceStartedAt = nil
            return apply(.idle, graceUntil: nil)
        }

        if inFlight {
            // Work again cancels a grace. The clock comes back only from the next stop.
            let droppingGrace = graceStartedAt != nil
            graceStartedAt = nil
            // Already holding for work. Only the power moving could change the verdict
            // now, and watching for that is the 15-second tick's job (FR-011), which
            // calls this with `readingPower: true`.
            //
            // This guard is why the IOKit call is not in the hot path. A read measures
            // ~65µs, which sounds like nothing until you notice `changed(_:)` runs on
            // every streamed token *and* is isolated to this actor — so without this,
            // every agent's updates would queue behind a synchronous IOKit call made on
            // behalf of another agent's token. Dropping a grace is the exception: the
            // verdict stays `.hold` and the windows still have to lose the clock.
            if !droppingGrace, !forcePowerRead, let last = lastWakeVerdict, last != .idle { return }

            let reading = power.read()
            lastPowerReading = reading
            return apply(Wake.verdict(workInFlight: true, power: reading), graceUntil: nil)
        }

        // Nothing computing. Right away, or no grace running and we were not holding
        // for work: the ordinary case, reached on every token of every stream, and it
        // must not pay IOKit.
        guard settings.graceHours > 0 else {
            graceStartedAt = nil
            return apply(.idle, graceUntil: nil)
        }
        if graceStartedAt == nil {
            // A grace begins only from a hold this process was keeping for work.
            // Turning the switch on while nothing is working does not start one, and
            // neither does a daemon that has just launched.
            guard lastWakeVerdict?.isHolding == true, lastGraceUntil == nil else {
                return apply(.idle, graceUntil: nil)
            }
            graceStartedAt = now()
        }

        let until = graceStartedAt!.addingTimeInterval(settings.graceInterval)
        if now() >= until {
            graceStartedAt = nil
            return apply(.idle, graceUntil: nil)
        }
        // Inside the grace, and we already told the windows this exact time. The tick
        // is what notices the battery, and the clock, moving.
        if !forcePowerRead, lastWakeVerdict == .hold, lastGraceUntil == until { return }

        let reading = power.read()
        lastPowerReading = reading
        let verdict = Wake.verdict(workInFlight: true, power: reading)
        if verdict.isHolding {
            apply(.hold, graceUntil: until)
        } else {
            // At or below the floor, with nothing in flight: the row stays quiet. The
            // clock is kept, so plugging back in before it passes takes the hold up again.
            apply(.idle, graceUntil: nil)
        }
    }

    /// Act on a verdict, and only when it or the grace clock has moved.
    ///
    /// The comparison is the whole of the idempotence `reviseWakefulness` promises,
    /// and `ProcessInfoWakefulness` is idempotent underneath it as well — belt and
    /// braces, because a leaked assertion is invisible until somebody's battery is
    /// flat. The clock is part of the comparison because a grace keeps the verdict
    /// at `.hold` and the windows still have to be told when it ends.
    private func apply(_ verdict: WakeVerdict, graceUntil: Date?) {
        let until = verdict.isHolding ? graceUntil : nil
        guard verdict != lastWakeVerdict || until != lastGraceUntil else { return }
        let wasHolding = lastWakeVerdict?.isHolding == true
        lastWakeVerdict = verdict
        lastGraceUntil = until

        if verdict.isHolding {
            // Set before the broadcast below reads it. Only moved when the hold is
            // *taken*, not when a grace keeps a hold that was already up, so "since"
            // means since this hold began.
            if !wasHolding { holdingSince = now() }
            let forGrace = until != nil
            wakefulness.hold(reason: forGrace ? Self.graceReason : Self.wakeReason)
            DaemonLog.shared.write(forGrace
                ? "holding the Mac awake: staying awake so you can reply"
                : "holding the Mac awake: a turn is in flight")
        } else {
            holdingSince = nil
            // A verdict that was never a hold — idle, or the battery already having
            // let go — has nothing to release. Releasing anyway would count a hold
            // the Mac never had.
            if wasHolding {
                wakefulness.release()
                DaemonLog.shared.write("letting the Mac sleep: \(Self.wakeWords(for: verdict))")
            }
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
        graceStartedAt = nil
        guard lastWakeVerdict?.isHolding == true else { return }
        wakefulness.release()
        lastWakeVerdict = nil
        lastGraceUntil = nil
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
                                   since: verdict.isHolding ? holdingSince : nil,
                                   graceUntil: verdict.isHolding ? lastGraceUntil : nil)
    }

    /// The switch and the hours, loaded once.
    public func readWakeSettings() -> WakeSettings {
        loadWakeSettingsIfNeeded()
        return wakeSettings
    }

    /// The person changed the switch or the hours. Applied at once: off, or a grace
    /// that the new length has already passed, lets the Mac sleep now.
    @discardableResult
    public func setWakeSettings(_ settings: WakeSettings) -> WakeSettings {
        loadWakeSettingsIfNeeded()
        wakeSettings = WakeSettings(keepsAwake: settings.keepsAwake, graceHours: settings.graceHours)
        do { try wakeStore.save(wakeSettings) } catch {
            DaemonLog.shared.write("wake.json: could not write: \(error.localizedDescription)")
        }
        reviseWakefulness(readingPower: true)
        return wakeSettings
    }

    func loadWakeSettingsIfNeeded() {
        guard !wakeSettingsLoaded else { return }
        wakeSettingsLoaded = true
        wakeSettings = wakeStore.load()
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

    /// What `pmset` shows once the work has stopped and the grace is what holds the Mac.
    static let graceReason = "Agents: staying awake so you can reply"

    /// Why we are not holding, for the daemon's log. FR-017's other half.
    static func wakeWords(for verdict: WakeVerdict) -> String {
        switch verdict {
        case .hold: return "a turn is in flight"
        case .idle: return "nothing is mid-turn"
        case .batteryTooLow(let percent): return "battery at \(percent)%, at or below the floor"
        }
    }
}

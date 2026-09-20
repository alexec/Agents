import Foundation

/// Where a need goes. The one place that decides (FR-012): no surface may work out for
/// itself whether it is the right one to alert.
///
/// Three things live here and none is written to disk. `presences` is one record per
/// connection, keyed by the connection rather than by surface, so two windows are two
/// records and one going does not erase the other's knowledge. `deliveries` is one per
/// outstanding need, and dies with it. `needRaisedAt` is the one fact about a need that
/// must not move: when the daemon first saw it.
extension DaemonCore {
    // MARK: What wants a person

    /// The outstanding needs, derived and never stored — exactly as `AgentGroup` is.
    ///
    /// **There is no detection here.** A need is a pending permission, a pending form,
    /// or a finished agent whose report says it cannot get further alone; the first two
    /// are the dictionaries the daemon already keeps, and the third is the one rule,
    /// `Agent.needsAPerson`. A second definition anywhere would be the bug FR-001 forbids.
    func needs() -> [Need] {
        let now = now()
        var found: [Need] = []
        for (id, pending) in pendingPermissions {
            guard let agent = agents[pending.agentID] else { continue }
            found.append(need(.permission(id), for: agent, kind: .permission,
                              wanted: "Wants to \(pending.request.toolCall.line)", now: now))
        }
        for (id, pending) in elicitations {
            guard let agent = agents[pending.agentID] else { continue }
            found.append(need(.elicitation(id), for: agent, kind: .elicitation,
                              wanted: "Asks: \(pending.request.title)", now: now))
        }
        for agent in agents.values where agent.state == .finished {
            guard let report = agent.report, report.outcome.needsAPerson else { continue }
            found.append(need(.report(agent.id, report.at), for: agent, kind: .report,
                              wanted: "\(report.outcome.heading): \(report.message)", now: now))
        }
        // Forget the first-seen time of anything that is no longer outstanding, so a
        // question asked again later is a new need with a new `raisedAt`.
        let live = Set(found.map(\.id))
        needRaisedAt = needRaisedAt.filter { live.contains($0.key) }
        return found
    }

    private func need(_ id: NeedID, for agent: Agent, kind: Need.Kind, wanted: String, now: Date) -> Need {
        let raisedAt = needRaisedAt[id] ?? now
        needRaisedAt[id] = raisedAt
        return Need(id: id, agentID: agent.id, folder: Project.standardize(agent.cwd), kind: kind,
                    raisedAt: raisedAt,
                    headline: Headline(h1: agent.cwd.lastPathComponent,
                                       h2: agent.title ?? "",
                                       h3: wanted).truncating())
    }

    // MARK: Where the person is

    /// The paired devices the ladder may route to. None until Slice C builds the store;
    /// the ladder's device rungs are exhausted in `RoutingTests` against records made
    /// by hand, which is why Slice A can ship without one.
    var pairedDevices: [Device] { [] }

    /// `presence/report`. The surface is the connection's, never the parameters', and the
    /// time is this clock's, never the sender's — a device with a fast clock must not
    /// win every race. A surface that reports again replaces its own record.
    func reportPresence(_ report: DaemonAPI.PresenceReport, from surface: Surface?, connection: UUID?) throws {
        guard let surface, let connection else {
            throw JSONRPCError(code: DaemonAPI.Failure.notASurface,
                               message: "This connection is not a window or a device, so it cannot say where anybody is.")
        }
        presences[connection] = Presence(surface: surface, watching: report.watching,
                                         active: report.active, heardAt: now())
        if let mayNotify = report.mayNotify, let device = surface.deviceID {
            deviceMayNotify[device] = mayNotify
        }
        reconsider()
    }

    /// A connection has gone. Its record is deleted, not aged out: gone is more truthful
    /// than stale, and it is the difference between the Mac rung failing fast and the
    /// person waiting `macIdle` for a banner nobody can show.
    func forgetPresence(connection: UUID) {
        guard presences.removeValue(forKey: connection) != nil else { return }
        reconsider()
    }

    /// The records folded to one per surface, which is what the ladder reads. Where a
    /// surface has several connections — two windows — the one heard from most recently
    /// speaks for it, and an active one outranks an idle one.
    private func presencesBySurface() -> [Surface: Presence] {
        var folded: [Surface: Presence] = [:]
        for presence in presences.values {
            if let held = folded[presence.surface] {
                // Active beats idle; among equals, the more recently heard.
                let better = presence.active != held.active
                    ? presence.active
                    : presence.heardAt > held.heardAt
                if !better { continue }
            }
            folded[presence.surface] = presence
        }
        return folded
    }

    // MARK: Deciding

    /// `attention/pending`: what is outstanding, and where each is showing, for a surface
    /// that was not listening when it was decided (FR-010).
    func attentionPending() -> DaemonAPI.AttentionPending {
        let outstanding = needs()
        return DaemonAPI.AttentionPending(
            needs: outstanding,
            deliveries: outstanding.compactMap { need in
                deliveries[need.id].map { DaemonAPI.AttentionDelivery(needID: need.id, to: $0.to) }
            })
    }

    /// Run the ladder for every outstanding need and say what changed — and only what
    /// changed, so calling this on every state change costs nothing anybody hears.
    ///
    /// Called from every place a need can begin or end: a question held or answered, a
    /// form held, answered or withdrawn, a report recorded, a process gone, and every
    /// state change through `move`. Also when where the person is changes, and when a
    /// settling pause elapses.
    func reconsider() {
        let now = now()
        let outstanding = needs()
        let live = Set(outstanding.map(\.id))
        let presences = presencesBySurface()

        // Met: answered anywhere, or the agent stopped or archived. Every surface hears
        // it, so the losers withdraw too (FR-016); a withdrawal names only the id.
        for id in deliveries.keys where !live.contains(id) {
            deliveries.removeValue(forKey: id)
            cancelSettling(id)
            broadcast(DaemonAPI.Notification.attentionChanged,
                      DaemonAPI.AttentionNotification(needID: id, need: nil, to: nil, alert: false))
        }
        for id in settlingTimers.keys where !live.contains(id) { cancelSettling(id) }

        for need in outstanding {
            let decision = Routing.decide(need: need, presences: presences, devices: pairedDevices,
                                          delivery: deliveries[need.id], thresholds: thresholds, now: now)
            if decision.wait {
                // At the Mac, and given a moment to look before anything is shown. One
                // timer per need, and rung 0 runs again when it fires (FR-014, FR-015).
                scheduleSettling(need)
                continue
            }
            cancelSettling(need.id)

            if let existing = deliveries[need.id] {
                guard existing.to != decision.to else { continue }
                // A move. `alertedAt` moves only if the person may be buzzed afresh —
                // the whole of FR-018 — and the notification moves either way.
                var moved = existing
                moved.to = decision.to
                if decision.alert {
                    moved.alertedAt = now
                    moved.alertCount += 1
                }
                deliveries[need.id] = moved
                broadcast(DaemonAPI.Notification.attentionChanged,
                          DaemonAPI.AttentionNotification(needID: need.id, need: need,
                                                          to: decision.to, alert: decision.alert))
            } else {
                // Never shown anywhere yet. Nowhere to show it — watched, or nobody
                // reachable — is not news to anybody; the need waits in the record and
                // `attention/pending` tells the next surface (FR-010).
                guard let to = decision.to else { continue }
                deliveries[need.id] = Delivery(needID: need.id, to: to, alertedAt: now, alertCount: 1)
                broadcast(DaemonAPI.Notification.attentionChanged,
                          DaemonAPI.AttentionNotification(needID: need.id, need: need, to: to, alert: true))
            }
        }
    }

    private func scheduleSettling(_ need: Need) {
        guard settlingTimers[need.id] == nil else { return }
        let due = need.raisedAt.addingTimeInterval(thresholds.settlingPause)
        let delay = max(0, due.timeIntervalSince(now()))
        settlingTimers[need.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.settlingElapsed(need.id)
        }
    }

    private func settlingElapsed(_ id: NeedID) {
        settlingTimers.removeValue(forKey: id)
        reconsider()
    }

    private func cancelSettling(_ id: NeedID) {
        settlingTimers.removeValue(forKey: id)?.cancel()
    }
}

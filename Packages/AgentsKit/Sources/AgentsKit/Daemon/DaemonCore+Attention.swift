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

    /// `surface/identify`, after the server has taken the identity: note that the device
    /// is here. The connection's surface must already be this device — the server sets
    /// it first — or the call is not a device's. An unknown device is **not** made known
    /// here: a device becomes one by announcing and being approved (`DaemonCore+Devices`),
    /// and the ladder never sees one that has not.
    func identify(_ who: DaemonAPI.SurfaceIdentification, from surface: Surface?, connection: UUID?) throws {
        guard connection != nil, surface == .device(who.id) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notASurface,
                               message: "Only a device's own connection may say which device it is.")
        }
        guard var known = device(who.id) else { return }
        known.name = who.name
        known.kind = who.kind
        known.lastSeenAt = now()
        try? saveDevice(known)
        reconsider()
    }

    /// `presence/report`. The surface is the connection's, never the parameters', and the
    /// time is this clock's, never the sender's — a device with a fast clock must not
    /// win every race. A surface that reports again replaces its own record.
    func reportPresence(_ report: DaemonAPI.PresenceReport, from surface: Surface?, connection: UUID?) throws {
        guard let surface, let connection else {
            throw JSONRPCError(code: DaemonAPI.Failure.notASurface,
                               message: "This connection is not a window or a device, so it cannot say where anybody is.")
        }
        let now = now()
        presences[connection] = Presence(surface: surface, watching: report.watching,
                                         active: report.active, heardAt: now)
        if report.active, let watching = report.watching { markRead(watching) }
        if let id = surface.deviceID, var known = device(id) {
            // Heard from is what the default rung reads when nobody is in hand, and what
            // the device says about its own permission is what makes it eligible at all.
            if let mayNotify = report.mayNotify { known.mayNotify = mayNotify }
            known.lastSeenAt = now
            try? saveDevice(known)
        }
        reconsider()
    }

    /// A conversation is in front of somebody: it has been read. Written only when it
    /// moves the fact, so a window that keeps saying the same thing does not rewrite
    /// the record.
    func markRead(_ agentID: UUID) {
        guard var agent = agents[agentID], agent.isUnread else { return }
        agent.isUnread = false
        changed(agent)
    }

    /// Whether some surface has this conversation in front of an active person right
    /// now — what makes a chat that finishes while it is being watched already read.
    func isWatched(_ agentID: UUID) -> Bool {
        presences.values.contains { $0.active && $0.watching == agentID }
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
            if let device = deliveries[id]?.to?.deviceID { withdraw(id, from: device, at: now) }
            deliveries.removeValue(forKey: id)
            cancelSettling(id)
            broadcast(DaemonAPI.Notification.attentionChanged,
                      DaemonAPI.AttentionNotification(needID: id, need: nil, to: nil, alert: false))
        }
        for id in settlingTimers.keys where !live.contains(id) { cancelSettling(id) }

        for need in outstanding {
            let decision = Routing.decide(need: need, presences: presences, devices: approvedDevices,
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
                if let device = existing.to?.deviceID { withdraw(need.id, from: device, at: now) }
                if let device = decision.to?.deviceID { post(need, to: device, alert: decision.alert, at: now) }
                broadcast(DaemonAPI.Notification.attentionChanged,
                          DaemonAPI.AttentionNotification(needID: need.id, need: need,
                                                          to: decision.to, alert: decision.alert))
            } else {
                // Never shown anywhere yet. Nowhere to show it — watched, or nobody
                // reachable — is not news to anybody; the need waits in the record and
                // `attention/pending` tells the next surface (FR-010).
                guard let to = decision.to else { continue }
                deliveries[need.id] = Delivery(needID: need.id, to: to, alertedAt: now, alertCount: 1)
                if let device = to.deviceID { post(need, to: device, alert: true, at: now) }
                broadcast(DaemonAPI.Notification.attentionChanged,
                          DaemonAPI.AttentionNotification(needID: need.id, need: need, to: to, alert: true))
            }
        }
    }

    // MARK: Reaching a device that is not here

    /// A need for a device goes to its mailbox as well as over any socket it holds,
    /// sealed to that device and nobody else (FR-022): a backgrounded or absent device
    /// is reached by push, not by a socket nobody is holding (research §1). Sealing
    /// needs the device's key; a record without a usable one is sent nothing, which is
    /// the truth about it rather than a banner in the clear.
    private func post(_ need: Need, to id: UUID, alert: Bool, at now: Date) {
        guard let device = device(id), device.isApproved,
              let envelope = try? Envelope.seal(need.headline, to: device.publicKey) else { return }
        enqueue(MailboxItem(needID: need.id, device: id, envelope: envelope, alert: alert, postedAt: now))
    }

    /// The need is over here: a withdrawal, naming only the id, replaces whatever was
    /// waiting for the device under it.
    private func withdraw(_ id: NeedID, from device: UUID, at now: Date) {
        enqueue(MailboxItem(needID: id, device: device, envelope: nil, alert: false, postedAt: now))
    }

    private func enqueue(_ item: MailboxItem) {
        guard let mailbox else {
            broadcast(DaemonAPI.Notification.mailboxPost, item)
            return
        }
        let previous = mailboxTail
        mailboxTail = Task {
            await previous?.value
            try? await mailbox.post(item)
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

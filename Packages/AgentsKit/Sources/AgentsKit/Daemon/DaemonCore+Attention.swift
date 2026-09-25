import Foundation

/// Where a need goes. The one place that decides (FR-012): no surface may work out for
/// itself whether it is the right one to alert.
///
/// Three things live here, and since 025 two of them are written down.
///
/// `presences` is one record per connection, keyed by the connection rather than by
/// surface, so two windows are two records and one going does not erase the other's
/// knowledge. It stays in memory: where somebody is right now is not a fact worth
/// keeping, and a remembered one could only mislead the next daemon.
///
/// `deliveries` is one per outstanding need, and dies with it. `needRaisedAt` is the one
/// fact about a need that must not move: when the daemon first saw it. Both of those
/// **do** survive now, in `attention.json`, because they are about a need rather than
/// about a live process — and a need built from the agent record outlives the daemon
/// perfectly well. What used to die with it was only the memory of having already told
/// somebody, which is how a restart came to buzz a person twice about one thing.
extension DaemonCore {
    // MARK: What survives the daemon

    /// Read the notes back, keeping only what can be acted on.
    ///
    /// Called from `recover()` rather than from `Daemon.start()`, so that anything
    /// driving a `DaemonCore` directly — which is every test, and any future embedder —
    /// gets it too. `recover()` is already "read the record and tell the truth about it",
    /// and these are part of that record.
    ///
    /// Deliberately **not** followed by a `reconsider()` here. Nothing is connected this
    /// early: a decision taken now would find nobody reachable, move every restored
    /// delivery to nowhere, and then move it back the moment a window appeared — two
    /// notifications and a file rewritten, to arrive exactly where it started. The first
    /// presence report does it, which is moments later and is when there is somebody to
    /// tell.
    func loadAttention() {
        let known = Set(devices.keys)
        let onDisk = attentionStore.load()
        let usable = onDisk.pruned(knownDevices: known, now: now())
        deliveries = Dictionary(usable.deliveries.map { ($0.needID, $0) },
                                uniquingKeysWith: { first, _ in first })
        needRaisedAt = Dictionary(usable.raised.map { ($0.need, $0.at) },
                                  uniquingKeysWith: { first, _ in first })
        pendingWithdrawals = usable.withdrawing
        lastWrittenAttention = usable
        // What was dropped is dropped now rather than at the next thing that happens to
        // move, so the file does not keep offering a device that has gone.
        if usable != onDisk { attentionStore.save(usable) }
    }

    /// Write the notes, and only when they have actually changed.
    ///
    /// The guard is the whole point. `reconsider()` is called on every state change, on
    /// every question held or answered, and on **every presence report** — which arrives
    /// periodically from every window and every device. An unconditional write here would
    /// put a file rewrite in a path that runs several times a second with nobody doing
    /// anything.
    ///
    /// Everything is sorted by the need's token before comparing, because the two sources
    /// are dictionaries and a dictionary's order is nobody's: unsorted, the comparison
    /// would differ on almost every pass and the guard would never once hold.
    func writeAttentionIfMoved() {
        let records = AttentionRecords(
            raised: needRaisedAt
                .map { RaisedNote(need: $0.key, at: $0.value) }
                .sorted { $0.need.token < $1.need.token },
            deliveries: deliveries.values.sorted { $0.needID.token < $1.needID.token },
            withdrawing: pendingWithdrawals.sorted { $0.need.token < $1.need.token })
        // Nothing is written by a core that has not read the file. Without this, a
        // decision taken before `loadAttention()` — by anything driving a `DaemonCore`
        // without recovering it first — writes its empty memory over what the last
        // daemon left, and every note in it is lost to a daemon that never looked.
        guard let last = lastWrittenAttention, records != last else { return }
        attentionStore.save(records)
        lastWrittenAttention = records
    }

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
        // An archived project is one the person has said they are done with: nothing
        // in it wants anybody, however its agents ended (2026-09-21, found on the walk).
        let archived = Set(projectRecords().values.filter(\.isArchived).map(\.folder))
        func inALiveProject(_ agent: Agent) -> Bool { !archived.contains(Project.standardize(agent.cwd)) }
        for (id, pending) in pendingPermissions {
            guard let agent = agents[pending.agentID], inALiveProject(agent) else { continue }
            found.append(need(.permission(id), for: agent, kind: .permission,
                              wanted: "Wants to \(pending.request.toolCall.line)", now: now))
        }
        for (id, pending) in elicitations {
            guard let agent = agents[pending.agentID], inALiveProject(agent) else { continue }
            found.append(need(.elicitation(id), for: agent, kind: .elicitation,
                              wanted: "Asks: \(pending.request.title)", now: now))
        }
        for agent in agents.values where agent.state == .finished && inALiveProject(agent) {
            guard let report = agent.report, report.outcome.needsAPerson else { continue }
            // Looked at already. The agent still wants an answer, and still says so under
            // Needs attention, but telling the person again is only noise: the same
            // report once bought fifteen banners (2026-09-24).
            guard !agent.reportIsSeen else { continue }
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
    /// here: a device becomes one by announcing its key (`DaemonCore+Devices`), and the
    /// ladder never sees one that has not.
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

    /// A conversation is in front of somebody: it has been read, and so has whatever it
    /// last reported. Written only when it moves a fact, so a window that keeps saying
    /// the same thing does not rewrite the record.
    func markRead(_ agentID: UUID) {
        guard var agent = agents[agentID] else { return }
        let seesReport = agent.report != nil && !agent.reportIsSeen
        guard agent.isUnread || seesReport else { return }
        agent.isUnread = false
        if seesReport { agent.reportSeenAt = agent.report?.at }
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
                DaemonLog.shared.write("attention: \(need.id.token) \(existing.to.map(String.init(describing:)) ?? "nowhere") → \(decision.to.map(String.init(describing:)) ?? "nowhere"), alert \(decision.alert); \(presences.count) presences: \(presences.values.map { "\($0.surface) active=\($0.active) watching=\($0.watching?.uuidString.prefix(8) ?? "-")" }.joined(separator: ", "))")
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
                DaemonLog.shared.write("attention: \(need.id.token) first to \(to)")
                if let device = to.deviceID { post(need, to: device, alert: true, at: now) }
                broadcast(DaemonAPI.Notification.attentionChanged,
                          DaemonAPI.AttentionNotification(needID: need.id, need: need, to: to, alert: true))
            }
        }

        // Last, once every decision above has landed. What is owed goes out if anything
        // will carry it; then, only if any of this moved anything, it is written down —
        // whatever the next daemon is told, it is told here.
        drainWithdrawals()
        writeAttentionIfMoved()
    }

    // MARK: Reaching a device that is not here

    /// A need for a device goes to its mailbox as well as over any socket it holds,
    /// sealed to that device and nobody else (FR-022): a backgrounded or absent device
    /// is reached by push, not by a socket nobody is holding (research §1). Sealing
    /// needs the device's key; a record without a usable one is sent nothing, which is
    /// the truth about it rather than a banner in the clear.
    private func post(_ need: Need, to id: UUID, alert: Bool, at now: Date) {
        // A newer decision about this need on this device voids any withdrawal still
        // waiting for a carrier. Otherwise a banner taken off the phone and put back while
        // the bridge was away would be taken off again the moment the bridge arrived —
        // for a question that is still asking.
        pendingWithdrawals.removeAll { $0.need == need.id && $0.device == id }
        guard let device = device(id),
              let envelope = try? Envelope.seal(need.headline, to: device.publicKey) else { return }
        enqueue(MailboxItem(needID: need.id, device: id, envelope: envelope, alert: alert, postedAt: now))
    }

    /// The need is over here: a withdrawal, naming only the id, replaces whatever was
    /// waiting for the device under it.
    ///
    /// **Owed, not sent.** It goes on `pendingWithdrawals` and leaves from
    /// `drainWithdrawals()` once something that carries mail is listening. This is the
    /// one post with no second chance: every other post is repeated by the next
    /// decision about its need, but this one is about the need being *over*, so there is
    /// no next decision. Broadcast into a room with no bridge in it, it is gone, and the
    /// phone keeps a question nobody can answer (025 US2).
    private func withdraw(_ id: NeedID, from device: UUID, at now: Date) {
        guard !pendingWithdrawals.contains(where: { $0.need == id && $0.device == device }) else { return }
        pendingWithdrawals.append(PendingWithdrawal(need: id, device: device, decidedAt: now))
    }

    /// Whether anything is listening that will take a post to the devices.
    ///
    /// A mailbox of the daemon's own — a test's, or an embedder's — always is. The
    /// daemon's own case has none, and depends on a connection having said
    /// `mailbox/carry`: the bridge, which is indistinguishable from a window until it
    /// does.
    var hasCarrier: Bool { mailbox != nil || !carriers.isEmpty }

    /// Hand every owed withdrawal to whatever carries mail, if anything does.
    ///
    /// What is handed over is forgotten: it has gone the same way as every other post,
    /// with the same guarantee. What cannot be — nobody carrying, the device no longer
    /// on record, a week gone by — is dealt with by the same rules `pruned` applies to
    /// the file, so what is in memory and what is on disk cannot disagree about it.
    func drainWithdrawals() {
        guard !pendingWithdrawals.isEmpty else { return }
        let now = now()
        let usable = AttentionRecords(withdrawing: pendingWithdrawals)
            .pruned(knownDevices: Set(devices.keys), now: now).withdrawing
        guard hasCarrier else {
            pendingWithdrawals = usable
            return
        }
        for owed in usable {
            enqueue(MailboxItem(needID: owed.need, device: owed.device, envelope: nil,
                                alert: false, postedAt: now))
        }
        pendingWithdrawals = []
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

// MARK: - Who carries mail

extension DaemonCore {
    /// `mailbox/carry`: this connection hears `mailbox/post` and takes it to the devices.
    func becomeCarrier(connection: UUID?) throws {
        guard let connection else {
            throw JSONRPCError(code: DaemonAPI.Failure.notASurface,
                               message: "Only a connection can carry mail.")
        }
        carriers.insert(connection)
        // Now there is somebody to hand things to. Reconsidering rather than only
        // draining, because after a restart with no window this may be the first thing
        // that has happened at all: the withdrawals for questions that died with the
        // last daemon have not even been decided yet.
        reconsider()
    }

    /// The connection has gone. Called beside `forgetPresence`, from the same place.
    func forgetCarrier(connection: UUID) {
        carriers.remove(connection)
    }
}

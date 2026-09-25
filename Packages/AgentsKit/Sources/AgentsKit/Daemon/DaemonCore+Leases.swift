import Foundation
import AgentsKitCore

/// Agents taking turns with the Mac's shared things (036).
///
/// The rules are the book's (`LeaseBook`); what is here is applying them. Every change
/// to the book happens before the first `await` of the call that makes it, which on
/// this actor is the whole of the lock: two agents asking at once are decided one
/// after the other, and the second sees the first's lease (FR-002).
///
/// What comes back from the book is then said: in the holder's transcript, in the
/// answer to a call that was waiting, or by starting an agent whose call had already
/// returned. Only agents hold leases. The person can end one and take an agent out of
/// a line, and nothing here lets them take one.
extension DaemonCore {
    // MARK: Agents' calls

    /// `lease_resource`: take it, extend it, or wait in line for it.
    ///
    /// A wait keeps the call open for up to `leaseWaitLimit`, then answers "still in
    /// line" with the place kept. When the lease comes after that, the agent is started
    /// again instead (research R3, R4).
    public func lease(_ request: DaemonAPI.LeaseRequest) async throws -> String {
        let caller = try leaseCaller(request.token)
        guard ResourceName(request.name) != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused, message: LeaseWords.emptyName)
        }
        // The one wait before the book is touched. From here to the answer, or to the
        // call being parked, nothing awaits.
        guard let resource = await resolveResource(request.name) else {
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused, message: LeaseWords.emptyName)
        }
        let loaded = loadLeasesIfNeeded()
        let told = noticesText(for: caller.id)
        let wait = request.wait ?? true
        let waitID = wait ? UUID() : nil
        // A call already waiting for this, from the same agent, is superseded by this
        // one: answered now with its place, rather than left to time out.
        let superseded = wait
            ? leaseBook.entry(resource.name)?.line.first { $0.agentID == caller.id }?.waitID
            : nil
        let events = leaseBook.request(resource.name, kind: resource.kind, displayName: resource.displayName,
                                       by: caller.id, minutes: request.minutes, wait: wait,
                                       waitID: waitID, now: now())
        let display = leaseBook.entry(resource.name)?.displayName ?? resource.displayName

        switch events.first {
        case .granted(let lease, _, let capped):
            leasesChanged()
            await settle(loaded + events)
            return told + LeaseWords.granted(lease, capped: capped)
        case .extended(let lease, let capped):
            leasesChanged()
            await settle(loaded + events)
            return told + LeaseWords.extended(lease, capped: capped)
        case .refused(let holder, let until):
            await settle(loaded)
            return told + LeaseWords.refused(display, holder: holderName(holder), until: until)
        case .stillWaiting(let place, let holder, let until) where !wait:
            await settle(loaded)
            return told + LeaseWords.stillInLine(display, holder: holderName(holder), until: until, place: place)
        case .queued, .stillWaiting:
            guard let waitID else { return told }
            leasesChanged()
            if let superseded, case .stillWaiting(let place, let holder, let until)? = events.first {
                answer(superseded, .success(LeaseWords.stillInLine(display, holder: holderName(holder),
                                                                   until: until, place: place)))
            }
            // Parked before anything is awaited, so a release arriving in the next
            // instant finds the call to answer rather than starting the agent again.
            let answer = await withCheckedContinuation { continuation in
                openWaits[waitID] = continuation
                openWaitStarted[waitID] = now()
                scheduleWaitLimit(waitID)
                Task { await self.settle(loaded) }
            }
            switch answer {
            case .success(let text): return told + text
            case .failure(let error): throw error
            }
        default:
            await settle(loaded)
            return told
        }
    }

    /// `release_resource`: give it back, or leave the line.
    public func releaseLease(_ request: DaemonAPI.LeaseNameRequest) async throws -> String {
        let caller = try leaseCaller(request.token)
        guard let resource = await resolveResource(request.name) else {
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused,
                               message: "Nothing was released: say which resource.")
        }
        let loaded = loadLeasesIfNeeded()
        let told = noticesText(for: caller.id)
        // The caller's own open call for this, if it is releasing its place while one
        // is still waiting (a second runtime thread, say): answered, not left hanging.
        let ownWait = leaseBook.entry(resource.name)?.line.first { $0.agentID == caller.id }?.waitID
        let events = leaseBook.release(resource.name, by: caller.id, now: now())
        let display = leaseBook.entry(resource.name)?.displayName ?? resource.displayName
        if events != [.nothingHeld] { leasesChanged() }
        if let ownWait { answer(ownWait, .success(LeaseWords.leftLine(display))) }
        await settle(loaded + events)

        switch events.first {
        case .released(let lease, _):
            let next = events.dropFirst().compactMap { event -> UUID? in
                if case .granted(let given, _, _) = event { return given.holder } else { return nil }
            }.first
            return told + LeaseWords.released(lease.displayName, passedTo: next.map(holderName))
        case .leftLine:
            return told + LeaseWords.leftLine(display)
        default:
            return told + LeaseWords.neither(display)
        }
    }

    /// `list_resources`: the caller's own first, then everything the Mac has.
    public func listLeases(_ request: DaemonAPI.LeaseTokenRequest) async throws -> String {
        let caller = try leaseCaller(request.token)
        foundResources = await resourceCatalog.found()
        let loaded = loadLeasesIfNeeded()
        let told = noticesText(for: caller.id)
        await settle(loaded)

        var lines: [String] = []
        let held = leaseBook.held(by: caller.id)
        let waits = leaseBook.waits(of: caller.id)
        if !held.isEmpty || !waits.isEmpty {
            lines.append("Yours:")
            for lease in held {
                lines.append("- Holding \(lease.displayName) (\(lease.resource.key)) until \(LeaseWords.clock(lease.expiresAt)).")
            }
            for wait in waits {
                guard let lease = wait.entry.lease else { continue }
                lines.append("- Waiting for \(wait.entry.displayName) (\(wait.name.key)): held by "
                             + "\(holderName(lease.holder)) until \(LeaseWords.clock(lease.expiresAt)), "
                             + "you are \(LeaseWords.ordinal(wait.place)).")
            }
            lines.append("")
        }
        lines.append("On this Mac:")
        for state in buildLeaseSnapshot().resources {
            let label = state.kind == .named
                ? "\(state.displayName) (named by an agent)"
                : "\(state.name.key) \u{2014} \(state.displayName)"
            var said = state.isGone ? " (gone from this Mac)" : ""
            if let lease = state.lease {
                let who = lease.holder == caller.id ? "you" : holderName(lease.holder)
                said += ": held by \(who) until \(LeaseWords.clock(lease.expiresAt))"
                said += state.line.isEmpty ? "." : "; \(state.line.count) waiting."
            } else {
                said += ": free."
            }
            lines.append("- \(label)\(said)")
        }
        return told + lines.joined(separator: "\n")
    }

    // MARK: The person's

    /// Every resource worth drawing, with the catalog asked afresh.
    public func leaseSnapshot() async -> DaemonAPI.LeaseSnapshot {
        foundResources = await resourceCatalog.found()
        let loaded = loadLeasesIfNeeded()
        if !loaded.isEmpty { leasesChanged() }
        await settle(loaded)
        return buildLeaseSnapshot()
    }

    /// The person ending whoever holds a resource (US4). The holder is told at its
    /// next lease call and not interrupted; the next in line gets it now.
    public func endLease(_ request: DaemonAPI.PersonEndRequest) async throws -> DaemonAPI.LeaseSnapshot {
        let loaded = loadLeasesIfNeeded()
        guard let name = ResourceName(request.name) else {
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused, message: "Say which resource to end.")
        }
        let events = leaseBook.end(name, now: now())
        guard !events.isEmpty else {
            await settle(loaded)
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused, message: "Nobody holds \(request.name).")
        }
        leasesChanged()
        await settle(loaded + events)
        return buildLeaseSnapshot()
    }

    /// The person taking one agent out of one line. A call it still has open is
    /// answered with why.
    public func removeWaiter(_ request: DaemonAPI.PersonRemoveRequest) async throws -> DaemonAPI.LeaseSnapshot {
        let loaded = loadLeasesIfNeeded()
        guard let name = ResourceName(request.name),
              let agentID = UUID(uuidString: request.agentID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused, message: "Say which resource and which agent.")
        }
        let display = leaseBook.entry(name)?.displayName ?? request.name
        let openCall = leaseBook.entry(name)?.line.first { $0.agentID == agentID }?.waitID
        let events = leaseBook.removeFromLine(name, agent: agentID)
        guard !events.isEmpty else {
            await settle(loaded)
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused,
                               message: "That agent is not in line for \(display).")
        }
        leasesChanged()
        if let openCall { answer(openCall, .success(LeaseWords.removedWhileWaiting(display))) }
        await settle(loaded + events)
        return buildLeaseSnapshot()
    }

    // MARK: Stop and archive

    /// Everything an agent holds given back and every line it is in left, when it is
    /// stopped or archived (FR-007). Not at the end of a turn: a lease outlives a turn
    /// by design (Clarification 1).
    ///
    /// Synchronous on purpose, so `stop` can call it before its first `await` and no
    /// grant can land on an agent halfway through stopping. What it returns is said
    /// afterwards, with `settle`.
    func dropLeases(for agentID: UUID, ending: LeaseEnding) -> [LeaseEvent] {
        let loaded = loadLeasesIfNeeded()
        for wait in leaseBook.waits(of: agentID) {
            if let open = wait.entry.line.first(where: { $0.agentID == agentID })?.waitID {
                answer(open, .failure(JSONRPCError(code: DaemonAPI.Failure.leaseRefused,
                                                   message: LeaseWords.stoppedWhileWaiting(wait.entry.displayName))))
            }
        }
        let events = leaseBook.drop(agentID, because: ending, now: now())
        if !events.isEmpty || !loaded.isEmpty { leasesChanged() }
        return loaded + events
    }

    // MARK: Time

    /// Whatever the clock has done since the last look: expiries handed on, holders
    /// warned. What the timer calls, and what a test calls after moving the clock.
    func lapseLeases() async {
        let loaded = loadLeasesIfNeeded()
        let events = loaded + leaseBook.lapse(now: now())
        leasesChanged()
        await settle(events)
    }

    /// Aim the one timer at the book's next deadline.
    func armLeaseTimer() {
        leaseTimer?.cancel()
        leaseTimer = nil
        guard let deadline = leaseBook.nextDeadline else { return }
        let delay = max(0, deadline.timeIntervalSince(now())) + 0.05
        leaseTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.lapseLeases()
        }
    }

    // MARK: Loading

    /// The book from disk, the first time it is wanted. No call that was waiting
    /// survives a restart, so every waiter is one to start instead; and whatever
    /// expired while the daemon was down is released now (US5-AS4).
    @discardableResult
    func loadLeasesIfNeeded() -> [LeaseEvent] {
        guard !leaseBookIsLoaded else { return [] }
        leaseBookIsLoaded = true
        leaseBook = leaseStore.load()
        leaseBook.closeAllWaits()
        return leaseBook.lapse(now: now())
    }

    /// Save, tell every window, and re-aim the timer. After every change.
    func leasesChanged() {
        do {
            try leaseStore.save(leaseBook)
        } catch {
            DaemonLog.shared.write("could not save leases.json: \(error)")
        }
        broadcast(DaemonAPI.Notification.leasesChanged, buildLeaseSnapshot())
        armLeaseTimer()
        keepLeaseMinutesTicking()
    }

    /// Once a minute while anything is held, the windows are told again, so the
    /// minutes left on a card count down without each window keeping its own clock.
    private func keepLeaseMinutesTicking() {
        let anythingHeld = leaseBook.entries.values.contains { $0.lease != nil }
        guard anythingHeld else {
            leaseMinuteTicker?.cancel()
            leaseMinuteTicker = nil
            return
        }
        guard leaseMinuteTicker == nil else { return }
        leaseMinuteTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                guard await self.tickLeaseMinutes() else { return }
            }
        }
    }

    /// One tick. False when there is nothing left to count down.
    private func tickLeaseMinutes() -> Bool {
        guard leaseBook.entries.values.contains(where: { $0.lease != nil }) else {
            leaseMinuteTicker = nil
            return false
        }
        broadcast(DaemonAPI.Notification.leasesChanged, buildLeaseSnapshot())
        return true
    }

    // MARK: Saying what happened

    /// Turn what the book did into words and starts. Called after the book has been
    /// changed and saved, so every `await` in here is on a book that is already right.
    func settle(_ events: [LeaseEvent]) async {
        let at = now()
        for event in events {
            switch event {
            case .granted(let lease, let waiter, let capped):
                guard let waiter else {
                    await record(.runtimeNote(LeaseWords.noteLeased(lease)), for: lease.holder)
                    continue
                }
                if let call = waiter.waitID, openWaits[call] != nil {
                    let waited = Int(at.timeIntervalSince(openWaitStarted[call] ?? waiter.askedAt).rounded())
                    answer(call, .success(LeaseWords.grantedAfterWaiting(lease, waited: waited, capped: capped)))
                    await record(.runtimeNote(LeaseWords.noteLeased(lease)), for: lease.holder)
                } else {
                    // Its call has returned. Started again, on the actor but not in
                    // this call: starting a runtime is a long wait, and the agent that
                    // let go of the lease should not sit through it.
                    Task { await self.wake(lease, askedAt: waiter.askedAt) }
                }
            case .extended(let lease, _):
                await record(.runtimeNote(LeaseWords.noteExtended(lease)), for: lease.holder)
            case .released(let lease, let ending):
                if let note = LeaseWords.noteEnded(lease, ending, at: at) {
                    await record(.runtimeNote(note), for: lease.holder)
                }
            case .queued, .refused, .stillWaiting, .leftLine, .nothingHeld, .warned:
                continue
            }
        }
    }

    /// A lease has reached an agent whose call already returned: start it again with
    /// the news (FR-006). If it cannot be started — gone, at a spending limit, a
    /// runtime that will not start — the lease is given up for it and passed on, and
    /// its transcript says why.
    func wake(_ lease: Lease, askedAt: Date) async {
        let agentID = lease.holder
        guard leaseBook.entry(lease.resource)?.lease?.holder == agentID else { return }
        await record(.runtimeNote(LeaseWords.noteLeased(lease)), for: agentID)
        let text = LeaseWords.wake(lease, askedAt: askedAt)
        var reason: String?
        let limits = limitStore.load()
        if let agent = agents[agentID] {
            if agent.isAtCostLimit(under: limits) {
                reason = "it is at its spending limit"
            } else if isDayLimitReached(under: limits) {
                reason = "the day's spending limit has been reached"
            } else {
                do {
                    try await prompt(DaemonAPI.PromptRequest(agentID: agentID, text: text, from: .app))
                } catch {
                    reason = (error as? JSONRPCError)?.message ?? error.localizedDescription
                    // The words stay queued when a runtime will not start. These must
                    // not: the lease they announce is about to go to somebody else.
                    if var agent = agents[agentID] {
                        agent.queuedPrompts.removeAll { $0.from == .app && $0.text == text }
                        changed(agent)
                    }
                }
            }
        } else {
            reason = "it is not here any more"
        }
        guard let reason else { return }
        let events = leaseBook.giveUp(lease.resource, heldBy: agentID, now: now())
        guard !events.isEmpty else { return }
        leasesChanged()
        await record(.runtimeNote(LeaseWords.noteCouldNotStart(lease.displayName, reason: reason)), for: agentID)
        await settle(events)
    }

    /// For tests: a fixed list of what the Mac has, and a shorter wait.
    func useForLeases(catalog: any ResourceFinding, waitLimit: Duration? = nil) {
        resourceCatalog = catalog
        if let waitLimit { leaseWaitLimit = waitLimit }
    }

    // MARK: Inside

    private func leaseCaller(_ token: String) throws -> Agent {
        guard let id = appTokens[token], let agent = agents[id] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: LeaseWords.noConversation)
        }
        return agent
    }

    /// A name as the catalog knows it, keeping the answer for the next snapshot.
    private func resolveResource(_ given: String) async -> FoundResource? {
        let found = await resourceCatalog.found()
        foundResources = found
        return await FixedCatalog(found).resolve(given)
    }

    /// Whatever the agent has been left to be told, as the head of its reply.
    private func noticesText(for agentID: UUID) -> String {
        let notices = leaseBook.takeNotices(for: agentID)
        guard !notices.isEmpty else { return "" }
        return notices.map(LeaseWords.notice).joined(separator: "\n") + "\n\n"
    }

    func holderName(_ id: UUID) -> String {
        LeaseWords.agentName(agents[id]?.title)
    }

    private func scheduleWaitLimit(_ waitID: UUID) {
        let limit = leaseWaitLimit
        Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.waitLimitReached(waitID)
        }
    }

    /// The call has waited as long as a call may. It answers with the place, which is
    /// kept; the agent will be started when its turn comes.
    private func waitLimitReached(_ waitID: UUID) {
        guard openWaits[waitID] != nil else { return }
        let display = leaseBook.names.lazy.compactMap { self.leaseBook.entry($0) }
            .first { $0.line.contains { $0.waitID == waitID } }?.displayName ?? "It"
        let events = leaseBook.waitTimedOut(waitID)
        leasesChanged()
        guard case .stillWaiting(let place, let holder, let until)? = events.first else {
            answer(waitID, .success(LeaseWords.leftLine(display)))
            return
        }
        answer(waitID, .success(LeaseWords.stillInLine(display, holder: holderName(holder),
                                                       until: until, place: place)))
    }

    /// Answer a waiting call once. Taken out of the table first, so nothing can
    /// answer it twice.
    private func answer(_ waitID: UUID, _ result: Result<String, JSONRPCError>) {
        openWaitStarted.removeValue(forKey: waitID)
        openWaits.removeValue(forKey: waitID)?.resume(returning: result)
    }

    /// The snapshot from the book and what the catalog last said.
    func buildLeaseSnapshot() -> DaemonAPI.LeaseSnapshot {
        let at = now()
        var rows: [DaemonAPI.ResourceState] = []
        var drawn = Set<ResourceName>()
        func row(_ name: ResourceName, kind: ResourceKind, display: String, gone: Bool) -> DaemonAPI.ResourceState {
            let entry = leaseBook.entry(name)
            return DaemonAPI.ResourceState(
                name: name, kind: kind, displayName: entry?.displayName ?? display, isGone: gone,
                lease: entry?.lease,
                line: entry?.line.map { DaemonAPI.LineMember(agentID: $0.agentID, askedAt: $0.askedAt,
                                                             isCallOpen: $0.isCallOpen && openWaits[$0.waitID!] != nil) } ?? [],
                endingSoon: entry?.lease?.isEndingSoon(at: at) ?? false)
        }
        for found in foundResources ?? [] {
            rows.append(row(found.name, kind: found.kind, display: found.displayName, gone: false))
            drawn.insert(found.name)
        }
        for name in leaseBook.names where !drawn.contains(name) {
            guard let entry = leaseBook.entry(name) else { continue }
            let gone = entry.kind != .named && foundResources != nil
            rows.append(row(name, kind: entry.kind, display: entry.displayName, gone: gone))
        }
        let order: [ResourceKind: Int] = [.screen: 0, .simulator: 1, .browser: 2, .named: 3]
        rows.sort {
            (order[$0.kind] ?? 9, $0.displayName.lowercased(), $0.name.key)
                < (order[$1.kind] ?? 9, $1.displayName.lowercased(), $1.name.key)
        }
        return DaemonAPI.LeaseSnapshot(resources: rows, at: at)
    }
}

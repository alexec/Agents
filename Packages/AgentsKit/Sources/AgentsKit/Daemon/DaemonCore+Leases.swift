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
                                       rules: rules(for: resource.name),
                                       by: caller.id, minutes: request.minutes, wait: wait,
                                       waitID: waitID, now: now())
        let display = leaseBook.entry(resource.name)?.displayName ?? resource.displayName
        let held = heldWords(resource.name, display: display)

        switch events.first {
        case .granted(let lease, _, let capped):
            leasesChanged()
            await settle(loaded + events)
            return told + LeaseWords.granted(lease, capped: capped)
        case .extended(let lease, let capped):
            leasesChanged()
            await settle(loaded + events)
            return told + LeaseWords.extended(lease, capped: capped)
        case .refused:
            await settle(loaded)
            return told + LeaseWords.refused(held: held)
        case .stillWaiting(let place, _, _) where !wait:
            await settle(loaded)
            return told + LeaseWords.stillInLine(held: held, place: place)
        case .queued, .stillWaiting:
            guard let waitID else { return told }
            leasesChanged()
            if let superseded, case .stillWaiting(let place, _, _)? = events.first {
                answer(superseded, .success(LeaseWords.stillInLine(held: held, place: place)))
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
                lines.append("- Waiting for \(wait.entry.displayName) (\(wait.name.key)): "
                             + "\(heldWords(wait.name, display: wait.entry.displayName)); "
                             + "you are \(LeaseWords.ordinal(wait.place)).")
            }
            lines.append("")
        }
        let states = buildLeaseSnapshot().resources
        let declared = states.filter { $0.declared != nil }
        if !declared.isEmpty {
            lines.append("Declared by the person. Lease one whenever its description applies to what you "
                         + "are about to do:")
            for state in declared {
                guard let declaration = state.declared else { continue }
                lines.append("- \(state.name.key) (\(LeaseWords.placesWords(state.places))): "
                             + "\(declaration.description) \u{2014} \(stateWords(state, caller: caller.id))")
            }
            lines.append("")
        }
        lines.append("On this Mac:")
        for state in states where state.declared == nil {
            let label = state.kind == .named
                ? "\(state.displayName) (named by an agent)"
                : "\(state.name.key) \u{2014} \(state.displayName)"
            let gone = state.isGone ? " (gone from this Mac)" : ""
            lines.append("- \(label)\(gone): \(stateWords(state, caller: caller.id))")
        }
        return told + lines.joined(separator: "\n")
    }

    /// "free.", "held by you until 14:05.", "2 of 3 held: by you until 14:05 and
    /// “Fix login” until 14:20; 1 waiting."
    private func stateWords(_ state: DaemonAPI.ResourceState, caller: UUID) -> String {
        guard !state.holds.isEmpty else {
            return state.places > 1 ? "free (0 of \(state.places) held)." : "free."
        }
        let who = state.holds.map { lease in
            (lease.holder == caller ? "you" : holderName(lease.holder)) + " until \(LeaseWords.clock(lease.expiresAt))"
        }
        let listed = who.count <= 2 ? who.joined(separator: " and ")
            : who.dropLast().joined(separator: ", ") + " and " + who[who.count - 1]
        let count = state.heldCount.map { "\($0): by " } ?? "held by "
        return count + listed + (state.line.isEmpty ? "." : "; \(state.line.count) waiting.")
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
        var holder: UUID?
        if let given = request.agentID?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty {
            guard let id = UUID(uuidString: given) else {
                await settle(loaded)
                throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused, message: "Say which agent's lease to end.")
            }
            holder = id
        }
        let events = leaseBook.end(name, holder: holder, now: now())
        guard !events.isEmpty else {
            await settle(loaded)
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused,
                               message: holder == nil ? "Nobody holds \(request.name)."
                                                      : "That agent does not hold \(request.name).")
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

    // MARK: Declaring (#116)

    /// The person adding a declared resource, or changing one. A changed count or
    /// length applies to the book at once: more places let the line in, and fewer take
    /// nothing from anyone holding it.
    public func declareResource(_ request: DaemonAPI.DeclareResourceRequest) async throws -> DaemonAPI.LeaseSnapshot {
        let loaded = loadLeasesIfNeeded()
        var resource = request.resource
        resource.displayName = resource.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        resource.description = resource.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = resource.problem {
            await settle(loaded)
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused, message: problem)
        }
        let replacing = request.replacing.flatMap(ResourceName.init)
        if resource.name != replacing, declaredResources.contains(where: { $0.name == resource.name }) {
            await settle(loaded)
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused,
                               message: "\(resource.displayName) is declared already.")
        }
        var list = declaredResources.filter { $0.name != resource.name && $0.name != replacing }
        list.append(resource)
        list.sort { $0.name < $1.name }
        do {
            try declaredResourceStore.save(list)
        } catch {
            await settle(loaded)
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused, message: "Could not save it: \(error.localizedDescription)")
        }
        declaredResources = list
        DaemonLog.shared.write("resources: declared \(resource.name.key), \(resource.holders) at once")
        let events = leaseBook.setRules(resource.rules, for: resource.name, now: now())
        leasesChanged()
        await settle(loaded + events)
        return buildLeaseSnapshot()
    }

    /// The person taking a declaration away. Whoever holds it keeps the lease, under
    /// the rules it had, and it is an ordinary named resource from then on.
    public func removeDeclaredResource(_ request: DaemonAPI.RemoveResourceRequest) async throws -> DaemonAPI.LeaseSnapshot {
        let loaded = loadLeasesIfNeeded()
        guard let name = ResourceName(request.name), declaredResources.contains(where: { $0.name == name }) else {
            await settle(loaded)
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused, message: "\(request.name) is not declared.")
        }
        let list = declaredResources.filter { $0.name != name }
        do {
            try declaredResourceStore.save(list)
        } catch {
            await settle(loaded)
            throw JSONRPCError(code: DaemonAPI.Failure.leaseRefused, message: "Could not save it: \(error.localizedDescription)")
        }
        declaredResources = list
        DaemonLog.shared.write("resources: removed \(name.key)")
        leasesChanged()
        await settle(loaded)
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
        loadDeclaredIfNeeded()
        leaseBook.closeAllWaits()
        // A count raised while the daemon was down lets the line in now.
        var events: [LeaseEvent] = []
        for declared in declaredResources {
            events += leaseBook.setRules(declared.rules, for: declared.name, now: now())
        }
        return events + leaseBook.lapse(now: now())
    }

    /// What the person declared, the first time it is wanted.
    func loadDeclaredIfNeeded() {
        guard !declaredResourcesAreLoaded else { return }
        declaredResourcesAreLoaded = true
        declaredResources = declaredResourceStore.load()
    }

    /// Save, tell every window, and re-aim the timer. After every change.
    func leasesChanged() {
        keepQuietly("the resource leases") { try leaseStore.save(leaseBook) }
        broadcast(DaemonAPI.Notification.leasesChanged, buildLeaseSnapshot())
        armLeaseTimer()
        keepLeaseMinutesTicking()
    }

    /// Once a minute while anything is held, the windows are told again, so the
    /// minutes left on a card count down without each window keeping its own clock.
    private func keepLeaseMinutesTicking() {
        let anythingHeld = leaseBook.anythingHeld
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
        guard leaseBook.anythingHeld else {
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
            raiseLeaseEvent(event)
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
        guard leaseBook.entry(lease.resource)?.lease(of: agentID) != nil else { return }
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
        loadDeclaredIfNeeded()
        if let name = ResourceName(given), let declared = declaredResources.first(where: { $0.name == name }) {
            return FoundResource(name: name, kind: .named, displayName: declared.displayName)
        }
        return await FixedCatalog(found).resolve(given)
    }

    /// Whatever the agent has been left to be told, as the head of its reply.
    private func noticesText(for agentID: UUID) -> String {
        let notices = leaseBook.takeNotices(for: agentID)
        guard !notices.isEmpty else { return "" }
        return notices.map(LeaseWords.notice).joined(separator: "\n") + "\n\n"
    }

    /// The rules a lease on `name` runs by: its declaration's, or the standard ones.
    func rules(for name: ResourceName) -> LeaseRules {
        declaredResources.first { $0.name == name }?.rules ?? .standard
    }

    /// Who holds `name`, as someone in its line is told it.
    func heldWords(_ name: ResourceName, display: String) -> String {
        let entry = leaseBook.entry(name)
        let holders = (entry?.leases ?? []).sorted { $0.expiresAt < $1.expiresAt }
            .map { (name: holderName($0.holder), until: $0.expiresAt) }
        return LeaseWords.heldBy(display, holders: holders, places: entry?.rules.holders ?? 1)
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
        let name = leaseBook.names.first { name in
            leaseBook.entry(name)?.line.contains { $0.waitID == waitID } == true
        }
        let display = name.flatMap { leaseBook.entry($0)?.displayName } ?? "It"
        let events = leaseBook.waitTimedOut(waitID)
        leasesChanged()
        guard case .stillWaiting(let place, _, _)? = events.first, let name else {
            answer(waitID, .success(LeaseWords.leftLine(display)))
            return
        }
        answer(waitID, .success(LeaseWords.stillInLine(held: heldWords(name, display: display), place: place)))
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
        func row(_ name: ResourceName, kind: ResourceKind, display: String, gone: Bool,
                 declared: DeclaredResource? = nil) -> DaemonAPI.ResourceState {
            let entry = leaseBook.entry(name)
            let holds = entry?.leases ?? []
            return DaemonAPI.ResourceState(
                name: name, kind: kind, displayName: declared?.displayName ?? entry?.displayName ?? display,
                isGone: gone, holds: holds,
                places: declared?.holders ?? entry?.rules.holders ?? 1, declared: declared,
                line: entry?.line.map { DaemonAPI.LineMember(agentID: $0.agentID, askedAt: $0.askedAt,
                                                             isCallOpen: $0.isCallOpen && openWaits[$0.waitID!] != nil) } ?? [],
                endingSoon: holds.contains { $0.isEndingSoon(at: at) })
        }
        for declared in declaredResources {
            rows.append(row(declared.name, kind: .named, display: declared.displayName, gone: false, declared: declared))
            drawn.insert(declared.name)
        }
        for found in foundResources ?? [] where !drawn.contains(found.name) {
            rows.append(row(found.name, kind: found.kind, display: found.displayName, gone: false))
            drawn.insert(found.name)
        }
        for name in leaseBook.names where !drawn.contains(name) {
            guard let entry = leaseBook.entry(name) else { continue }
            let gone = entry.kind != .named && foundResources != nil
            rows.append(row(name, kind: entry.kind, display: entry.displayName, gone: gone))
        }
        // Declared first, then by kind, then as Finder sorts names: "iPhone 9" before
        // "iPhone 17".
        let order: [ResourceKind: Int] = [.screen: 0, .simulator: 1, .browser: 2, .named: 3]
        rows.sort {
            if ($0.declared == nil) != ($1.declared == nil) { return $0.declared != nil }
            let (a, b) = (order[$0.kind] ?? 9, order[$1.kind] ?? 9)
            if a != b { return a < b }
            switch $0.displayName.localizedStandardCompare($1.displayName) {
            case .orderedSame: return $0.name < $1.name
            case let result: return result == .orderedAscending
            }
        }
        return DaemonAPI.LeaseSnapshot(resources: rows, at: at)
    }
}

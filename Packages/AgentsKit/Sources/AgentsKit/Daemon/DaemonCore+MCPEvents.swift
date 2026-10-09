import AgentsKitCore
import Foundation

/// A subscription to a server's event (#383, data-model.md): one server, event and set of
/// arguments in one project on this host, shared by every workflow whose trigger makes it.
struct MCPSubscription: Sendable, Equatable {
    var key: String
    var project: URL
    var server: String
    var event: String
    var arguments: [String: JSONValue]
    /// The workflows whose triggers make it, by id, sorted.
    var workflows: [String]
    var pool: MCPClientPool.Key
    var filled: MCPServer
    var cwd: URL
    /// What a stopped subscription waits to see change: the event as the server lists
    /// it, the server's entry, and the workflows' files.
    var fingerprint: String

    /// Its record's key, `"<project path>|<key>"`.
    var id: String { MCPEventRecords.key(project: project, subscription: key) }
}

/// The source's memory (#383). In the core, because only an actor's stored properties
/// can hold it; reached only from `DaemonCore+MCPEvents.swift`.
struct MCPEventsState {
    /// One line under a trigger: a subscription's, or a fixed one saying why there is none.
    struct Line: Equatable, Sendable {
        var event: String
        var server: String?
        var subscription: String?
        var fixed: MCPTriggerStatus?
    }

    /// What a subscription is doing now, beside what its record keeps.
    struct Live: Equatable, Sendable {
        var state: MCPTriggerStatus.State
        var failure: MCPTriggerFailure?
        var retryAt: Date?
        /// Set when it stopped: it starts again only when its fingerprint changes.
        var stoppedFor: String?
    }

    /// A server's events as last listed.
    struct Listing: Sendable {
        /// Nil when the server declares no `events` capability.
        var events: [EventDefinition]?
        var at: Date
        /// Why the last listing failed, when it did; `events` is then the one before.
        var failure: MCPEventsError?
        var stale = false
    }

    var started = false
    var clients = MCPEventClients()
    /// How a poll waits. A test hands in a clock it moves by hand.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var subscriptions: [String: MCPSubscription] = [:]
    var tasks: [String: Task<Void, Never>] = [:]
    var live: [String: Live] = [:]
    var listings: [MCPClientPool.Key: Listing] = [:]
    /// Each workflow's lines, by `Workflow.id`, in file order and then by server.
    var lines: [String: [Line]] = [:]
    var records: MCPEventRecords?
    /// Subscriptions whose next raised event says events may have been missed.
    var missedToTell: Set<String> = []
    /// Servers whose badly named events were logged on this connection.
    var loggedBadNames: Set<MCPClientPool.Key> = []
    /// When each subscription's line was last told to the windows, so "Checked 20 s ago"
    /// is put right at most once a minute rather than on every poll.
    var announced: [String: Date] = [:]
    var reconciling = false
    var reconcileAgain = false
    /// The user each hosted server's event connection is to it (#488), by server.
    var hostedUsers: [MCPClientPool.Key: String] = [:]
    var ticker: Task<Void, Never>?
}

extension DaemonCore {
    /// The pace (research R6): at most every 10 s, at least every 5 min, 30 s unsaid.
    static let mcpPollFloor: Duration = .seconds(10)
    static let mcpPollCeiling: Duration = .seconds(300)
    static let mcpPollDefault: Duration = .seconds(30)
    /// `hasMore` pages asked for in a row before waiting.
    static let mcpPageLimit = 10
    /// A server's events are listed again this often, as well as on `list_changed`.
    static let mcpRelistAfter: TimeInterval = 600
    /// What an event's data may take in `details.payload`.
    static let mcpPayloadLimit = 256 * 1024

    var mcpEventStore: MCPEventStore { MCPEventStore(root: locations.root) }

    /// The servers' events some subscription asks for in a project, sorted: the only
    /// server events a wait there can hear.
    func mcpEventsHeard(in project: URL) -> [String] {
        let folder = Project.standardize(project)
        return Set(mcpEvents.subscriptions.values.filter { Project.standardize($0.project) == folder }.map(\.event))
            .sorted()
    }

    // MARK: Starting and stopping

    /// Begin hearing servers' events. `http` and `sleep` are for tests: a stand-in server
    /// and a clock moved by hand.
    func startMCPEvents(http: MCPClient.HTTPSend? = nil,
                        sleep: (@Sendable (Duration) async throws -> Void)? = nil) async {
        guard !mcpEvents.started else { return }
        mcpEvents.started = true
        mcpEvents.clients = MCPEventClients(http: http)
        if let sleep { mcpEvents.sleep = sleep }
        await mcpEvents.clients.onListChanged { [weak self] key in
            Task { await self?.mcpEventsListChanged(key) }
        }
        // The rest of what can change a subscription — an approval, mcp.json, a plugin,
        // a sign-in, secrets.env, the 10-minute relist — is looked at once a minute. It
        // costs no request unless a list is due.
        mcpEvents.ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.reconcileMCPEvents()
            }
        }
        await reconcileMCPEvents()
    }

    func stopMCPEvents() async {
        guard mcpEvents.started else { return }
        mcpEvents.started = false
        mcpEvents.ticker?.cancel()
        mcpEvents.ticker = nil
        for task in mcpEvents.tasks.values { task.cancel() }
        mcpEvents.tasks = [:]
        await mcpEvents.clients.endAll()
        for user in mcpEvents.hostedUsers.values { await hostedServers.release(user) }
        mcpEvents.hostedUsers = [:]
    }

    /// Look again soon: a workflow file moved.
    func scheduleMCPEventsReconcile() {
        guard mcpEvents.started else { return }
        Task { [weak self] in await self?.reconcileMCPEvents() }
    }

    /// A hosted server said its events changed (#488): its own copy hears it, not the
    /// event connection, which has no stream.
    func hostedServerListChanged(_ key: MCPClientPool.Key) async {
        guard mcpEvents.started, mcpEvents.hostedUsers[key] != nil else { return }
        await mcpEventsListChanged(key)
    }

    private func mcpEventsListChanged(_ key: MCPClientPool.Key) async {
        mcpEvents.listings[key]?.stale = true
        DaemonLog.shared.write("mcp events: \(key.name) says its events changed")
        await reconcileMCPEvents()
    }

    // MARK: Which subscriptions

    /// Work out the subscriptions from every workflow's triggers, start the new ones, end
    /// the gone ones, and say each trigger's lines. One at a time: a second ask while one
    /// runs is one more pass after it.
    func reconcileMCPEvents() async {
        guard mcpEvents.started else { return }
        if mcpEvents.reconciling {
            mcpEvents.reconcileAgain = true
            return
        }
        mcpEvents.reconciling = true
        repeat {
            mcpEvents.reconcileAgain = false
            await reconcileMCPEventsOnce()
        } while mcpEvents.reconcileAgain && mcpEvents.started
        mcpEvents.reconciling = false
    }

    /// The workflows whose server-event triggers this host asks for: on, not archived,
    /// readable, approved, and run here.
    private func workflowsHearingServers() -> [Workflow] {
        let records = workflowStore.load()
        return workflows.keys.sorted { $0.path < $1.path }.flatMap { folder in
            (workflows[folder] ?? [:]).values.sorted { $0.workflowID < $1.workflowID }.filter { workflow in
                workflow.triggers.contains { if case .serverEvent = $0 { true } else { false } }
                    && workflow.runs(on: MachineID.current) && workflow.problem == nil && !workflow.isArchived
                    && !workflow.isOff
                    && awaitingApproval(workflow, state: records.state(folder: workflow.folder,
                                                                        workflowID: workflow.workflowID),
                                        records: records) == nil
            }
        }
    }

    private func reconcileMCPEventsOnce() async {
        let at = now()
        var wanted: [String: MCPSubscription] = [:]
        var lines: [String: [MCPEventsState.Line]] = [:]
        // Per project, the servers as resolved this pass, by name.
        var resolved: [URL: [String: Result<ViewServer, ViewServerProblem>]] = [:]

        for workflow in workflowsHearingServers() {
            let folder = workflow.folder
            let names = mcpServerNames(project: folder)
            if resolved[folder] == nil {
                var servers: [String: Result<ViewServer, ViewServerProblem>] = [:]
                for name in names { servers[name] = await mcpEventServer(name, project: folder) }
                resolved[folder] = servers
            }
            var workflowLines: [MCPEventsState.Line] = []
            for trigger in workflow.triggers {
                guard case .serverEvent(let trigger) = trigger else { continue }
                var triggerLines: [MCPEventsState.Line] = []
                var unreachable: [String] = []
                var waiting: [String] = []
                let named = trigger.servers != nil
                for name in (trigger.servers ?? names).sorted() {
                    func fixed(_ code: MCPTriggerFailure.Code, _ message: String,
                               state: MCPTriggerStatus.State = .stopped) {
                        guard named else { return }
                        triggerLines.append(.init(event: trigger.event, server: name, fixed: MCPTriggerStatus(
                            name: trigger.event, server: name, state: state,
                            failure: MCPTriggerFailure(code: code, message: message, since: at))))
                    }
                    guard let found = resolved[folder]?[name] else {
                        fixed(.serverNotFound, "\(name) is not set up here.")
                        continue
                    }
                    let server: ViewServer
                    switch found {
                    case .success(let ready): server = ready
                    case .failure(.waiting):
                        waiting.append(name)
                        fixed(.waitingForApproval, "\(name) is waiting for approval in this project's MCP servers.")
                        continue
                    case .failure(.missingSecret):
                        fixed(.secretMissing, "\(name) needs a secret that isn't set here.")
                        continue
                    case .failure(.signIn):
                        fixed(.needsSignIn, "\(name) wants a sign-in first.")
                        continue
                    case .failure(.oldTransport):
                        fixed(.serverError, "\(name) uses the old sse transport, which can't offer events.")
                        continue
                    case .failure:
                        fixed(.serverNotFound, "\(name) is not set up here.")
                        continue
                    }
                    let listing = await mcpEventListing(server)
                    guard let offered = listing.events else {
                        if let failure = listing.failure {
                            unreachable.append(name)
                            fixed(.unreachable, Self.mcpWords(failure, server: name), state: .retrying)
                        } else {
                            fixed(.noEvents, "\(name) doesn't offer events.")
                        }
                        continue
                    }
                    guard let definition = offered.first(where: { $0.name == trigger.event }) else {
                        let others = offered.map(\.name).filter(EventCatalogue.isServerEventName).sorted()
                        fixed(.eventNotOffered, "\(name) doesn't offer \(trigger.event)"
                              + (others.isEmpty ? "." : "; it offers \(others.joined(separator: ", ")).") )
                        continue
                    }
                    // From here a server that offers the name has a line, named or not.
                    func stopped(_ code: MCPTriggerFailure.Code, _ message: String) {
                        triggerLines.append(.init(event: trigger.event, server: name, fixed: MCPTriggerStatus(
                            name: trigger.event, server: name, state: .stopped,
                            failure: MCPTriggerFailure(code: code, message: message, since: at))))
                    }
                    guard definition.offersPoll else {
                        stopped(.noPollMode, "\(name) offers \(trigger.event) only by push or webhook, "
                                + "which this version doesn't take.")
                        continue
                    }
                    if let schema = definition.inputSchema,
                       let problem = JSONSchemaSubset.check(.object(trigger.arguments), against: schema,
                                                            name: "\(name)'s \(trigger.event)") {
                        stopped(.badArguments, problem)
                        continue
                    }
                    let key = trigger.subscriptionKey(server: name)
                    let id = MCPEventRecords.key(project: folder, subscription: key)
                    if var already = wanted[id] {
                        already.workflows = Array(Set(already.workflows + [workflow.workflowID])).sorted()
                        wanted[id] = already
                    } else {
                        wanted[id] = MCPSubscription(
                            key: key, project: folder, server: name, event: trigger.event,
                            arguments: trigger.arguments, workflows: [workflow.workflowID],
                            pool: server.poolKey, filled: server.filled, cwd: server.cwd, fingerprint: "")
                    }
                    triggerLines.append(.init(event: trigger.event, server: name, subscription: id))
                    let definitionText = MCPEventTrigger.canonicalJSON(definition.wire)
                    wanted[id]?.fingerprint = definitionText + "\n" + server.entry
                }
                if triggerLines.isEmpty, !waiting.isEmpty {
                    // It may well be offered by a server nobody has approved yet: say that,
                    // not that no server offers it.
                    let names = waiting.joined(separator: ", ")
                    triggerLines.append(.init(event: trigger.event, server: nil, fixed: MCPTriggerStatus(
                        name: trigger.event, server: nil, state: .stopped,
                        failure: MCPTriggerFailure(code: .waitingForApproval,
                                                   message: "\(names) \(waiting.count == 1 ? "is" : "are") waiting for "
                                                       + "approval in this project's MCP servers, so \(trigger.event) "
                                                       + "is not asked for yet.",
                                                   since: at))))
                }
                if triggerLines.isEmpty {
                    let guess = EventPatternProblem.closest(to: trigger.event).map { " Did you mean \($0)?" } ?? ""
                    let why = unreachable.isEmpty ? "" : " \(unreachable.joined(separator: ", ")) could not be asked."
                    triggerLines.append(.init(event: trigger.event, server: nil, fixed: MCPTriggerStatus(
                        name: trigger.event, server: nil, state: unreachable.isEmpty ? .stopped : .pending,
                        failure: MCPTriggerFailure(code: .serverNotFound,
                                                   message: "No server here offers \(trigger.event).\(why)\(guess)",
                                                   since: at))))
                }
                workflowLines += triggerLines
            }
            lines[workflow.id] = workflowLines
        }
        // A workflow's file is part of what a stopped subscription waits on.
        for (id, subscription) in wanted {
            let digests = subscription.workflows.map { workflowID in
                workflows[subscription.project]?[workflowID].flatMap { workflowDigest($0) } ?? workflowID
            }
            wanted[id]?.fingerprint += "\n" + digests.joined(separator: ",")
        }
        guard mcpEvents.started else { return }
        applyMCPSubscriptions(wanted)
        // Lines keep the time a fixed failure was first seen, so "since" does not move
        // with each look.
        for (workflowID, fresh) in lines {
            let old = mcpEvents.lines[workflowID] ?? []
            lines[workflowID] = fresh.map { line in
                guard var status = line.fixed,
                      let before = old.first(where: { $0.event == line.event && $0.server == line.server })?.fixed,
                      before.failure?.code == status.failure?.code, let since = before.failure?.since else { return line }
                status.failure?.since = since
                return .init(event: line.event, server: line.server, subscription: line.subscription, fixed: status)
            }
        }
        let changed = Set(lines.keys).union(mcpEvents.lines.keys).filter { mcpEvents.lines[$0] != lines[$0] }
        mcpEvents.lines = lines
        let subscribed = Set(mcpEvents.subscriptions.values.map(\.pool))
        await mcpEvents.clients.keep(only: subscribed)
        // A hosted server no subscription names is no longer used by events (#488).
        for (key, user) in mcpEvents.hostedUsers where !subscribed.contains(key) {
            mcpEvents.hostedUsers[key] = nil
            await hostedServers.release(user)
        }
        // Records no workflow has named for a day go (a changed filter, a deleted workflow).
        var records = mcpRecords()
        var expired = false
        for (id, record) in records.subscriptions {
            if let since = record.missedSince, at.timeIntervalSince(since) > MCPSubscriptionRecord.missedFor {
                records.subscriptions[id]?.missedSince = nil
                expired = true
            }
        }
        if records.prune(keeping: Set(mcpEvents.subscriptions.keys), now: at) || expired {
            mcpEvents.records = records
            saveMCPRecords()
        } else {
            mcpEvents.records = records
        }
        for id in changed { announceMCPWorkflow(id) }
    }

    /// Start what is new, end what is gone, and start again a stopped one whose
    /// fingerprint moved.
    private func applyMCPSubscriptions(_ wanted: [String: MCPSubscription]) {
        for (id, _) in mcpEvents.subscriptions where wanted[id] == nil {
            let gone = mcpEvents.subscriptions.removeValue(forKey: id)
            mcpEvents.tasks.removeValue(forKey: id)?.cancel()
            mcpEvents.live[id] = nil
            if let gone { DaemonLog.shared.write("mcp events: \(gone.server) \(gone.event) unsubscribed (key \(gone.key))") }
        }
        for (id, subscription) in wanted.sorted(by: { $0.key < $1.key }) {
            let before = mcpEvents.subscriptions[id]
            mcpEvents.subscriptions[id] = subscription
            let live = mcpEvents.live[id]
            let restart = before == nil
                || (live?.state == .stopped && live?.stoppedFor != subscription.fingerprint)
                || before?.pool != subscription.pool
            guard restart else { continue }
            mcpEvents.tasks.removeValue(forKey: id)?.cancel()
            mcpEvents.live[id] = .init(state: .pending)
            DaemonLog.shared.write("mcp events: \(subscription.server) \(subscription.event) subscribed for "
                                   + "\(subscription.workflows.joined(separator: ", ")) (key \(subscription.key))")
            mcpEvents.tasks[id] = Task { [weak self] in await self?.runMCPSubscription(id) }
        }
    }

    /// `name` as a session in `project` is given it, http or stdio, signed in.
    private func mcpEventServer(_ name: String, project: URL) async -> Result<ViewServer, ViewServerProblem> {
        switch mcpServer(name, project: project, allowing: [.http, .stdio]) {
        case .failure(let problem): return .failure(problem)
        case .success(var server):
            // A hosted server's events come from its one copy, over the app's endpoint (#488).
            if server.hosted {
                let user = mcpEvents.hostedUsers[server.poolKey] ?? "events-" + UUID().uuidString
                mcpEvents.hostedUsers[server.poolKey] = user
                do {
                    if let routed = try await hostedRoute(server, user: user) { server.filled = routed }
                } catch HostedMCPServers.Refusal.tooMany {
                    mcpEvents.hostedUsers[server.poolKey] = nil
                    return .failure(.unreachable("\(HostedMCPServers.limit) hosted servers are in use on this host."))
                } catch {
                    mcpEvents.hostedUsers[server.poolKey] = nil
                    return .failure(.unreachable("The app's endpoint could not start."))
                }
                return .success(server)
            }
            if case .http(let url, var headers) = server.filled.transport, !MCPSignIns.bringsOwnAuthorization(headers) {
                switch await mcpSignIns.bearer(server: url, name: name) {
                case .none: break
                case .token(let token):
                    headers["Authorization"] = "Bearer \(token)"
                    server.filled = MCPServer(name: server.filled.name, transport: .http(url: url, headers: headers))
                case .needsSignIn: return .failure(.signIn)
                }
            }
            return .success(server)
        }
    }

    /// The server's events, listed again when the last listing is 10 minutes old, or the
    /// server said they changed. A failed listing keeps the events from before.
    private func mcpEventListing(_ server: ViewServer) async -> MCPEventsState.Listing {
        let at = now()
        if let kept = mcpEvents.listings[server.poolKey], !kept.stale,
           at.timeIntervalSince(kept.at) < (kept.failure == nil ? Self.mcpRelistAfter : 50) {
            return kept
        }
        let before = mcpEvents.listings[server.poolKey]
        let clients = mcpEvents.clients
        let listing: MCPEventsState.Listing
        do {
            if try await clients.capability(server.poolKey, server: server.filled, cwd: server.cwd) == nil {
                listing = .init(events: nil, at: at)
            } else {
                let events = try await clients.with(server.poolKey, server: server.filled, cwd: server.cwd) {
                    try await $0.listEvents()
                }
                listing = .init(events: events, at: at)
                if before?.events?.map(\.name) != events.map(\.name) {
                    DaemonLog.shared.write("mcp events: \(server.name) connected (events: \(events.count))")
                }
                if !mcpEvents.loggedBadNames.contains(server.poolKey) {
                    mcpEvents.loggedBadNames.insert(server.poolKey)
                    for bad in events.map(\.name) where !EventCatalogue.isServerEventName(bad) {
                        DaemonLog.shared.write("mcp events: \(server.name) names an event \(bad), which only the app "
                                               + "can raise or which is not noun.verbed: refused (badEventName)")
                    }
                }
            }
        } catch MCPEventClients.Refusal.tooMany {
            listing = .init(events: before?.events, at: at,
                            failure: .transport(MCPEventClients.tooMany))
        } catch let failure as MCPClient.Failure {
            await clients.drop(server.poolKey)
            listing = .init(events: before?.events, at: at, failure: MCPEventsError(failure))
        } catch {
            await clients.drop(server.poolKey)
            listing = .init(events: before?.events, at: at, failure: .transport("It could not be reached."))
        }
        mcpEvents.listings[server.poolKey] = listing
        return listing
    }

    // MARK: Polling

    /// One subscription's loop: deliver what was half delivered, keep the pace across a
    /// restart, then poll until it is cancelled or stops.
    private func runMCPSubscription(_ id: String) async {
        guard let first = mcpEvents.subscriptions[id] else { return }
        await recoverMCPDelivering(id, first)
        if let next = mcpRecords().subscriptions[id]?.nextPollAt, next > now() {
            let wait = Duration.seconds(min(next.timeIntervalSince(now()), 300))
            do { try await mcpEvents.sleep(wait) } catch { return }
        }
        var failures = 0
        while !Task.isCancelled, mcpEvents.started {
            guard let subscription = mcpEvents.subscriptions[id] else { return }
            var wait = Self.mcpPollDefault
            do {
                var pages = 0
                var hint: Int?
                repeat {
                    let cursor = mcpRecords().subscriptions[id]?.cursor
                    let result = try await mcpPoll(subscription, cursor: cursor)
                    guard !Task.isCancelled, mcpEvents.subscriptions[id] != nil else { return }
                    deliverMCPEvents(result, for: subscription, usedCursor: cursor)
                    hint = result.nextPollMs
                    pages += 1
                    if !result.hasMore { break }
                } while pages < Self.mcpPageLimit
                failures = 0
                wait = Self.mcpPace(hint)
                setMCPLive(id, .init(state: .active))
            } catch is CancellationError {
                return
            } catch let error as MCPEventsError {
                switch error {
                case .transport, .timedOut, .needsSignIn:
                    failures += 1
                    wait = Self.mcpBackoff(failures)
                    await mcpEvents.clients.drop(subscription.pool)
                    retryMCP(id, subscription, error, wait: wait)
                case .resourceExhausted(let after):
                    failures += 1
                    wait = max(Self.mcpBackoff(failures), .milliseconds(after ?? 0))
                    retryMCP(id, subscription, error, wait: wait)
                case .unsupported(let reason, _) where reason == "schema_changed":
                    // The arguments are checked again against the new list.
                    mcpEvents.listings[subscription.pool]?.stale = true
                    wait = Self.mcpPollFloor
                    scheduleMCPEventsReconcile()
                case .notFound:
                    mcpEvents.listings[subscription.pool]?.stale = true
                    stopMCP(id, subscription, .eventNotOffered,
                            "\(subscription.server) no longer offers \(subscription.event).")
                    scheduleMCPEventsReconcile()
                    return
                case .forbidden(let message):
                    stopMCP(id, subscription, .refused, "\(subscription.server) refused \(subscription.event)"
                            + Self.mcpTheirWords(message))
                    return
                case .invalidParams(let message):
                    stopMCP(id, subscription, .badArguments, "\(subscription.server) refused the settings under "
                            + "\(subscription.event)" + Self.mcpTheirWords(message))
                    return
                case .unsupported(_, let message), .serverError(_, let message):
                    stopMCP(id, subscription, .serverError, "\(subscription.server) answered with an error"
                            + Self.mcpTheirWords(message))
                    return
                }
            } catch {
                failures += 1
                wait = Self.mcpBackoff(failures)
                retryMCP(id, subscription, .transport(MCPEventClients.tooMany), wait: wait)
            }
            var records = mcpRecords()
            if records.subscriptions[id] != nil {
                records.subscriptions[id]?.nextPollAt = now().addingTimeInterval(wait.timeInterval)
                mcpEvents.records = records
                saveMCPRecords()
            }
            do { try await mcpEvents.sleep(wait) } catch { return }
        }
    }

    private func mcpPoll(_ subscription: MCPSubscription, cursor: String?) async throws -> EventsPollResult {
        let request = EventsPollRequest(name: subscription.event, arguments: subscription.arguments, cursor: cursor)
        do {
            return try await mcpEvents.clients.with(subscription.pool, server: subscription.filled,
                                                    cwd: subscription.cwd) { try await $0.pollEvents(request) }
        } catch let failure as MCPClient.Failure {
            throw MCPEventsError(failure)
        } catch MCPEventClients.Refusal.tooMany {
            throw MCPEventsError.transport(MCPEventClients.tooMany)
        }
    }

    /// `nextPollMs` held between 10 s and 5 min; 30 s when the server says nothing.
    static func mcpPace(_ hint: Int?) -> Duration {
        guard let hint else { return mcpPollDefault }
        return min(max(.milliseconds(hint), mcpPollFloor), mcpPollCeiling)
    }

    /// 10 s, 20 s, 40 s and so on, up to 5 min.
    static func mcpBackoff(_ failures: Int) -> Duration {
        let seconds = 10 * (1 << min(max(failures - 1, 0), 5))
        return min(.seconds(seconds), mcpPollCeiling)
    }

    private static func mcpTheirWords(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "." : ": \(trimmed.prefix(200))"
    }

    static func mcpWords(_ error: MCPEventsError, server: String) -> String {
        switch error {
        case .transport(let why) where why == MCPEventClients.tooMany: return why
        case .transport(let why): return "Can't reach \(server): \(why)"
        case .timedOut: return "Can't reach \(server): it did not answer in 15 s."
        case .needsSignIn: return "\(server) wants a sign-in first."
        case .resourceExhausted: return "\(server) asked to be asked less often."
        default: return "\(server) answered with an error."
        }
    }

    private func retryMCP(_ id: String, _ subscription: MCPSubscription, _ error: MCPEventsError, wait: Duration) {
        let code: MCPTriggerFailure.Code = switch error {
        case .needsSignIn: .needsSignIn
        case .resourceExhausted: .serverError
        default: .unreachable
        }
        let since = mcpEvents.live[id]?.failure?.code == code ? mcpEvents.live[id]?.failure?.since ?? now() : now()
        setMCPLive(id, .init(state: .retrying,
                             failure: MCPTriggerFailure(code: code, message: Self.mcpWords(error, server: subscription.server),
                                                        since: since),
                             retryAt: now().addingTimeInterval(wait.timeInterval)))
        DaemonLog.shared.write("mcp events: \(subscription.server) \(subscription.event) retrying in "
                               + "\(Int(wait.timeInterval))s (\(error.logWord))")
    }

    private func stopMCP(_ id: String, _ subscription: MCPSubscription, _ code: MCPTriggerFailure.Code, _ message: String) {
        setMCPLive(id, .init(state: .stopped, failure: MCPTriggerFailure(code: code, message: message, since: now()),
                             stoppedFor: subscription.fingerprint))
        DaemonLog.shared.write("mcp events: \(subscription.server) \(subscription.event) stopped (\(code.rawValue))")
    }

    /// A subscription's state, kept in its record too, and told to the windows when it
    /// changed in a way a line shows.
    private func setMCPLive(_ id: String, _ live: MCPEventsState.Live) {
        let before = mcpEvents.live[id]
        mcpEvents.live[id] = live
        var records = mcpRecords()
        if records.subscriptions[id] != nil, records.subscriptions[id]?.failure != live.failure {
            records.subscriptions[id]?.failure = live.failure
            mcpEvents.records = records
            saveMCPRecords()
        }
        guard before?.state != live.state || before?.failure?.code != live.failure?.code
                || before?.retryAt != live.retryAt else { return }
        announceMCPSubscription(id)
    }

    // MARK: Delivering, exactly once (research R4, R5)

    /// What a poll brought. A first poll (no cursor) starts from now: its events are noted
    /// as seen, never raised. Otherwise the ids go into `delivering` and are written down
    /// before any is raised; each moves to `seen` once the event log has it.
    private func deliverMCPEvents(_ result: EventsPollResult, for subscription: MCPSubscription, usedCursor: String?) {
        let id = subscription.id
        let at = now()
        var records = mcpRecords()
        var record = records.subscriptions[id] ?? MCPSubscriptionRecord(lastNamedAt: at)
        record.lastPolledAt = at
        if result.truncated {
            if record.missedSince == nil { record.missedSince = at }
            mcpEvents.missedToTell.insert(id)
            DaemonLog.shared.write("mcp events: \(subscription.server) \(subscription.event) truncated "
                                   + "(events may have been missed)")
        }
        var fresh: [PolledEvent] = []
        var ids: Set<String> = []
        for event in result.events {
            guard let eventID = event.eventId, !eventID.isEmpty else {
                DaemonLog.shared.write("mcp events: \(subscription.server) \(subscription.event) sent an event with no id: dropped")
                continue
            }
            guard event.name == subscription.event else {
                DaemonLog.shared.write("mcp events: \(subscription.server) \(subscription.event) sent an event of "
                                       + "another name: dropped")
                continue
            }
            guard !record.hasSeen(eventID), ids.insert(eventID).inserted else { continue }
            fresh.append(event)
        }
        let wasMissed = record.missedSince
        if usedCursor == nil {
            // A new subscription starts from now, whatever the server answered.
            record.see(fresh.compactMap(\.eventId), at: at)
            record.cursor = result.cursor ?? record.cursor
            records.subscriptions[id] = record
            mcpEvents.records = records
            saveMCPRecords()
            if wasMissed != nil || !fresh.isEmpty { announceMCPSubscription(id) }
            return
        }
        record.previousCursor = usedCursor
        record.cursor = result.cursor ?? record.cursor
        record.delivering = fresh.compactMap(\.eventId)
        records.subscriptions[id] = record
        mcpEvents.records = records
        saveMCPRecords()
        guard !fresh.isEmpty else {
            if result.truncated || at.timeIntervalSince(mcpEvents.announced[id] ?? .distantPast) >= 60 {
                announceMCPSubscription(id)
            }
            return
        }
        for event in fresh {
            raiseMCPEvent(event, for: subscription)
            guard let eventID = event.eventId else { continue }
            record.see([eventID], at: at)
            record.delivering.removeAll { $0 == eventID }
            record.lastEventAt = at
        }
        records = mcpRecords()
        records.subscriptions[id] = record
        mcpEvents.records = records
        saveMCPRecords()
        announceMCPSubscription(id)
    }

    /// One event onto the log, which fires the workflows whose triggers it matches.
    @discardableResult
    private func raiseMCPEvent(_ polled: PolledEvent, for subscription: MCPSubscription) -> Event {
        var payload = polled.data.map { MCPEventTrigger.canonicalJSON($0) } ?? "null"
        var details: [String: String] = [
            "server": subscription.server, "event": subscription.event, "subscription": subscription.key,
            "mcp_event_id": polled.eventId ?? "",
            "time": polled.timestamp ?? ISO8601DateFormatter().string(from: now()),
        ]
        if payload.utf8.count > Self.mcpPayloadLimit {
            payload = String(decoding: Data(payload.utf8.prefix(Self.mcpPayloadLimit)), as: UTF8.self)
            details["payload_cut"] = "true"
        }
        details["payload"] = payload
        if mcpEvents.missedToTell.remove(subscription.id) != nil,
           let since = mcpRecords().subscriptions[subscription.id]?.missedSince {
            details["missed_since"] = ISO8601DateFormatter().string(from: since)
        }
        let event = raise(EventDraft(name: subscription.event, at: now(), scope: .project(folder: subscription.project),
                                     sentence: "\(subscription.server) reported \(subscription.event)", details: details))
        DaemonLog.shared.write("mcp events: \(subscription.server) \(subscription.event) evt \(polled.eventId ?? "") "
                               + "raised (position \(event.position), workflows: \(subscription.workflows.joined(separator: ", ")))")
        return event
    }

    /// Ids a daemon stopped with in `delivering`: the event log is the commit point.
    /// One found there was raised, and is only noted as seen. One not found is fetched
    /// again from the cursor before, and raised once.
    private func recoverMCPDelivering(_ id: String, _ subscription: MCPSubscription) async {
        var records = mcpRecords()
        guard var record = records.subscriptions[id], !record.delivering.isEmpty else { return }
        loadEventsIfNeeded()
        let at = now()
        var missing: [String] = []
        for eventID in record.delivering {
            let logged = eventLog.events.contains {
                $0.details["mcp_event_id"] == eventID && $0.details["subscription"] == subscription.key
            }
            if logged { record.see([eventID], at: at) } else { missing.append(eventID) }
        }
        record.delivering = missing
        records.subscriptions[id] = record
        mcpEvents.records = records
        saveMCPRecords()
        guard !missing.isEmpty, let previous = record.previousCursor else { return }
        guard let result = try? await mcpPoll(subscription, cursor: previous) else {
            DaemonLog.shared.write("mcp events: \(subscription.server) \(subscription.event) could not fetch "
                                   + "\(missing.count) event(s) again; kept to try at the next start")
            return
        }
        records = mcpRecords()
        guard var current = records.subscriptions[id] else { return }
        for event in result.events {
            guard let eventID = event.eventId, missing.contains(eventID), event.name == subscription.event,
                  !current.hasSeen(eventID) else { continue }
            raiseMCPEvent(event, for: subscription)
            current.see([eventID], at: at)
            current.lastEventAt = at
        }
        current.delivering = []
        records.subscriptions[id] = current
        mcpEvents.records = records
        saveMCPRecords()
    }

    // MARK: The record

    func mcpRecords() -> MCPEventRecords {
        if let held = mcpEvents.records { return held }
        let loaded = mcpEventStore.load()
        mcpEvents.records = loaded
        return loaded
    }

    private func saveMCPRecords() {
        guard let records = mcpEvents.records else { return }
        keepQuietly("where each server's events have got to") { try mcpEventStore.save(records) }
    }

    // MARK: Clear

    /// The page's Clear on a line's missed events (#383, T036): granted as any change to
    /// a workflow is.
    func clearMCPMissed(_ request: DaemonAPI.WorkflowMCPClearMissedRequest) throws -> WorkflowSummary {
        guard let workflow = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(request.workflowID) in this project.")
        }
        let ids = (mcpEvents.lines[workflow.id] ?? [])
            .filter { $0.event == request.name && $0.server == request.server }.compactMap(\.subscription)
        var records = mcpRecords()
        for id in ids where records.subscriptions[id]?.missedSince != nil {
            records.subscriptions[id]?.missedSince = nil
            mcpEvents.missedToTell.remove(id)
        }
        mcpEvents.records = records
        saveMCPRecords()
        DaemonLog.shared.write("mcp events: \(request.server ?? "no server") \(request.name) missed events cleared, by the person")
        for id in ids { announceMCPSubscription(id) }
        return summary(for: workflow)
    }

    // MARK: Telling the windows

    private func announceMCPSubscription(_ id: String) {
        guard let subscription = mcpEvents.subscriptions[id] else { return }
        mcpEvents.announced[id] = now()
        for workflowID in subscription.workflows {
            if let workflow = workflows[subscription.project]?[workflowID] { announceWorkflow(workflow) }
        }
    }

    private func announceMCPWorkflow(_ workflowID: String) {
        for folder in workflows.keys {
            if let workflow = workflows[folder]?.values.first(where: { $0.id == workflowID }) {
                announceWorkflow(workflow)
                return
            }
        }
    }

    /// Each server's line under each of `workflow`'s MCP triggers, or nil when it has none
    /// this host asks for.
    func mcpTriggerStatuses(for workflow: Workflow) -> [MCPTriggerStatus]? {
        guard let lines = mcpEvents.lines[workflow.id], !lines.isEmpty else { return nil }
        let records = mcpRecords()
        return lines.map { line in
            if let fixed = line.fixed { return fixed }
            guard let id = line.subscription else {
                return MCPTriggerStatus(name: line.event, server: line.server, state: .pending)
            }
            let record = records.subscriptions[id]
            let live = mcpEvents.live[id] ?? .init(state: .pending)
            return MCPTriggerStatus(name: line.event, server: line.server, state: live.state,
                                    lastPolledAt: record?.lastPolledAt, lastEventAt: record?.lastEventAt,
                                    missedSince: record?.missedSince, failure: live.failure,
                                    retryAt: live.state == .retrying ? live.retryAt : nil)
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

import AgentsKitCore
import Foundation

/// Workspace providers on the control plane (#691, plan.md): their records, their last lists,
/// the links from hosts to workspaces, and every start and stop, one at a time per workspace.
///
/// What it learns it lays over each linked host's state in the router (`setWorkspace`), so
/// `hosts/list` and `control/hostChanged` carry it to every client. Runs only on a control
/// plane with one copy (research R4).
public actor WorkspaceProviders: WorkspaceHandling {
    public struct Timing: Sendable {
        /// How often every provider is listed (FR-004).
        public var listEvery: Duration
        /// How long a started workspace's agentsd has to connect before it is started over ssh (FR-013).
        public var sshAfter: Duration
        /// How long a start has, in all, before it is given up (US1 AS3).
        public var giveUp: Duration
        /// How often a start looks for the host's connection.
        public var lookEvery: Duration
        public var calls: ProviderConnection.Timing
        /// What one minute of a stop when idle lasts: a minute, but shorter in tests.
        public var idleMinute: Duration
        /// How often stopped workspaces are looked at for a wake-up call that is due (#1004).
        public var wakeLookEvery: Duration

        public static let standard = Timing(listEvery: .seconds(300), sshAfter: .seconds(120), giveUp: .seconds(600),
                                            lookEvery: .seconds(1), calls: .standard)

        public init(listEvery: Duration, sshAfter: Duration, giveUp: Duration, lookEvery: Duration,
                    calls: ProviderConnection.Timing, idleMinute: Duration = .seconds(60),
                    wakeLookEvery: Duration = .seconds(15)) {
            self.listEvery = listEvery
            self.sshAfter = sshAfter
            self.giveUp = giveUp
            self.lookEvery = lookEvery
            self.calls = calls
            self.idleMinute = idleMinute
            self.wakeLookEvery = wakeLookEvery
        }
    }

    /// What the executable does for it: what needs ssh, processes or the tunnels.
    public struct Hooks: Sendable {
        /// Starts a host's agentsd over ssh, as an install leaves it, without installing.
        public var sshStart: @Sendable (_ host: HostRecord, _ destination: String) async throws -> Void
        /// Opens the host's reverse tunnel now, if it has one.
        public var openTunnel: @Sendable (HostID) async -> Void
        /// The ssh destination the host was installed over, when its tunnel keeps it (#965).
        public var installedOver: @Sendable (HostID) async -> String?
        /// A connection to a provider, as its record says.
        public var connect: @Sendable (ProviderRecord, [String: String]) throws -> any WorkspaceProvider
        /// The one line that installs a host with a new host code (`install.sh`), for a new
        /// workspace's first boot (US5, FR-041).
        public var hostCommand: @Sendable () async throws -> String

        public init(sshStart: @escaping @Sendable (HostRecord, String) async throws -> Void = { _, _ in
                        throw ProviderFailure("This control plane can’t start agentsd over ssh.")
                    },
                    openTunnel: @escaping @Sendable (HostID) async -> Void = { _ in },
                    installedOver: @escaping @Sendable (HostID) async -> String? = { _ in nil },
                    hostCommand: @escaping @Sendable () async throws -> String = {
                        throw ProviderFailure("This control plane can’t give out host codes.")
                    },
                    connect: @escaping @Sendable (ProviderRecord, [String: String]) throws -> any WorkspaceProvider) {
            self.sshStart = sshStart
            self.openTunnel = openTunnel
            self.installedOver = installedOver
            self.hostCommand = hostCommand
            self.connect = connect
        }
    }

    public static let prefix = "v1/providers/"
    static func key(_ id: ProviderID) -> String { prefix + id.rawValue + ".json" }

    /// A provider's last list.
    struct Listed {
        var workspaces: [DaemonAPI.WorkspaceInfo] = []
        var listedAt: Date?
        var current = true
        var problem: String?
    }

    /// A start or stop under way, for one host.
    struct Activity {
        enum Kind { case start, stop }
        var kind: Kind
        var phase: String
        var since: Date
    }

    private let store: any ControlStore
    private let records: ControlRecords
    private let methods: ControlMethods
    private let router: ControlRouter
    private let secrets: ProviderSecrets
    private let timing: Timing
    private let hooks: Hooks
    private let log: @Sendable (String) -> Void

    private var providers: [ProviderID: (record: ProviderRecord, etag: String)] = [:]
    private var connections: [ProviderID: any WorkspaceProvider] = [:]
    private var listed: [ProviderID: Listed] = [:]
    private var activities: [HostID: Activity] = [:]
    /// Why each host's last start or stop failed, until the next one.
    private var problems: [HostID: String] = [:]
    private var ticker: Task<Void, Never>?
    /// Looks for wake-up calls that are due (#1004).
    private var waker: Task<Void, Never>?
    /// Prompts and agent starts kept for stopped hosts (US3).
    public private(set) var kept: KeptRequests?
    /// Write It for Me's drafts (#858).
    public private(set) var drafts: ProviderDrafts?
    /// What each host last said about whether it is idle (US4). A host that never says is
    /// never stopped as idle.
    private var statuses: [HostID: DaemonAPI.HostStatus] = [:]
    /// Each linked host's stop when idle, counting down while it stays idle.
    private var idleTimers: [HostID: Task<Void, Never>] = [:]
    /// Stops under way because a host was idle, by how many minutes.
    private var idleStopping: [HostID: Int] = [:]
    /// "Stopped by Agents after 30 minutes idle", until it is started again.
    private var stoppedBy: [HostID: String] = [:]

    public init(store: any ControlStore, records: ControlRecords, methods: ControlMethods, router: ControlRouter,
                secrets: ProviderSecrets, timing: Timing = .standard, hooks: Hooks,
                log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.records = records
        self.methods = methods
        self.router = router
        self.secrets = secrets
        self.timing = timing
        self.hooks = hooks
        self.log = log
    }

    /// Keeps prompts and starts for this control plane's stopped hosts (US3).
    public func keep(with kept: KeptRequests) { self.kept = kept }

    /// Lets an agent write a provider's map or commands at Add Provider (#858).
    public func draft(with drafts: ProviderDrafts) { self.drafts = drafts }

    /// The host linked to a provider's workspace, by name, when agents are working there:
    /// a writer can't ask to stop it (#858, FR-020).
    public func busyHost(_ provider: ProviderID?, _ workspace: String) async -> String? {
        guard let provider else { return nil }
        for record in await records.hosts where record.workspace?.provider == provider && record.workspace?.workspace == workspace {
            if let running = statuses[record.id]?.running, !running.isEmpty { return record.name }
        }
        return nil
    }

    public func draftCall(from host: HostID, call: DaemonAPI.HostProviderDraftCall) async throws -> JSONValue {
        guard let drafts else { throw JSONRPCError(code: DaemonAPI.Failure.notPermitted, message: ProviderDrafts.notYoursWords) }
        return try await drafts.call(from: host, call)
    }

    /// Reads the providers, lists each, and lists again every `listEvery` (FR-004).
    public func start() async {
        await load()
        await kept?.load()
        await refresh(nil)
        let every = timing.listEvery
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                await self?.refresh(nil)
            }
        }
        let look = timing.wakeLookEvery
        waker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: look)
                await self?.wakeUps(now: Date())
            }
        }
    }

    public func stop() async {
        ticker?.cancel()
        waker?.cancel()
        for connection in connections.values { await connection.end() }
        connections = [:]
    }

    private func load() async {
        guard let keys = try? await store.list(prefix: Self.prefix) else { return }
        for key in keys {
            guard let object = try? await store.get(key.key),
                  let record = try? ControlRecords.decoder.decode(ProviderRecord.self, from: object.data) else { continue }
            if record.forgotten == true { continue }
            providers[record.id] = (record, object.etag)
        }
    }

    // MARK: WorkspaceHandling

    public func answer(method: String, params: JSONValue?, from caller: ControlRouter.Caller) async throws -> JSONValue {
        try await answer(method: method, params: params, from: caller, who: "client \(caller.client.uuidString.prefix(8).lowercased())")
    }

    public func agentCall(from host: HostID, agent: String, method: String, params: JSONValue) async throws -> JSONValue {
        let hostName = await records.host(host)?.name ?? host.rawValue
        // No client: the host's own channel. Its removals and events are said as by the host.
        let caller = ControlRouter.Caller(session: UUID(), client: UUID(), kind: .unknown)
        if method == DaemonAPI.Method.workspacesForAgent { return try JSONValue.encoding(await forAgent()) }
        // An agent names hosts and providers as it saw them listed: by name, or by id.
        guard var given = params.objectValue else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Those parameters aren’t an object.")
        }
        if let named = given["host"]?.stringValue, await records.host(HostID(rawValue: named)) == nil {
            guard let found = await records.hosts.first(where: { $0.name.caseInsensitiveCompare(named) == .orderedSame }) else {
                throw JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No host is called \(named).")
            }
            given["host"] = .string(found.id.rawValue)
        }
        if let named = given["id"]?.stringValue, providers[ProviderID(rawValue: named)] == nil,
           [DaemonAPI.Method.providersCreate, DaemonAPI.Method.providersOptions].contains(method) {
            guard let found = providers.values.first(where: { $0.record.name.caseInsensitiveCompare(named) == .orderedSame }) else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "No provider is called \(named).")
            }
            given["id"] = .string(found.record.id.rawValue)
        }
        return try await answer(method: method, params: .object(given), from: caller, who: "agent \(agent) on \(hostName)")
    }

    /// What an agent is shown (US6 AS1): every provider's workspaces and their hosts, and what
    /// a new one could be, never a secret or its name.
    private func forAgent() async -> DaemonAPI.AgentWorkspaces {
        let hosts = await records.hosts
        var out: [DaemonAPI.AgentWorkspaces.Provider] = []
        for summary in await summaries() {
            var options: JSONValue?
            if summary.capabilities.contains("create") {
                options = try? await providerCall(summary.id) { try await $0.options() }
            }
            var workspaces: [DaemonAPI.AgentWorkspaces.Workspace] = []
            for workspace in summary.workspaces {
                let host = workspace.host.flatMap { id in hosts.first { $0.id == id } }
                var hostState: String?
                if let host {
                    let described = await router.described(host.id, await router.state(of: host.id) ?? .offline(since: Date()))
                    hostState = described["state"]?.stringValue
                }
                workspaces.append(.init(id: workspace.id, name: workspace.name, state: workspace.state,
                                        host: host?.name, hostState: hostState, cost: workspace.cost))
            }
            out.append(.init(id: summary.id, name: summary.name, canMake: summary.capabilities.contains("create"),
                             canDelete: summary.capabilities.contains("delete"), options: options, workspaces: workspaces))
        }
        return DaemonAPI.AgentWorkspaces(providers: out)
    }

    private func answer(method: String, params: JSONValue?, from caller: ControlRouter.Caller, who: String) async throws -> JSONValue {
        switch method {
        case DaemonAPI.Method.providersList:
            // As last listed: a page that opens asks for `providers/refresh` too (FR-004).
            return ["providers": try JSONValue.encoding(await summaries())]
        case DaemonAPI.Method.providersRefresh:
            let id = (try? params?.decode(DaemonAPI.ProviderRequest.self))?.id
            Task { await self.refresh(id) }
            return [:]
        case DaemonAPI.Method.providersAdd, DaemonAPI.Method.providersUpdate:
            let request = try Self.require(params, as: DaemonAPI.ProviderAdd.self)
            return try JSONValue.encoding(try await save(request, updating: method == DaemonAPI.Method.providersUpdate))
        case DaemonAPI.Method.providersRemove:
            guard let id = try Self.require(params, as: DaemonAPI.ProviderRequest.self).id else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Which provider?")
            }
            try await remove(id)
            return [:]
        case DaemonAPI.Method.hostsLink:
            return try JSONValue.encoding(try await link(try Self.require(params, as: DaemonAPI.HostLink.self)))
        case DaemonAPI.Method.hostsUnlink:
            let host = try Self.require(params, as: DaemonAPI.HostRequest.self).host
            return try JSONValue.encoding(try await changeLink(host) { $0.workspace = nil })
        case DaemonAPI.Method.hostsSetWorkspaceOptions:
            let options = try Self.require(params, as: DaemonAPI.HostWorkspaceOptions.self)
            return try JSONValue.encoding(try await changeLink(options.host, { record in
                guard var link = record.workspace else { return }
                if let on = options.startWhenUsed { link.startWhenUsed = on }
                if let minutes = options.stopWhenIdleMinutes { link.stopWhenIdleMinutes = minutes > 0 ? minutes : nil }
                if let on = options.startForSchedules { link.startForSchedules = on }
                record.workspace = link
            }, then: { await self.countIdle(options.host) }))
        case DaemonAPI.Method.hostsStart:
            let host = try Self.require(params, as: DaemonAPI.HostRequest.self).host
            return try JSONValue.encoding(try await begin(.start, host, by: who))
        case DaemonAPI.Method.hostsStop:
            let request = try Self.require(params, as: DaemonAPI.HostStop.self)
            // Asked first while agents are working there (US4 AS4).
            if request.confirmRunning != true, let running = statuses[request.host]?.running, !running.isEmpty,
               await router.state(of: request.host)?.isOnline == true {
                let name = await records.host(request.host)?.name ?? request.host.rawValue
                throw JSONRPCError(code: DaemonAPI.Failure.agentsWorking,
                                   message: "Stop \(name)? \(Self.list(running)) \(running.count == 1 ? "is" : "are") working there.",
                                   data: ["running": .array(running.map { .string($0) })])
            }
            return try JSONValue.encoding(try await begin(.stop, request.host, by: who))
        case DaemonAPI.Method.providersOptions:
            guard let id = try Self.require(params, as: DaemonAPI.ProviderRequest.self).id else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Which provider?")
            }
            return try JSONValue.encoding(DaemonAPI.ProviderOptions(schema: try await providerCall(id) { try await $0.options() }))
        case DaemonAPI.Method.providersCreate:
            return try JSONValue.encoding(try await create(try Self.require(params, as: DaemonAPI.ProviderCreate.self), by: who,
                                                           caller: caller))
        case DaemonAPI.Method.hostsDeleteWorkspace:
            try await deleteWorkspace(try Self.require(params, as: DaemonAPI.HostRequest.self).host, by: who, caller: caller)
            return [:]
        case DaemonAPI.Method.hostsKeep:
            let request = try Self.require(params, as: DaemonAPI.KeepRequest.self)
            guard let kept, let answer = await kept.keep(host: request.host, method: request.method,
                                                         params: request.params, from: caller) else {
                throw JSONRPCError(code: DaemonAPI.Failure.hostOffline,
                                   message: "\(await records.host(request.host)?.name ?? "That host") is offline.")
            }
            throw answer
        case DaemonAPI.Method.providersRuntimes:
            guard let drafts else { return try JSONValue.encoding(DaemonAPI.ProviderRuntimes(runtimes: [], why: "This control plane can’t start a writing agent.")) }
            return try JSONValue.encoding(await drafts.runtimes())
        case DaemonAPI.Method.providersDraftStart:
            guard let drafts else { throw JSONRPCError(code: DaemonAPI.Failure.notSupported, message: "This control plane can’t start a writing agent.") }
            var request = try Self.require(params, as: DaemonAPI.ProviderDraftStart.self)
            var existing: (record: ProviderRecord, secrets: [String: String], problem: String?)?
            if let id = request.provider {
                guard let held = providers[id]?.record else {
                    throw JSONRPCError(code: JSONRPCError.invalidParams, message: "There is no such provider.")
                }
                existing = (held, await secrets.values(id), listed[id]?.problem)
                // Written again from the provider as it is kept: the sheet knows only its name.
                let cli = request.form.cli?.trimmingCharacters(in: .whitespaces) ?? ""
                request.form = DaemonAPI.ProviderAdd(id: id, name: held.name, kind: held.kind, command: held.command,
                                                     args: held.args, url: held.url, headers: held.headers,
                                                     cli: cli.isEmpty ? Self.cli(of: held) : cli)
            }
            return try JSONValue.encoding(try await drafts.start(request, from: caller, existing: existing))
        case DaemonAPI.Method.providersDraftCancel:
            let request = try Self.require(params, as: DaemonAPI.ProviderDraftRequest.self)
            await drafts?.cancel(request.draft, from: caller)
            return [:]
        case DaemonAPI.Method.providersDraftAnswer:
            guard let drafts else { throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That draft has ended.") }
            try await drafts.answer(try Self.require(params, as: DaemonAPI.ProviderDraftAnswer.self), from: caller)
            return [:]
        case DaemonAPI.Method.hostsListKept, DaemonAPI.Method.hostsDropKept, DaemonAPI.Method.hostsRetryKept:
            guard let kept else { return ["kept": []] }
            return try await kept.answer(method: method, params: params)
        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    // MARK: Providers

    public func summaries() async -> [DaemonAPI.ProviderSummary] {
        var linked: [String: HostID] = [:]
        for record in await records.hosts {
            if let link = record.workspace { linked["\(link.provider.rawValue)/\(link.workspace)"] = record.id }
        }
        var out: [DaemonAPI.ProviderSummary] = []
        for (record, _) in providers.values.sorted(by: { $0.record.name < $1.record.name }) {
            let had = await secrets.values(record.id)
            let list = listed[record.id] ?? Listed()
            out.append(DaemonAPI.ProviderSummary(
                id: record.id, name: record.name, kind: record.kind.rawValue,
                secrets: Dictionary(record.secretNames.map { ($0, had[$0] != nil) }) { a, _ in a },
                capabilities: record.capabilities, contract: record.contract, mapped: record.map != nil,
                preset: record.commands?["preset"]?.stringValue,
                workspaces: list.workspaces.map { workspace in
                    var workspace = workspace
                    workspace.host = linked["\(record.id.rawValue)/\(workspace.id)"]
                    return workspace
                },
                listedAt: list.listedAt, current: list.current, problem: list.problem))
        }
        return out
    }

    /// Adds or changes a provider: connected, checked and listed before it is kept (US2 AS1–2).
    private func save(_ request: DaemonAPI.ProviderAdd, updating: Bool) async throws -> DaemonAPI.ProviderSummary {
        let id: ProviderID
        var etag: String?
        if updating {
            guard let given = request.id, let held = providers[given] else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "There is no such provider.")
            }
            id = given
            etag = held.etag
        } else {
            id = ProviderID.make(name: request.name)
        }
        if providers.values.contains(where: { $0.record.id != id && $0.record.name == request.name.trimmingCharacters(in: .whitespaces) }) {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "There is already a provider called \(request.name).")
        }
        let before = updating ? await secrets.values(id) : [:]
        // An update keeps what it leaves out, as it keeps the secrets (#858 US4: Edit… sends
        // only the map or commands it wrote again).
        var request = request
        if updating, let held = providers[id]?.record, request.kind == held.kind {
            request.command = request.command ?? held.command
            request.args = request.args ?? held.args
            request.url = request.url ?? held.url
            request.headers = request.headers ?? held.headers
            if request.kind == .commands { request.commands = request.commands ?? held.commands } else { request.map = request.map ?? held.map }
        }
        let given = (request.secrets ?? [:]).filter { !$0.value.isEmpty }
        let values = before.merging(given) { $1 }
        var record = ProviderRecord(id: id, name: request.name.trimmingCharacters(in: .whitespaces), kind: request.kind,
                                    command: request.command, args: request.args, url: request.url, headers: request.headers,
                                    commands: request.commands, secretNames: values.keys.sorted(), map: request.map)
        if let problem = record.problem {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: problem)
        }
        let connection: any WorkspaceProvider
        let checked: ProviderConnection.Checked
        do {
            connection = try hooks.connect(record, values)
            checked = try await connection.check()
        } catch {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: (error as? ProviderFailure)?.description ?? "\(error)")
        }
        record.capabilities = checked.capabilities
        record.contract = checked.contract
        record.writtenBy = await writtenBy(request, before: updating ? providers[id]?.record : nil)
        record.rev = (updating ? providers[id]?.record.rev ?? 0 : 0) + 1
        do {
            let newTag = try await store.put(Self.key(id), try ControlRecords.encoder.encode(record),
                                             when: etag.map { .matching($0) } ?? .absent)
            try await secrets.set(id, values)
            providers[id] = (record, newTag)
        } catch {
            await connection.end()
            throw error
        }
        await connections[id]?.end()
        connections[id] = connection
        listed[id] = Listed(workspaces: checked.workspaces, listedAt: Date())
        log("provider: \(updating ? "changed" : "added") \(id) (\(record.kind.rawValue)\(record.commands?["preset"]?.stringValue.map { ", preset \($0)" } ?? "")\(record.map != nil ? ", mapped" : "")), \(checked.workspaces.count) workspaces")
        await changed()
        return await summaries().first { $0.id == id }!
    }

    /// Who wrote what is kept (#858): an agent, when the request accepts a done draft and its
    /// map or commands are the draft's, compared as JSON; otherwise it stays as it was when
    /// they are unchanged, and goes when the person changed them.
    private func writtenBy(_ request: DaemonAPI.ProviderAdd, before: ProviderRecord?) async -> ProviderRecord.WrittenBy? {
        let given = request.kind == .commands ? request.commands : request.map
        if let draft = request.draft, let result = await drafts?.result(draft), result.json == given {
            return .init(runtimeID: result.runtimeID, at: Date())
        }
        guard let before else { return nil }
        return (before.kind == .commands ? before.commands : before.map) == given ? before.writtenBy : nil
    }

    /// The program a command provider's commands use: the first word of its list, or of its
    /// first workspace's start (#858 US4).
    static func cli(of record: ProviderRecord) -> String? {
        let line = record.commands?["list"]?.stringValue ?? record.commands?["workspaces"]?.arrayValue?.first?["start"]?.stringValue
        return line?.split(separator: " ").first.map(String.init)
    }

    /// A provider goes; its hosts stay, unlinked (US2 AS5).
    private func remove(_ id: ProviderID) async throws {
        guard var held = providers[id] else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "There is no such provider.")
        }
        held.record.forgotten = true
        held.record.rev += 1
        _ = try await store.put(Self.key(id), try ControlRecords.encoder.encode(held.record), when: .matching(held.etag))
        providers[id] = nil
        listed[id] = nil
        await connections.removeValue(forKey: id)?.end()
        try? await secrets.remove(id)
        for var record in await records.hosts where record.workspace?.provider == id {
            record.workspace = nil
            try? await records.save(record)
        }
        log("provider: removed \(id)")
        await changed()
    }

    /// Lists one provider, or every one; a failed list keeps the last, marked not current.
    public func refresh(_ only: ProviderID?) async {
        let ids = only.map { [$0] } ?? Array(providers.keys)
        await withTaskGroup(of: (ProviderID, Result<[DaemonAPI.WorkspaceInfo], ProviderFailure>).self) { group in
            for id in ids {
                guard let connection = try? await connection(id) else { continue }
                group.addTask {
                    do { return (id, .success(try await connection.list())) }
                    catch let failure as ProviderFailure { return (id, .failure(failure)) }
                    catch { return (id, .failure(ProviderFailure("\(error)"))) }
                }
            }
            for await (id, result) in group {
                guard providers[id] != nil else { continue }
                var list = listed[id] ?? Listed()
                switch result {
                case .success(let workspaces):
                    list = Listed(workspaces: workspaces, listedAt: Date())
                case .failure(let failure):
                    list.current = list.listedAt == nil
                    list.problem = failure.description
                }
                listed[id] = list
            }
        }
        await changed()
    }

    private func connection(_ id: ProviderID) async throws -> any WorkspaceProvider {
        if let held = connections[id] { return held }
        guard let record = providers[id]?.record else { throw ProviderFailure("That provider was removed.") }
        do {
            let made = try hooks.connect(record, await secrets.values(id))
            connections[id] = made
            return made
        } catch let failure as ProviderFailure {
            var list = listed[id] ?? Listed()
            list.current = false
            list.problem = failure.description
            listed[id] = list
            throw failure
        }
    }

    // MARK: Links

    private func link(_ request: DaemonAPI.HostLink) async throws -> DaemonAPI.ControlHost {
        guard providers[request.provider] != nil else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "There is no such provider.")
        }
        // One host per workspace: linking moves the link.
        for var other in await records.hosts where other.id != request.host
            && other.workspace?.provider == request.provider && other.workspace?.workspace == request.workspace {
            other.workspace = nil
            try await records.save(other)
        }
        return try await changeLink(request.host) { record in
            let had = record.workspace
            var link = WorkspaceLink(
                provider: request.provider, workspace: request.workspace,
                startWhenUsed: request.startWhenUsed ?? had?.startWhenUsed ?? true,
                stopWhenIdleMinutes: request.stopWhenIdleMinutes.map { $0 > 0 ? $0 : nil }
                    ?? (had == nil ? WorkspaceLink.defaultIdleMinutes : had?.stopWhenIdleMinutes))
            // The host's schedule and the switch are the host's, whatever it is linked to.
            link.startForSchedules = had?.startForSchedules
            link.schedule = had?.schedule
            record.workspace = link
        } then: {
            // Listed again, in the background: the last list can be from before an install
            // woke the workspace (#965).
            Task { await self.refresh(request.provider) }
        }
    }

    private func changeLink(_ host: HostID, _ change: (inout HostRecord) -> Void,
                            then after: () async -> Void = {}) async throws -> DaemonAPI.ControlHost {
        guard var record = await records.host(host) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No host is called \(host.rawValue).")
        }
        change(&record)
        try await records.save(record)
        await after()
        let saved = await records.host(host) ?? record
        log("workspace: \(saved.name) \(saved.workspace.map { "linked to \($0.provider)/\($0.workspace)" } ?? "unlinked")")
        await changed()
        return await methods.hostRow(saved)
    }

    // MARK: Starts and stops

    /// The host's name when a prompt or start for it is to be kept (FR-020): it is linked
    /// with start when used on, isn't online, and its workspace is stopped or starting.
    public func keepable(_ host: HostID) async -> String? {
        guard let record = await records.host(host), let link = record.workspace, link.startWhenUsed ?? true,
              providers[link.provider] != nil, await router.state(of: host)?.isOnline != true else { return nil }
        if activities[host]?.kind == .stop { return nil }
        let shown = overlay(record)?.hostState
        return shown == "stopped" || shown == "starting" ? record.name : nil
    }

    /// Starts a host's workspace for a kept request, or joins the start under way.
    public func startForUse(_ host: HostID, by who: String) async {
        _ = try? await begin(.start, host, by: who)
    }

    private func begin(_ kind: Activity.Kind, _ host: HostID, by who: String) async throws -> DaemonAPI.ControlHost {
        guard let record = await records.host(host) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No host is called \(host.rawValue).")
        }
        guard let link = record.workspace, providers[link.provider] != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.notLinked, message: "\(record.name) isn’t linked to a workspace.")
        }
        // One start or stop at a time per workspace (US1 AS4): a second press of the same
        // joins the first; the other is refused, never dropped without a word.
        if let under = activities[host], under.kind != kind {
            throw JSONRPCError(code: DaemonAPI.Failure.providerFailed,
                               message: under.kind == .start ? "\(record.name) is starting. Stop it once it has started."
                                                             : "\(record.name) is stopping. Start it once it has stopped.")
        }
        if activities[host] == nil {
            activities[host] = Activity(kind: kind, phase: kind == .start ? "provider" : "stopping", since: Date())
            problems[host] = nil
            stoppedBy[host] = nil
            idleTimers.removeValue(forKey: host)?.cancel()
            await changed()
            Task { await self.run(kind, host: host, link: link, by: who) }
        }
        return await methods.hostRow(await records.host(host) ?? record)
    }

    private func run(_ kind: Activity.Kind, host: HostID, link: WorkspaceLink, by who: String) async {
        let began = ContinuousClock.now
        let name = await records.host(host)?.name ?? host.rawValue
        let verb = kind == .start ? "start" : "stop"
        let what = "\(name) (\(link.provider)/\(link.workspace))"
        do {
            let connection = try await connection(link.provider)
            if kind == .start {
                try await connection.start(link.workspace)
            } else {
                try await connection.stop(link.workspace)
            }
        } catch {
            let reason = (error as? ProviderFailure)?.description ?? "\(error)"
            log("workspace: \(verb) \(what) by \(who): failed: \(reason)")
            await finish(host, link, problem: kind == .start ? "Couldn’t start \(name): \(reason)" : "Couldn’t stop \(name): \(reason)")
            return
        }
        await refresh(link.provider)
        guard kind == .start else {
            log("workspace: stop \(what) by \(who): ok in \(Self.seconds(since: began))")
            // Said on its row and strip until it is started again (US4 AS1).
            if let minutes = idleStopping.removeValue(forKey: host) {
                stoppedBy[host] = "Stopped by Agents after \(Self.words(minutes: minutes)) idle"
            }
            statuses[host] = nil
            await finish(host, link, problem: nil)
            return
        }
        // Started: now its agentsd has to connect (US1 AS2).
        await setPhase(host, "connecting")
        await hooks.openTunnel(host)
        var sshTried = false
        while ContinuousClock.now - began < timing.giveUp {
            if await router.state(of: host)?.isOnline == true {
                log("workspace: start \(what) by \(who): ok in \(Self.seconds(since: began))")
                // How long it takes, so a wake-up call starts it early enough (#1004 FR-004).
                let took = Int((ContinuousClock.now - began).components.seconds)
                await changeLinkQuietly(host) { $0.measuredStartSeconds = took }
                // Done as it connects, so a Stop pressed the moment it shows online is heard.
                await finish(host, link, problem: nil)
                await refresh(link.provider)
                return
            }
            if !sshTried, ContinuousClock.now - began >= timing.sshAfter,
               let record = await records.host(host), let destination = await sshDestination(link, host) {
                sshTried = true
                await setPhase(host, "sshStart")
                do {
                    try await hooks.sshStart(record, destination)
                    log("workspace: ssh start \(name): ok")
                } catch {
                    // Nothing else will bring it online, so the start ends now, with why (#960).
                    let reason = (error as? ProviderFailure)?.description ?? "\(error)"
                    log("workspace: ssh start \(name): failed: \(reason)")
                    log("workspace: start \(what) by \(who): failed: ssh start failed")
                    await finish(host, link, problem: "\(name) started, but its agentsd didn’t connect, and starting it over ssh failed. \(reason)")
                    return
                }
            }
            try? await Task.sleep(for: timing.lookEvery)
        }
        let minutes = Self.words(timing.giveUp)
        let problem: String
        if await sshDestination(link, host) == nil {
            problem = "\(name) started, but its agentsd didn’t connect in \(minutes), and the provider gives no ssh destination to start it with. Make agentsd start on boot (loginctl enable-linger)."
        } else {
            problem = "\(name) didn’t connect in \(minutes)."
        }
        log("workspace: start \(what) by \(who): failed: didn't connect in \(minutes)")
        await finish(host, link, problem: problem)
    }

    // MARK: Making and deleting (US5)

    /// Workspaces made here that will install on their first boot, by the host name they will
    /// join as, until they join and are linked.
    private var joining: [String: Joining] = [:]

    private struct Joining {
        var provider: ProviderID
        var workspace: String
        /// What it clones once it has joined (#1122), as the client that made it.
        var clones: [String] = []
        var caller: ControlRouter.Caller?
    }

    /// How long one clone on a new host may take before the next is sent.
    static let clonePatience: Duration = .seconds(3600)

    /// Makes a workspace (FR-040, FR-041): with a one-time install command and host code for
    /// its first boot, so it joins by itself and is linked. A provider that can't run it says
    /// so, and the person adds it over ssh as Add as Host… does.
    private func create(_ request: DaemonAPI.ProviderCreate, by who: String,
                        caller: ControlRouter.Caller? = nil) async throws -> DaemonAPI.ProviderCreated {
        guard let provider = providers[request.id]?.record else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "There is no such provider.")
        }
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isHostName(name) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "A workspace’s name is letters, digits and dashes, and starts with a letter.")
        }
        guard !(await records.hosts).contains(where: { $0.name == name }) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "There is already a host called \(name).")
        }
        // The install line holds a host code: passed on, never logged.
        let firstBoot = try await hooks.hostCommand() + " " + Self.shellQuoted(name)
        let began = ContinuousClock.now
        let made: (DaemonAPI.WorkspaceInfo?, Bool)
        do {
            made = try await providerCall(request.id) { try await $0.create(name: name, options: request.options ?? [:], firstBoot: firstBoot) }
        } catch {
            log("workspace: create \(name) at \(provider.name) by \(who): failed: \((error as? JSONRPCError)?.message ?? "\(error)")")
            throw error
        }
        await refresh(request.id)
        let listedNow = listed[request.id]?.workspaces ?? []
        let found = made.0.map { said in listedNow.first { $0.id == said.id } ?? said }
            ?? listedNow.first { $0.name == name || $0.id == name }
        guard let workspace = found else {
            throw JSONRPCError(code: DaemonAPI.Failure.providerFailed,
                               message: "\(provider.name) made \(name), but doesn’t list it yet. Refresh in a minute.")
        }
        log("workspace: create \(name) (\(request.id)/\(workspace.id)) by \(who): ok in \(Self.seconds(since: began))\(made.1 ? ", joining on first boot" : "")")
        if made.1 {
            let clones = (request.clones ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            joining[name] = Joining(provider: request.id, workspace: workspace.id, clones: clones, caller: caller)
            Task { await self.linkWhenJoined(name) }
        }
        return DaemonAPI.ProviderCreated(workspace: workspace, joining: made.1)
    }

    /// Links a made workspace's host once it has joined, within the start's time.
    private func linkWhenJoined(_ name: String) async {
        let began = ContinuousClock.now
        while ContinuousClock.now - began < timing.giveUp, let wanted = joining[name] {
            if let host = await records.hosts.first(where: { $0.name == name && $0.workspace == nil }) {
                joining[name] = nil
                _ = try? await link(DaemonAPI.HostLink(host: host.id, provider: wanted.provider, workspace: wanted.workspace))
                await clone(wanted.clones, on: host.id, named: name, as: wanted.caller)
                return
            }
            try? await Task.sleep(for: timing.lookEvery)
        }
        if joining.removeValue(forKey: name) != nil {
            log("workspace: \(name) was made but didn't join in \(Self.words(timing.giveUp))")
        }
    }

    /// Clone these projects (#1122): each sent to the new host as File ▸ Clone Project sends
    /// it, one after another, as the client that made the workspace. A private repository
    /// clones with the git access a Mac lends the host, asked of the person the first time.
    /// The URLs are not logged: one may hold a token.
    private func clone(_ urls: [String], on host: HostID, named name: String, as caller: ControlRouter.Caller?) async {
        for (index, url) in urls.enumerated() {
            let reply = await router.deliverKept(DaemonAPI.Method.projectsClone,
                                                 params: try? JSONValue.encoding(DaemonAPI.CloneRequest(url: url)),
                                                 as: caller?.client ?? UUID(), kind: caller?.kind ?? .mac,
                                                 to: host, patience: Self.clonePatience)
            let outcome = switch reply {
            case .success?: "ok"
            // Its code only: the host's words may name the URL.
            case .failure(_, let error)?: "failed (\(error.code))"
            default: "not answered"
            }
            log("workspace: \(name) clone \(index + 1) of \(urls.count): \(outcome)")
        }
    }

    /// Deletes a linked host's workspace, then removes the host as Remove does (FR-042).
    private func deleteWorkspace(_ host: HostID, by who: String, caller: ControlRouter.Caller) async throws {
        guard let record = await records.host(host) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No host is called \(host.rawValue).")
        }
        guard let link = record.workspace, providers[link.provider] != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.notLinked, message: "\(record.name) isn’t linked to a workspace.")
        }
        guard activities[host] == nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.providerFailed,
                               message: "\(record.name) is starting or stopping. Delete it once that is done.")
        }
        do {
            try await providerCall(link.provider) { try await $0.delete(link.workspace) }
        } catch {
            log("workspace: delete \(record.name) (\(link.provider)/\(link.workspace)) by \(who): failed: \((error as? JSONRPCError)?.message ?? "\(error)")")
            throw error
        }
        log("workspace: delete \(record.name) (\(link.provider)/\(link.workspace)) by \(who): ok")
        _ = try await methods.handle(method: DaemonAPI.Method.hostsRemove, params: ["host": .string(host.rawValue)], from: caller)
        await refresh(link.provider)
    }

    /// A provider call, its failure in the provider's words.
    private func providerCall<T: Sendable>(_ id: ProviderID, _ work: (any WorkspaceProvider) async throws -> T) async throws -> T {
        do {
            return try await work(try await connection(id))
        } catch let failure as ProviderFailure {
            throw JSONRPCError(code: DaemonAPI.Failure.providerFailed, message: failure.description)
        }
    }

    static func isHostName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z][A-Za-z0-9-]{0,62}$", options: .regularExpression) != nil
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Stop when idle (US4)

    public func heard(_ host: HostID, status: DaemonAPI.HostStatus) async {
        let was = statuses[host]
        statuses[host] = status
        // Kept on its link, for while it is stopped (#1004 FR-003). A host from before
        // #1004 says nothing, and is left as it was (FR-011).
        if let schedule = status.schedule, await records.host(host)?.workspace.map({ $0.schedule != schedule }) == true {
            await changeLinkQuietly(host) { $0.schedule = schedule }
            await changed()
        }
        // Busy again cancels the count; still idle leaves it running (US4 AS2).
        if !status.idle { idleTimers.removeValue(forKey: host)?.cancel() }
        if status.idle, was?.idle != true || idleTimers[host] == nil { await countIdle(host) }
    }

    /// Starts counting down a linked host's stop when idle, from now, if it is idle, online
    /// and has one; otherwise stops counting.
    private func countIdle(_ host: HostID) async {
        idleTimers.removeValue(forKey: host)?.cancel()
        guard statuses[host]?.idle == true, let minutes = await records.host(host)?.workspace?.stopWhenIdleMinutes,
              minutes > 0, activities[host] == nil, await router.state(of: host)?.isOnline == true else { return }
        let wait = timing.idleMinute * minutes
        idleTimers[host] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.idleFor(host, minutes: minutes)
        }
    }

    private func idleFor(_ host: HostID, minutes: Int) async {
        idleTimers[host] = nil
        // Still idle, still online, and still set to this (US4 AS1).
        guard statuses[host]?.idle == true, activities[host] == nil,
              await router.state(of: host)?.isOnline == true,
              let link = await records.host(host)?.workspace, link.stopWhenIdleMinutes == minutes else { return }
        // Its next scheduled workflow is due within its idle time, or it was started for it:
        // it stays up for the run, and counts again (#1004 FR-005).
        if Self.keptUp(link, idleFor: Self.interval(timing.idleMinute * minutes), now: Date()), let at = link.schedule?.at {
            log("workspace: \(host) idle \(minutes) min, kept up for \(link.schedule?.workflow ?? "a workflow") at \(at)")
            await countIdle(host)
            return
        }
        idleStopping[host] = minutes
        do {
            _ = try await begin(.stop, host, by: "idle (\(minutes) min)")
        } catch {
            idleStopping[host] = nil
            log("workspace: stop \(host) by idle (\(minutes) min): refused: \((error as? JSONRPCError)?.message ?? "\(error)")")
        }
    }

    // MARK: Wake-up calls (#1004)

    /// How long before a due time a stopped workspace is started (FR-004): its last
    /// measured start and 2 minutes, or 5 minutes when none has been measured.
    static func lead(_ link: WorkspaceLink) -> TimeInterval {
        link.measuredStartSeconds.map { TimeInterval($0 + 120) } ?? 300
    }

    /// Whether its next scheduled workflow keeps it up though it is idle (FR-005): due within
    /// its idle time, or it was started for it.
    static func keptUp(_ link: WorkspaceLink, idleFor: TimeInterval, now: Date) -> Bool {
        guard let at = link.schedule?.at, at > now else { return false }
        return at.timeIntervalSince(now) <= idleFor || link.wokeFor == at
    }

    /// When a wake-up call would start it for its next scheduled workflow: with the switch on
    /// and a due time still to come that it was not already started for.
    static func wakeAt(_ link: WorkspaceLink, now: Date) -> Date? {
        guard link.startForSchedules ?? true, let at = link.schedule?.at, at > now, link.wokeFor != at else { return nil }
        return at.addingTimeInterval(-lead(link))
    }

    /// Starts each stopped workspace whose wake-up call is due (FR-004, FR-006). Only this
    /// copy runs providers, so only it makes them.
    func wakeUps(now: Date) async {
        for record in await records.hosts {
            guard let link = record.workspace, providers[link.provider] != nil,
                  let wake = Self.wakeAt(link, now: now), wake <= now, let at = link.schedule?.at,
                  activities[record.id] == nil, overlay(record)?.hostState == "stopped",
                  await router.state(of: record.id)?.isOnline != true else { continue }
            // Marked before the start, so a restart or a reconnect never starts it twice for it.
            await changeLinkQuietly(record.id) { $0.wokeFor = at }
            let workflow = link.schedule?.workflow ?? "a workflow"
            log("workspace: wake-up call for \(record.name): \(workflow) due at \(at)")
            _ = try? await begin(.start, record.id, by: "schedule (\(workflow))")
        }
    }

    /// Changes a host's link and saves it, without telling clients.
    private func changeLinkQuietly(_ host: HostID, _ change: (inout WorkspaceLink) -> Void) async {
        guard var record = await records.host(host), var link = record.workspace else { return }
        change(&link)
        guard link != record.workspace else { return }
        record.workspace = link
        do { try await records.save(record) } catch { log("workspace: couldn't save \(record.name)'s link: \(error)") }
    }

    static func interval(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    static func words(minutes: Int) -> String {
        switch minutes {
        case 60: "1 hour"
        case let m where m % 60 == 0: "\(m / 60) hours"
        case 1: "1 minute"
        default: "\(minutes) minutes"
        }
    }

    /// "Claude (fix-login) and Codex (docs)".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    private func setPhase(_ host: HostID, _ phase: String) async {
        activities[host]?.phase = phase
        await changed()
    }

    private func finish(_ host: HostID, _ link: WorkspaceLink, problem: String?) async {
        let kind = activities[host]?.kind
        activities[host] = nil
        idleStopping[host] = nil
        problems[host] = problem
        await changed()
        if kind == .start, let problem { await kept?.startFailed(host, problem) }
        // A host says it is idle as it connects, while the start is still under way, and
        // isn't counted then: count now, or a host started and left idle is never stopped.
        if kind == .start, problem == nil { await countIdle(host) }
    }

    /// Where agentsd is started over ssh: the provider's destination, or the one the host
    /// was installed over, as its tunnel keeps it (#965).
    private func sshDestination(_ link: WorkspaceLink, _ host: HostID) async -> String? {
        if let given = workspace(link)?.ssh { return given }
        return await hooks.installedOver(host)
    }

    private func workspace(_ link: WorkspaceLink) -> DaemonAPI.WorkspaceInfo? {
        listed[link.provider]?.workspaces.first { $0.id == link.workspace }
    }

    // MARK: What clients are told

    /// Lays each linked host's workspace over its state, and tells clients the providers.
    private func changed() async {
        for record in await records.hosts {
            await router.setWorkspace(overlay(record), of: record.id)
        }
        if let summaries = try? JSONValue.encoding(await summaries()) {
            await router.broadcastControl(DaemonAPI.Notification.controlProvidersChanged, ["providers": summaries])
        }
    }

    func overlay(_ record: HostRecord) -> DaemonAPI.HostWorkspace? {
        guard let link = record.workspace, let provider = providers[link.provider]?.record else { return nil }
        let list = listed[link.provider]
        let found = workspace(link)
        let state = found?.state ?? "unknown"
        let activity = activities[record.id]
        let now = Date()
        let upcoming = link.schedule.flatMap { $0.at.map { $0 > now } == true ? $0 : nil }
        let hostState: String? = switch activity?.kind {
        case .start?: "starting"
        case .stop?: "stopping"
        case nil: ["stopped", "starting", "stopping"].contains(state) ? state : nil
        }
        return DaemonAPI.HostWorkspace(
            provider: link.provider, providerName: provider.name, workspace: link.workspace,
            workspaceName: found?.name ?? link.workspace, workspaceState: state, hostState: hostState,
            phase: activity?.kind == .start ? activity?.phase : nil, since: activity?.since,
            problem: problems[record.id],
            stoppedBy: hostState == "stopped" ? stoppedBy[record.id] : nil,
            // A running one whose start failed can be started again: its agentsd is what is down (#960).
            canStart: activity == nil && (!["running", "starting"].contains(state)
                                          || (state == "running" && problems[record.id] != nil)),
            canStop: activity == nil && ["running", "starting", "unknown"].contains(state),
            startWhenUsed: link.startWhenUsed ?? true, stopWhenIdleMinutes: link.stopWhenIdleMinutes,
            cost: found?.cost, current: list?.current ?? false,
            startForSchedules: link.startForSchedules ?? true, tellsSchedule: link.schedule != nil,
            nextWorkflow: upcoming?.workflow, nextWorkflowAt: upcoming?.at,
            // Also while it runs, so Stop's confirmation can say when it starts next (FR-010).
            wakeAt: Self.wakeAt(link, now: now))
    }

    // MARK: Helpers

    private static func require<T: Decodable>(_ params: JSONValue?, as type: T.Type) throws -> T {
        guard let params, let value = try? params.decode(T.self) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Those parameters are not a \(T.self).")
        }
        return value
    }

    /// An ssh destination as a provider may give it, `alex@127.0.0.1 -p 2222`, as one word
    /// ssh takes: `ssh://alex@127.0.0.1:2222`.
    public static func sshDestination(_ given: String) -> String {
        let words = given.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 3, words[1] == "-p", let port = Int(words[2]) else { return given }
        return "ssh://\(words[0]):\(port)"
    }

    /// Why an ssh start failed, in words (#960): an install's, but a host key to trust is
    /// trusted with ssh itself, as there is no install here to show it.
    public static func say(_ problem: HostProblem, destination: String) -> String {
        guard problem == .hostKeyUnknown else { return HostInstall.say(problem) }
        let ssh = destination.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "Its host key isn’t in your known_hosts. Check and trust it with “ssh \(ssh)”, then start it again."
    }

    static func seconds(since start: ContinuousClock.Instant) -> String {
        "\(Int((ContinuousClock.now - start).components.seconds))s"
    }

    static func words(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return seconds >= 60 ? "\(seconds / 60) minutes" : "\(seconds) seconds"
    }
}

import Foundation

/// The methods the control plane answers itself (058, contracts/control-api.md), and
/// what it does with a host's channel 0.
///
/// Portable: pairing codes, enrolment keys and ssh installs need CryptoKit, Network and
/// processes, so the executable hands those in as closures. Everything here is records
/// and rules.
public actor ControlMethods: ControlHandling {
    public struct Hooks: Sendable {
        /// `clients/startPairing` / `devices/startPairing`: a code for a new client.
        public var startPairing: @Sendable (Grant) async throws -> JSONValue
        public var stopPairing: @Sendable () async -> Void
        /// `hosts/startEnroll`: a code for a new host.
        public var startEnroll: @Sendable () async throws -> JSONValue
        /// `hosts/install`, `hosts/update`, `hosts/checkAgain`: the ssh path (US3).
        public var install: @Sendable (JSONValue?) async throws -> JSONValue
        public var update: @Sendable (HostID) async throws -> Void
        public var checkAgain: @Sendable (HostID) async throws -> Void
        /// A need a host raised, for the control plane to choose a device and seal (R6).
        public var need: @Sendable (HostID, JSONValue?) async -> Void
        /// A client was forgotten: its key must stop working on every listener.
        public var clientsChanged: @Sendable ([ClientRecord]) async -> Void
        /// A host enrolled or removed: its key starts or stops working.
        public var hostsChanged: @Sendable () async -> Void
        /// A change a person made, for every other copy to apply (058, US3, T066). Called
        /// after the store has it.
        public var changed: @Sendable (ControlEvent) async -> Void = { _ in }
        /// A host started or stopped relaying, or a relay host said hello (T096).
        public var relayChanged: @Sendable (HostID) async -> Void = { _ in }

        public init(startPairing: @escaping @Sendable (Grant) async throws -> JSONValue = { _ in throw ControlMethods.notHere },
                    stopPairing: @escaping @Sendable () async -> Void = {},
                    startEnroll: @escaping @Sendable () async throws -> JSONValue = { throw ControlMethods.notHere },
                    install: @escaping @Sendable (JSONValue?) async throws -> JSONValue = { _ in throw ControlMethods.notHere },
                    update: @escaping @Sendable (HostID) async throws -> Void = { _ in throw ControlMethods.notHere },
                    checkAgain: @escaping @Sendable (HostID) async throws -> Void = { _ in },
                    need: @escaping @Sendable (HostID, JSONValue?) async -> Void = { _, _ in },
                    clientsChanged: @escaping @Sendable ([ClientRecord]) async -> Void = { _ in },
                    hostsChanged: @escaping @Sendable () async -> Void = {}) {
            self.hostsChanged = hostsChanged
            self.startPairing = startPairing
            self.stopPairing = stopPairing
            self.startEnroll = startEnroll
            self.install = install
            self.update = update
            self.checkAgain = checkAgain
            self.need = need
            self.clientsChanged = clientsChanged
        }
    }

    public static let notHere = JSONRPCError(code: DaemonAPI.Failure.notSupported,
                                             message: "This control plane cannot do that yet.")

    private let records: ControlRecords
    private let version: String
    private var hooks: Hooks
    private var settings: ControlSettings
    private weak var router: ControlRouter?

    private let startedAt = Date()
    private let port: Int?
    private let awayFromHome: Bool

    /// `settings` is what `records` has, or made (`ControlRecords.settings(orMake:)`):
    /// the records are read before this is made, so every accessor below is current.
    public init(records: ControlRecords, settings: ControlSettings, version: String, hooks: Hooks = Hooks(),
                port: Int? = nil, awayFromHome: Bool = false) {
        self.port = port
        self.awayFromHome = awayFromHome
        self.records = records
        self.settings = settings
        self.version = version
        self.hooks = hooks
    }

    /// Reads the store again: the backstop for a change another copy made (R4).
    public func refresh() async throws {
        try await records.load()
        if let fresh = await records.settings { settings = fresh }
    }

    public func attach(_ router: ControlRouter) { self.router = router }

    /// The executable's part, handed in once it exists (the network listener needs the
    /// records, and the records need the listener's hooks).
    public func setHooks(_ hooks: Hooks) { self.hooks = hooks }

    public var knownHosts: [HostID] { get async { await records.hosts.map(\.id) } }
    public var allClients: [ClientRecord] { get async { await records.clients } }
    public var allHosts: [HostRecord] { get async { await records.hosts } }
    public func client(_ id: UUID) async -> ClientRecord? { await records.client(id) }
    public func host(_ id: HostID) async -> HostRecord? { await records.host(id) }
    public var controlSettings: ControlSettings { settings }

    // MARK: Records the executable changes

    /// A client that has paired, or this Mac's own window arriving on the local socket.
    ///
    /// `lastSeen` is written at most hourly (R4): a connect is not a write.
    public func admit(_ client: ClientRecord) async throws {
        do {
            try await admitOnce(client)
        } catch StoreError.conflict {
            try await records.load()
            try await admitOnce(client)
        }
        let changed = await records.clients
        Task { await router?.broadcastControl(DaemonAPI.Notification.controlClientChanged,
                                              ["client": .string(client.id.uuidString)], operatorsOnly: true) }
        Task { await hooks.clientsChanged(changed) }
    }

    private func admitOnce(_ client: ClientRecord) async throws {
        if var known = await records.client(client.id) {
            let stale = known.lastSeen.map { Date().timeIntervalSince($0) > 3600 } ?? true
            guard stale || known.name != client.name else { return }
            known.lastSeen = Date()
            known.name = client.name
            try await records.save(known)
        } else {
            var fresh = client
            fresh.lastSeen = fresh.lastSeen ?? Date()
            try await records.save(fresh)
        }
    }

    /// What a member said it holds of the endpoints (R16), written only when it changes,
    /// so Agents Host can say who has heard of a move. A conflict is let go: the next
    /// connection says it again.
    public func noteEpoch(client id: UUID, _ epoch: Int) async {
        guard var known = await records.client(id), known.knownEpoch != epoch else { return }
        known.knownEpoch = epoch
        try? await records.save(known)
    }

    public func noteEpoch(host id: HostID, _ epoch: Int) async {
        guard var known = await records.host(id), known.knownEpoch != epoch else { return }
        known.knownEpoch = epoch
        try? await records.save(known)
    }

    /// A host that has enrolled, or this Mac's own host arriving on the local socket.
    public func enroll(_ host: HostRecord) async throws {
        try await records.save(host)
    }

    /// Where the control plane answers from now on, in order (R16): the list every member
    /// is given in `ok`, under a new epoch so each one takes it.
    @discardableResult
    public func setEndpoints(_ endpoints: [ControlEndpoint]) async throws -> ControlSettings {
        guard !endpoints.isEmpty, endpoints.allSatisfy(\.isAcceptable) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Each place must be https, with a pin or none.")
        }
        // `url` and `pin` stay this copy's own, which codes carry and a handover reaches it
        // at; the list is what members are told.
        settings = try await records.changeSettings {
            $0.endpoints = endpoints
            $0.epoch = ($0.epoch ?? 0) + 1
        }
        return settings
    }

    public func setHomeHost(_ host: HostID) async throws {
        guard settings.homeHost != host else { return }
        settings = try await records.changeSettings { $0.homeHost = host }
    }

    // MARK: ControlHandling

    private static let own: Set<String> = [
        DaemonAPI.Method.ping, DaemonAPI.Method.controlStatus, DaemonAPI.Method.hostsList,
        DaemonAPI.Method.hostsStartEnroll, DaemonAPI.Method.hostsInstall, DaemonAPI.Method.hostsCheckAgain,
        DaemonAPI.Method.hostsUpdate, DaemonAPI.Method.hostsRemove, DaemonAPI.Method.hostsSetRelay,
        DaemonAPI.Method.hostsLendSignIn,
        DaemonAPI.Method.clientsList, DaemonAPI.Method.clientsStartPairing, DaemonAPI.Method.clientsStopPairing,
        DaemonAPI.Method.clientsSetGrant, DaemonAPI.Method.clientsForget, DaemonAPI.Method.clientsConnections,
        DaemonAPI.Method.devicesList, DaemonAPI.Method.devicesStartPairing, DaemonAPI.Method.devicesStopPairing,
        DaemonAPI.Method.devicesForget,
    ]

    /// Anyone connected may ask these. Everything else of the control plane's is an
    /// operator's.
    static let anyGrant: Set<String> = [
        DaemonAPI.Method.ping, DaemonAPI.Method.controlStatus, DaemonAPI.Method.hostsList,
    ]

    public nonisolated func handles(_ method: String) -> Bool {
        // A bare `daemon/ping` from today's Remote is the home host's to answer: that is
        // how the Remote knows its Mac is there.
        method != DaemonAPI.Method.ping && Self.own.contains(method)
    }

    public func handle(method: String, params: JSONValue?, from caller: ControlRouter.Caller) async throws -> JSONValue {
        do {
            return try await answer(method: method, params: params, from: caller)
        } catch let error as StoreError {
            throw error.rpcError
        }
    }

    /// Frozen for a handover (R16): records are not to change until it is done.
    public private(set) var frozen = false
    public func setFrozen(_ value: Bool) { frozen = value }

    /// What changes records, refused while frozen.
    private static let writes: Set<String> = [
        DaemonAPI.Method.hostsStartEnroll, DaemonAPI.Method.hostsInstall, DaemonAPI.Method.hostsUpdate,
        DaemonAPI.Method.hostsRemove, DaemonAPI.Method.hostsSetRelay, DaemonAPI.Method.hostsLendSignIn,
        DaemonAPI.Method.clientsStartPairing, DaemonAPI.Method.clientsSetGrant, DaemonAPI.Method.clientsForget,
        DaemonAPI.Method.devicesStartPairing, DaemonAPI.Method.devicesForget,
    ]

    private func answer(method: String, params: JSONValue?, from caller: ControlRouter.Caller) async throws -> JSONValue {
        if frozen, Self.writes.contains(method) {
            throw JSONRPCError(code: DaemonAPI.Failure.storeUnavailable,
                               message: "The control plane is moving to another machine. Nothing was changed; try again in a minute.")
        }
        guard Self.anyGrant.contains(method) || caller.grant == .operator else {
            throw JSONRPCError(code: DaemonAPI.Failure.notPermitted,
                               message: "\(method) is not open to this client (\(caller.grant.rawValue)).")
        }
        switch method {
        case DaemonAPI.Method.ping:
            return [:]
        case DaemonAPI.Method.controlStatus:
            var status = DaemonAPI.ControlStatus(name: settings.name, version: version,
                                                                  homeHost: settings.homeHost, machineID: settings.machineID,
                                                                  startedAt: startedAt, port: port,
                                                                  awayFromHome: awayFromHome)
            status.you = caller.client
            status.relayKey = await records.hosts.first { $0.relay == true }?.publicKey
            // A relay host is what takes devices out of the house (T096).
            if status.relayKey != nil { status.awayFromHome = true }
            return try JSONValue.encoding(status)
        case DaemonAPI.Method.hostsList:
            return try JSONValue.encoding(await hostList())
        case DaemonAPI.Method.clientsList, DaemonAPI.Method.devicesList:
            return try JSONValue.encoding(await records.clients)
        case DaemonAPI.Method.clientsConnections:
            // The relaying host by name; with more than one, the first, as a relayed
            // session does not say which carried it.
            let relay = await records.hosts.first { $0.relay == true }?.name
            let links = await router?.connections() ?? [:]
            return try JSONValue.encoding(links.map { client, relayed in
                DaemonAPI.ClientConnection(client: client, relayed: relayed, through: relayed ? relay : nil)
            }.sorted { $0.client.uuidString < $1.client.uuidString })
        case DaemonAPI.Method.clientsStartPairing:
            let grant = (params?["grant"]?.stringValue).flatMap(Grant.init(rawValue:)) ?? .device
            return try await hooks.startPairing(grant)
        case DaemonAPI.Method.devicesStartPairing:
            return try await hooks.startPairing(.device)
        case DaemonAPI.Method.clientsStopPairing, DaemonAPI.Method.devicesStopPairing:
            await hooks.stopPairing()
            return [:]
        case DaemonAPI.Method.clientsSetGrant:
            let request = try Self.require(params, as: DaemonAPI.ClientGrantRequest.self)
            try await records.setGrant(request.grant, of: request.client)
            await router?.setGrant(request.grant, of: request.client)
            await hooks.changed(ControlEvent(kind: .grantChanged, subject: request.client.uuidString, at: Date(),
                                             by: caller.client.uuidString))
            await router?.broadcastControl(DaemonAPI.Notification.controlClientChanged,
                                           ["client": .string(request.client.uuidString)], operatorsOnly: true)
            return [:]
        case DaemonAPI.Method.clientsForget, DaemonAPI.Method.devicesForget:
            let id: UUID
            if let client = params?["client"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                id = client
            } else if let device = params?["id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                id = device
            } else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Which client?")
            }
            try await forget(id)
            await hooks.changed(ControlEvent(kind: .clientForgotten, subject: id.uuidString, at: Date(),
                                             by: caller.client.uuidString))
            return [:]
        case DaemonAPI.Method.hostsStartEnroll:
            return try await hooks.startEnroll()
        case DaemonAPI.Method.hostsInstall:
            return try await hooks.install(params)
        case DaemonAPI.Method.hostsUpdate:
            try await hooks.update(try Self.require(params, as: DaemonAPI.HostRequest.self).host)
            return [:]
        case DaemonAPI.Method.hostsCheckAgain:
            try await hooks.checkAgain(try Self.require(params, as: DaemonAPI.HostRequest.self).host)
            return [:]
        case DaemonAPI.Method.hostsLendSignIn:
            let request = try Self.require(params, as: DaemonAPI.LendSignIn.self)
            guard var record = await records.host(request.host), await records.host(request.from) != nil else {
                throw JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No such host.")
            }
            var lends = record.signInFrom ?? [:]
            lends[request.runtime] = request.allowed ? request.from : nil
            record.signInFrom = lends.isEmpty ? nil : lends
            try await records.save(record)
            await hooks.changed(ControlEvent(kind: .hostEnrolled, subject: request.host.rawValue, at: Date(),
                                             by: caller.client.uuidString))
            return [:]
        case DaemonAPI.Method.hostsSetRelay:
            let request = try Self.require(params, as: DaemonAPI.HostRelayRequest.self)
            guard var record = await records.host(request.host) else {
                throw JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No host is called \(request.host.rawValue).")
            }
            // Only `agents-relay` carries devices; a host that runs agents cannot start to.
            guard record.relay != nil else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "\(record.name) does not relay.")
            }
            record.relay = request.relay
            try await records.save(record)
            await hooks.relayChanged(request.host)
            await hooks.changed(ControlEvent(kind: .hostEnrolled, subject: request.host.rawValue, at: Date(),
                                             by: caller.client.uuidString))
            return [:]
        case DaemonAPI.Method.hostsRemove:
            let request = try Self.require(params, as: DaemonAPI.HostRequest.self)
            guard try await records.remove(request.host) else {
                throw JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No host is called \(request.host.rawValue).")
            }
            await router?.forgetHost(request.host)
            await hooks.hostsChanged()
            await hooks.changed(ControlEvent(kind: .hostRemoved, subject: request.host.rawValue, at: Date(),
                                             by: caller.client.uuidString))
            return [:]
        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    public func hostSaid(_ host: HostID, method: String, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case DaemonAPI.Method.controlPing:
            return [:]
        case DaemonAPI.Method.hostHello:
            let hello = try Self.require(params, as: DaemonAPI.HostHello.self)
            var record = await records.host(host) ?? HostRecord(id: host, name: hello.name ?? host.rawValue)
            record.version = hello.version
            record.platform = hello.platform
            record.machineID = hello.machineID
            if let name = hello.name { record.name = name }
            // Whether a host relays is settled when it enrols (`hosts/announce`) and changed
            // only by an operator (`hosts/setRelay`). A host's own hello never makes it a
            // relay: one that runs agents would otherwise hear every host's headlines and
            // hold every device's notices (T102).
            try await enroll(record)
            // The home host is where a device's plain connection goes: the host on the
            // control plane's own machine, or, on a control plane with none (servers only,
            // like the review demo), the first host to join until one on its machine does.
            if hello.relay != true {
                let onThisMachine = hello.machineID == settings.machineID
                let home = settings.homeHost
                var homeIsHere = false
                if let home { homeIsHere = await records.host(home)?.machineID == settings.machineID }
                if home == nil || (onThisMachine && home != host && !homeIsHere) {
                    try await setHomeHost(host)
                    await router?.setHomeHost(host)
                }
            }
            await router?.broadcastControl(DaemonAPI.Notification.controlHostChanged,
                                           ControlRouter.describe(host, .online))
            if record.relay == true { await hooks.relayChanged(host) }
            return [:]
        case DaemonAPI.Method.attentionNeed:
            await hooks.need(host, params)
            return [:]
        case DaemonAPI.Method.tunnelOpen:
            // Only to a lender an operator said yes to, for that runtime (T091).
            let request = try Self.require(params, as: DaemonAPI.TunnelOpen.self)
            if await records.host(host)?.signInFrom?[request.runtime] == nil { try? await refresh() }
            guard let lender = await records.host(host)?.signInFrom?[request.runtime] else {
                throw JSONRPCError(code: DaemonAPI.Failure.notPermitted,
                                   message: "No host lends this host its \(request.runtime) sign-in.")
            }
            guard await router?.openTunnel(borrower: host, lender: lender, runtime: request.runtime, ref: request.ref) == true else {
                throw JSONRPCError(code: DaemonAPI.Failure.hostOffline, message: "The host that lends this sign-in is offline.")
            }
            return [:]
        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    // MARK: Helpers

    private func forget(_ id: UUID) async throws {
        try await records.forget(id)
        let changed = await records.clients
        Task {
            await router?.forgetClient(id)
            await router?.broadcastControl(DaemonAPI.Notification.controlClientChanged,
                                           ["client": .string(id.uuidString), "removed": true], operatorsOnly: true)
            await hooks.clientsChanged(changed)
        }
    }

    private func hostList() async -> [DaemonAPI.ControlHost] {
        let states = await router?.hostStates ?? [:]
        return await records.hosts.map { record in
            let state = states[record.id] ?? .offline(since: Date())
            var listed = DaemonAPI.ControlHost(id: record.id, name: record.name, platform: record.platform,
                                               version: record.version,
                                               state: ControlRouter.describe(record.id, state)["state"]?.stringValue ?? "offline",
                                               reach: "dialOut", machineID: record.machineID, relay: record.relay)
            listed.signInFrom = record.signInFrom
            return listed
        }
    }

    private static func require<T: Decodable>(_ params: JSONValue?, as type: T.Type) throws -> T {
        guard let params, let value = try? params.decode(T.self) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Those parameters are not a \(T.self).")
        }
        return value
    }
}

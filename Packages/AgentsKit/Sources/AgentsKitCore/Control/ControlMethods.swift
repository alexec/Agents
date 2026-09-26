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

    private let store: GrantStore
    private let version: String
    private var hooks: Hooks
    private var settings: ControlSettings
    private var clients: [ClientRecord]
    private var hosts: [HostID: HostRecord]
    private weak var router: ControlRouter?

    private let startedAt = Date()
    private let port: Int?
    private let awayFromHome: Bool

    public init(store: GrantStore, settings: ControlSettings, version: String, hooks: Hooks = Hooks(),
                port: Int? = nil, awayFromHome: Bool = false) {
        self.port = port
        self.awayFromHome = awayFromHome
        self.store = store
        self.settings = settings
        self.version = version
        self.hooks = hooks
        self.clients = store.loadClients()
        self.hosts = Dictionary(store.loadHosts().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func attach(_ router: ControlRouter) { self.router = router }

    /// The executable's part, handed in once it exists (the network listener needs the
    /// records, and the records need the listener's hooks).
    public func setHooks(_ hooks: Hooks) { self.hooks = hooks }

    public var knownHosts: [HostID] { Array(hosts.keys) }
    public var allClients: [ClientRecord] { clients }
    public var allHosts: [HostRecord] { Array(hosts.values) }
    public func client(_ id: UUID) -> ClientRecord? { clients.first { $0.id == id } }
    public func host(_ id: HostID) -> HostRecord? { hosts[id] }
    public var controlSettings: ControlSettings { settings }

    // MARK: Records the executable changes

    /// A client that has paired, or this Mac's own window arriving on the local socket.
    public func admit(_ client: ClientRecord) throws {
        if let index = clients.firstIndex(where: { $0.id == client.id }) {
            clients[index].lastSeen = Date()
            clients[index].name = client.name
        } else {
            clients.append(client)
        }
        try store.saveClients(clients)
        let changed = clients
        Task { await router?.broadcastControl(DaemonAPI.Notification.controlClientChanged,
                                              ["client": .string(client.id.uuidString)], operatorsOnly: true) }
        Task { await hooks.clientsChanged(changed) }
    }

    /// A host that has enrolled, or this Mac's own host arriving on the local socket.
    public func enroll(_ host: HostRecord) throws {
        hosts[host.id] = host
        try store.saveHosts(Array(hosts.values).sorted { $0.id.rawValue < $1.id.rawValue })
    }

    public func setHomeHost(_ host: HostID) throws {
        guard settings.homeHost != host else { return }
        settings.homeHost = host
        try store.saveSettings(settings)
    }

    // MARK: ControlHandling

    private static let own: Set<String> = [
        DaemonAPI.Method.ping, DaemonAPI.Method.controlStatus, DaemonAPI.Method.hostsList,
        DaemonAPI.Method.hostsStartEnroll, DaemonAPI.Method.hostsInstall, DaemonAPI.Method.hostsCheckAgain,
        DaemonAPI.Method.hostsUpdate, DaemonAPI.Method.hostsRemove,
        DaemonAPI.Method.clientsList, DaemonAPI.Method.clientsStartPairing, DaemonAPI.Method.clientsStopPairing,
        DaemonAPI.Method.clientsSetGrant, DaemonAPI.Method.clientsForget,
        DaemonAPI.Method.devicesList, DaemonAPI.Method.devicesStartPairing, DaemonAPI.Method.devicesStopPairing,
        DaemonAPI.Method.devicesForget,
    ]

    /// Anyone connected may ask these. Everything else of the control plane's is an
    /// operator's.
    private static let anyGrant: Set<String> = [
        DaemonAPI.Method.ping, DaemonAPI.Method.controlStatus, DaemonAPI.Method.hostsList,
    ]

    public nonisolated func handles(_ method: String) -> Bool {
        // A bare `daemon/ping` from today's Remote is the home host's to answer: that is
        // how the Remote knows its Mac is there.
        method != DaemonAPI.Method.ping && Self.own.contains(method)
    }

    public func handle(method: String, params: JSONValue?, from caller: ControlRouter.Caller) async throws -> JSONValue {
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
            return try JSONValue.encoding(status)
        case DaemonAPI.Method.hostsList:
            return try JSONValue.encoding(await hostList())
        case DaemonAPI.Method.clientsList, DaemonAPI.Method.devicesList:
            return try JSONValue.encoding(clients)
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
            clients = try GrantStore.settingGrant(request.grant, of: request.client, in: clients)
            try store.saveClients(clients)
            await router?.setGrant(request.grant, of: request.client)
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
            try forget(id)
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
        case DaemonAPI.Method.hostsRemove:
            let request = try Self.require(params, as: DaemonAPI.HostRequest.self)
            guard hosts.removeValue(forKey: request.host) != nil else {
                throw JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No host is called \(request.host.rawValue).")
            }
            try store.saveHosts(Array(hosts.values))
            await router?.forgetHost(request.host)
            await hooks.hostsChanged()
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
            var record = hosts[host] ?? HostRecord(id: host, name: hello.name ?? host.rawValue)
            record.version = hello.version
            record.platform = hello.platform
            record.machineID = hello.machineID
            if let name = hello.name { record.name = name }
            if record != hosts[host] { try enroll(record) }
            if hello.machineID == settings.machineID, settings.homeHost == nil {
                try setHomeHost(host)
                await router?.setHomeHost(host)
            }
            await router?.broadcastControl(DaemonAPI.Notification.controlHostChanged,
                                           ControlRouter.describe(host, .online))
            return [:]
        case DaemonAPI.Method.attentionNeed:
            await hooks.need(host, params)
            return [:]
        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    // MARK: Helpers

    private func forget(_ id: UUID) throws {
        clients = try GrantStore.forgetting(id, in: clients)
        try store.saveClients(clients)
        let changed = clients
        Task {
            await router?.forgetClient(id)
            await router?.broadcastControl(DaemonAPI.Notification.controlClientChanged,
                                           ["client": .string(id.uuidString), "removed": true], operatorsOnly: true)
            await hooks.clientsChanged(changed)
        }
    }

    private func hostList() async -> [DaemonAPI.ControlHost] {
        let states = await router?.hostStates ?? [:]
        return hosts.values.sorted { $0.id.rawValue < $1.id.rawValue }.map { record in
            let state = states[record.id] ?? .offline(since: Date())
            return DaemonAPI.ControlHost(id: record.id, name: record.name, platform: record.platform,
                                         version: record.version,
                                         state: ControlRouter.describe(record.id, state)["state"]?.stringValue ?? "offline",
                                         reach: record.reach.isSSH ? "ssh" : "dialOut", machineID: record.machineID)
        }
    }

    private static func require<T: Decodable>(_ params: JSONValue?, as type: T.Type) throws -> T {
        guard let params, let value = try? params.decode(T.self) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Those parameters are not a \(T.self).")
        }
        return value
    }
}

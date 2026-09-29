import AgentsKitCore
import Foundation

/// The control plane, assembled (058): its records, its own methods, the router, and the
/// two local sockets this Mac's window and this Mac's host reach it on.
///
/// Devices on the network and in iCloud still reach this Mac's host through the bridge
/// as they always have; they move onto the router in US4. Hosts elsewhere join in US3.
public final class ControlPlane: @unchecked Sendable {
    public let root: URL
    public let router: ControlRouter
    public let methods: ControlMethods
    private var listeners: [UnixSocketListener] = []

    /// `~/Library/Application Support/Agents Control` on a Mac; `~/.agents-control`
    /// elsewhere. `--control-root` or `AGENTS_CONTROL_ROOT` for any other.
    public static var defaultRoot: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Agents Control", isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents-control", isDirectory: true)
        #endif
    }

    public static let rootVariable = "AGENTS_CONTROL_ROOT"
    public static let rootFlag = "--control-root"
    /// `--control-plane`: the ordinary root. What the launch agent says, since a plist
    /// cannot name a path under the person's home.
    public static let defaultRootFlag = "--control-plane"

    public static func chosenRoot(arguments: [String] = CommandLine.arguments,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let at = arguments.firstIndex(of: rootFlag), arguments.indices.contains(at + 1) {
            return URL(fileURLWithPath: arguments[at + 1], isDirectory: true)
        }
        if let root = environment[rootVariable] { return URL(fileURLWithPath: root, isDirectory: true) }
        return arguments.contains(defaultRootFlag) ? defaultRoot : nil
    }

    /// Where this Mac's window connects.
    public static func clientSocket(root: URL) -> URL { root.appendingPathComponent("control.sock") }
    /// Where this Mac's host connects.
    public static func hostSocket(root: URL) -> URL { root.appendingPathComponent("hosts.sock") }

    /// What the window on this Mac is called when the Mac has no name to give it.
    public static let windowName = "This Mac"

    /// Where the records are kept: a folder store in the control root (contracts/store.md).
    public static func store(root: URL) -> FolderStore { FolderStore(root: root.appendingPathComponent("store", isDirectory: true)) }

    static func freshSettings() -> ControlSettings {
        ControlSettings(name: Host.current().localizedName ?? "This Mac", machineID: MachineID.current)
    }

    public init(root: URL, version: String, port: Int? = nil, awayFromHome: Bool = false) {
        self.root = root
        let records = ControlRecords(store: Self.store(root: root))
        self.records = records
        let settings = Self.freshSettings()
        let methods = ControlMethods(records: records, settings: settings, version: version,
                                     port: port, awayFromHome: awayFromHome)
        self.methods = methods
        self.router = ControlRouter(handler: methods)
        self.name = settings.name
        self.servers = SSHHosts(root: root, installedBy: settings.name)
        #if canImport(Network) && canImport(CryptoKit)
        if let port {
            do {
                net = try ControlNet(root: root, port: UInt16(clamping: port),
                                     advertise: ProcessInfo.processInfo.environment["AGENTS_CONTROL_NO_BONJOUR"] == nil)
            } catch {
                DaemonLog.shared.write("control: no key, so nothing can connect over the network: \(error)")
            }
        }
        #endif
    }

    private let name: String
    private let records: ControlRecords
    /// Servers reached over ssh (US3).
    let servers: SSHHosts
    #if canImport(Network) && canImport(CryptoKit)
    /// The control plane on the network, when it was given a port.
    public private(set) var net: ControlNet?
    #endif

    /// A one-time host code, so `hosts/install` can have the server dial out (T044).
    /// Nil when this control plane is not listening on the network.
    func enrolmentCode() async -> String? {
        #if canImport(Network) && canImport(CryptoKit)
        guard let net else { return nil }
        return await net.startCode(.host, name: name).text
        #else
        return nil
        #endif
    }

    /// Going away (launchd's SIGTERM): the ssh master to each server stops with the
    /// control plane rather than outliving it. The servers' daemons carry on.
    public func stop() async {
        await servers.sync([])
    }

    public func start() async throws {
        _ = try await records.settings(orMake: Self.freshSettings)
        try await methods.refresh()
        for host in await methods.knownHosts { await router.know(host) }
        await router.setHomeHost(await methods.controlSettings.homeHost)
        await methods.attach(router)
        let servers = self.servers
        let methods = self.methods
        await servers.attach(self)
        knownClients = Set(await methods.allClients.map(\.id))
        var hooks = ControlMethods.Hooks(
            install: { try await servers.install($0) },
            update: { try await servers.checkAgain($0) },
            checkAgain: { try await servers.checkAgain($0) },
            need: { [onNeed] host, params in await onNeed?(host, params) },
            clientsChanged: { [weak self] now in await self?.clientsChanged(now) },
            hostsChanged: { await servers.sync(await methods.allHosts) })
        #if canImport(Network) && canImport(CryptoKit)
        if let net {
            await net.attach(methods: methods, plane: self)
            let name = self.name
            hooks.startPairing = { grant in try JSONValue.encoding(await net.startCode(.client(grant), name: name)) }
            hooks.stopPairing = { await net.stopCodes() }
            hooks.startEnroll = { try JSONValue.encoding(await net.startCode(.host, name: name)) }
            hooks.clientsChanged = { [weak self] now in
                await net.relisten()
                await self?.clientsChanged(now)
            }
            hooks.hostsChanged = {
                await net.relisten()
                await servers.sync(await methods.allHosts)
            }
            await net.start()
        }
        #endif
        await methods.setHooks(hooks)
        await servers.reconnectAll(await methods.allHosts)
        let roles = RolePolicy.forControl(root: root)
        DaemonLog.shared.write("control: \(roles.summary)")
        let clients = UnixSocketListener(url: Self.clientSocket(root: root), roles: roles) { [weak self] transport, role, peer in
            Task { await self?.clientArrived(transport, role: role, peer: peer) }
        }
        let hosts = UnixSocketListener(url: Self.hostSocket(root: root), roles: roles) { [weak self] transport, role, peer in
            Task { await self?.hostArrived(transport, role: role, peer: peer) }
        }
        try clients.start()
        try hosts.start()
        listeners = [clients, hosts]
        DaemonLog.shared.write("control: listening at \(root.path)")
    }

    public func stop() {
        for listener in listeners { listener.stop() }
    }

    /// A host's unsealed `attention/need`. Set before `start`, which is when the hook is taken.
    public var onNeed: (@Sendable (HostID, JSONValue?) async -> Void)?

    /// Device clients, with the notify flag they last reported, for sealing a need (R6).
    public func devicesForNotices() async -> [Device] {
        let flags = await router.notifyFlags()
        return await methods.allClients.compactMap { record in
            guard record.grant == .device, !record.publicKey.isEmpty else { return nil }
            let kind: Device.Kind = switch record.kind {
            case .iPhone: .iPhone
            case .iPad: .iPad
            case .mac, .unknown: .unknown
            }
            return Device(id: record.id, publicKey: record.publicKey, name: record.name, kind: kind,
                          announcedAt: record.paired, lastSeenAt: record.lastSeen,
                          mayNotify: flags[record.id] ?? record.mayNotify)
        }
    }

    /// A phone or iPad the bridge let in, on the direct link or through the relay (058,
    /// US4): a client of the router like any other, with the grant the control plane
    /// keeps for it — a device's until somebody says otherwise in Settings. Returns the
    /// device's end; what it writes is the client wire, or today's bare lines, which go
    /// to this Mac's host.
    public func attachDevice(_ id: UUID, name: String, kind: ClientRecord.Kind) async -> any LineTransport {
        var record = await methods.client(id)
            ?? ClientRecord(id: id, name: name, kind: kind, publicKey: Data(), grant: .device, paired: Date())
        record.name = name
        try? await methods.admit(record)
        let (ours, theirs) = PairedTransport.pair()
        await router.attachClient(await methods.client(id) ?? record, transport: ours)
        return theirs
    }

    /// A client forgotten in Settings: the bridge forgets it on this Mac's host too, so
    /// its key stops opening the direct link and the relay (FR-008).
    public var onClientForgotten: (@Sendable (UUID) async -> Void)?
    private var knownClients: Set<UUID> = []

    func clientsChanged(_ now: [ClientRecord]) async {
        let ids = Set(now.map(\.id))
        let gone = knownClients.subtracting(ids)
        knownClients = ids
        guard let onClientForgotten else { return }
        for id in gone { await onClientForgotten(id) }
    }

    /// This Mac's window: an operator, because only the app is `control` by signature.
    private func clientArrived(_ transport: FDTransport, role: ConnectionRole, peer: Int32?) async {
        guard role == .control else {
            DaemonLog.shared.write("control: refused a client socket connection from pid \(peer.map(String.init) ?? "?") (\(role.rawValue))")
            transport.close()
            return
        }
        // The window on this Mac is the one client with no key: it came in by signature.
        // Named for the Mac, as every other client sees it.
        let existing = await methods.allClients.first { $0.kind == .mac && $0.publicKey.isEmpty }
        var record = existing ?? ClientRecord(id: UUID(), name: Self.windowName, kind: .mac, publicKey: Data(),
                                              grant: .operator, paired: Date())
        record.name = Host.current().localizedName ?? Self.windowName
        try? await methods.admit(record)
        await router.attachClient(await methods.client(record.id) ?? record, transport: transport)
    }

    /// This Mac's host. Its first line is `host/hello`, which says which host it is.
    private func hostArrived(_ transport: FDTransport, role: ConnectionRole, peer: Int32?) async {
        guard role == .agent || role == .control else {
            DaemonLog.shared.write("control: refused a host socket connection from pid \(peer.map(String.init) ?? "?") (\(role.rawValue))")
            transport.close()
            return
        }
        await hostArrived(transport, as: nil)
    }

    /// A host's uplink, from the local socket (which host it is, it says) or from the
    /// network (its key has said already, and `known` is that host: what it says is
    /// not heard).
    func hostArrived(_ transport: any LineTransport, as known: HostID?) async {
        let rest = Remainder(transport)
        guard let first = await rest.first(),
              case .message(0, let message)? = try? ControlWire.readHost(first),
              case .request(let id, DaemonAPI.Method.hostHello, let params)? = try? JSONRPCCodec.decode(line: message),
              let hello = try? params?.decode(DaemonAPI.HostHello.self),
              let host = known ?? hello.host, ControlWire.isHostID(host.rawValue) else {
            DaemonLog.shared.write("control: a host connected without saying which it is; closing it")
            transport.close()
            return
        }
        await router.attachHost(host, transport: rest)
        let reply: JSONRPCMessage
        do {
            reply = .success(id: id, result: try await methods.hostSaid(host, method: DaemonAPI.Method.hostHello, params: params))
        } catch let error as JSONRPCError {
            reply = .failure(id: id, error: error)
        } catch {
            reply = .failure(id: id, error: .internalError("\(error)"))
        }
        if let line = try? JSONRPCCodec.encode(reply) { try? rest.write(line: ControlWire.channel(0, message: line)) }
        DaemonLog.shared.write("control: host \(host) connected (\(hello.platform), \(hello.version))")
    }

    /// A transport whose first line has been read here and whose rest is read by the
    /// router: a stream is read by one reader, so this is that reader for both.
    final class Remainder: LineTransport, @unchecked Sendable {
        private let base: any LineTransport
        private let stream: AsyncThrowingStream<String, any Error>
        private let continuation: AsyncThrowingStream<String, any Error>.Continuation
        private let firstLine: AsyncStream<String?>
        private let firstContinuation: AsyncStream<String?>.Continuation

        init(_ base: any LineTransport) {
            self.base = base
            var c: AsyncThrowingStream<String, any Error>.Continuation!
            stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
            continuation = c
            var f: AsyncStream<String?>.Continuation!
            firstLine = AsyncStream { f = $0 }
            firstContinuation = f
            Task { [continuation, firstContinuation] in
                var sawFirst = false
                do {
                    for try await line in base.lines() {
                        if sawFirst { continuation.yield(line) } else {
                            sawFirst = true
                            firstContinuation.yield(line)
                            firstContinuation.finish()
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                if !sawFirst { firstContinuation.yield(nil); firstContinuation.finish() }
            }
        }

        func first() async -> String? {
            for await line in firstLine { return line }
            return nil
        }

        func write(line: String) throws { try base.write(line: line) }
        func lines() -> AsyncThrowingStream<String, any Error> { stream }
        func close() { base.close() }
    }
}

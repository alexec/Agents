import AgentsKitCore
import ControlDial
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// The control plane as a service (058): a store, the router, the methods it answers
/// itself, and a WebSocket server every client and host connects to. One copy for now;
/// several copies over one store come with the copies work (US3).
public final class ControlService: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var store: any ControlStore
        /// The control plane's P-256 private key: raw, 32 bytes. Never in the store.
        public var privateKey: Data
        /// The one address clients and hosts are given (R8).
        public var url: URL
        /// The pin of this copy's certificate, when it is not publicly trusted.
        public var pin: String?
        /// This copy terminates TLS itself with this, or nil behind a load balancer.
        public var tls: NIOSSLContext?
        public var bind: String
        public var port: Int
        public var name: String
        public var machineID: String
        public var version: String

        public init(store: any ControlStore, privateKey: Data, url: URL, pin: String? = nil, tls: NIOSSLContext? = nil,
                    bind: String = "0.0.0.0", port: Int, name: String, machineID: String = "", version: String = ControlPlaneKit.version) {
            self.store = store
            self.privateKey = privateKey
            self.url = url
            self.pin = pin
            self.tls = tls
            self.bind = bind
            self.port = port
            self.name = name
            self.machineID = machineID
            self.version = version
        }
    }

    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    public let configuration: Configuration
    public let records: ControlRecords
    public let methods: ControlMethods
    public let router: ControlRouter
    public let codes: ControlCodes
    public let copyID = String(UUID().uuidString.prefix(8)).lowercased()
    let publicKey: Data
    let origin: String
    private var server: (any Channel)?
    private var refresher: Task<Void, Never>?
    private let readiness = Readiness()
    private let sockets = Sockets()

    public init(_ configuration: Configuration) throws {
        self.configuration = configuration
        publicKey = try ControlAgreement.publicKey(privateKey: configuration.privateKey)
        guard let origin = ControlAuth.origin(configuration.url) else {
            throw Failure("\(configuration.url) is not an address clients can dial")
        }
        self.origin = origin
        records = ControlRecords(store: configuration.store)
        let settings = ControlSettings(name: configuration.name, machineID: configuration.machineID)
        methods = ControlMethods(records: records, settings: settings, version: configuration.version,
                                 port: configuration.port)
        router = ControlRouter(handler: methods)
        codes = ControlCodes(store: configuration.store, privateKey: configuration.privateKey,
                             publicKey: publicKey, url: configuration.url.absoluteString, pin: configuration.pin,
                             name: configuration.name)
    }

    /// Opens the store, refuses one that ignores conditions or belongs to another key,
    /// and starts listening. Returns the port bound (the configured one, or the one the
    /// system chose for 0).
    @discardableResult
    public func start() async throws -> Int {
        let store = configuration.store
        do {
            try await store.probe(copy: copyID)
        } catch let error as StoreError {
            throw Failure("the store can't be used: \(error)")
        }
        let configuration = self.configuration
        let publicKey = self.publicKey
        let made = try await records.settings {
            ControlSettings(name: configuration.name, machineID: configuration.machineID,
                            url: configuration.url.absoluteString, pin: configuration.pin, controlKey: publicKey)
        }
        if let kept = made.controlKey, kept != publicKey {
            throw Failure("this store belongs to a control plane with another key; give it that key, or another store")
        }
        _ = try await records.changeSettings {
            $0.url = configuration.url.absoluteString
            $0.pin = configuration.pin
            $0.controlKey = publicKey
        }
        try await methods.refresh()
        for host in await methods.knownHosts { await router.know(host) }
        await router.setHomeHost(await methods.controlSettings.homeHost)
        await methods.attach(router)
        let codes = self.codes
        await methods.setHooks(ControlMethods.Hooks(
            startPairing: { grant in try JSONValue.encoding(try await codes.issue(.client(grant))) },
            startEnroll: { try JSONValue.encoding(try await codes.issue(.host)) }))
        await readiness.set(true)

        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self, readiness] channel in
                let service = self
                return ControlWebSocketServer.configure(channel, tls: configuration.tls, plain: { head in
                    switch head.uri.split(separator: "?").first {
                    case "/healthz": (.ok, "ok\n")
                    case "/readyz": readiness.now ? (.ok, "ready\n") : (.serviceUnavailable, "the store can't be reached\n")
                    default: (.notFound, "not here\n")
                    }
                }, opened: { socket in
                    guard let service else { return socket.close() }
                    service.sockets.add(socket)
                    Task { await service.accept(socket) }
                })
            }
        let channel = try await bootstrap.bind(host: configuration.bind, port: configuration.port).get()
        server = channel
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.refresh()
            }
        }
        let port = channel.localAddress?.port ?? configuration.port
        log("listening on \(configuration.bind):\(port) for \(configuration.url.absoluteString)")
        return port
    }

    /// Stops listening and drops every connection, as a copy that stopped would: its
    /// clients and hosts redial another copy, or this one when it is back.
    public func stop() async {
        refresher?.cancel()
        try? await server?.close()
        server = nil
        sockets.closeAll()
    }

    /// The backstop for changes another copy made (R4), and the readiness probe's answer.
    func refresh() async {
        do {
            try await methods.refresh()
            for host in await methods.knownHosts { await router.know(host) }
            await readiness.set(true)
        } catch {
            await readiness.set(false)
            log("store: \(error)")
        }
    }

    // MARK: A socket

    /// The server's side of the key exchange, then the socket goes where its identity
    /// says: a client to the router, a host's uplink to the router, a code holder to a
    /// one-time announce.
    func accept(_ socket: WebSocketLineTransport) async {
        let reader = PrefixReader(socket)
        let serverNonce = ControlAuth.nonce()
        let hello = ControlAuth.Hello(name: configuration.name, control: ControlCode.base64url(publicKey),
                                      nonce: ControlCode.base64url(serverNonce), copy: copyID)
        do {
            try reader.write(line: ControlAuth.Message.hello(hello).line)
            guard let line = try await reader.next(within: 15), case .auth(let auth)? = ControlAuth.Message(line: line) else {
                throw ControlAuth.Refusal(.badMessage)
            }
            var admitted: Admitted?
            let (identity, mac) = try await ControlAuth.verify(auth, serverNonce: serverNonce, origin: origin) { identity in
                let (key, who) = try await self.key(for: identity)
                admitted = who
                return key
            }
            guard let admitted else { throw ControlAuth.Refusal(.unknown) }
            try reader.write(line: ControlAuth.Message.ok(ControlAuth.OK(
                mac: ControlCode.base64url(mac), grant: admitted.client?.grant, host: admitted.host)).line)
            switch identity {
            case .client:
                guard let client = admitted.client else { throw ControlAuth.Refusal(.unknown) }
                await router.attachClient(client, transport: reader)
                try? await methods.admit(client)
                log("client \(client.name) (\(client.grant.rawValue)) connected from \(socket.remote)")
            case .host(let host):
                await hostArrived(host, reader)
            case .pairing(let id), .enrolling(let id):
                await announce(reader, code: id)
            case .copy:
                // Peer links between copies come with US3.
                reader.close()
            }
        } catch let refusal as ControlAuth.Refusal {
            try? reader.write(line: ControlAuth.Message.refused(refusal.reason).line)
            log("refused a connection from \(socket.remote): \(refusal.reason.rawValue)")
            reader.close()
        } catch {
            log("a connection from \(socket.remote) ended: \(error)")
            reader.close()
        }
    }

    struct Admitted: Sendable {
        var client: ClientRecord?
        var host: HostID?
        var code: ControlCodes.Stored?
    }

    /// The key an identity proves, and what it is admitted as.
    func key(for identity: ControlAuth.Identity) async throws -> (Data, Admitted) {
        let privateKey = configuration.privateKey
        switch identity {
        case .client(let id):
            guard let client = await records.client(id), !client.publicKey.isEmpty else { throw ControlAuth.Refusal(.unknown) }
            return (try ControlAuth.clientKey(privateKey: privateKey, peer: client.publicKey, client: id),
                    Admitted(client: client))
        case .host(let id):
            guard let host = await records.host(id), let key = host.publicKey else { throw ControlAuth.Refusal(.unknown) }
            return (try ControlAuth.hostKey(privateKey: privateKey, peer: key, host: id), Admitted(host: id))
        case .pairing(let id), .enrolling(let id):
            let stored = try await codes.stored(id)
            let wanted: Bool = if case .enrolling = identity { stored.purpose == .host } else { stored.purpose != .host }
            guard wanted, let secret = ControlAuth.codeSecret(controlPrivateKey: privateKey, id: id) else {
                throw ControlAuth.Refusal(.unknown)
            }
            return (ControlAuth.codeKey(secret: secret), Admitted(code: stored))
        case .copy:
            return (ControlAuth.copyKey(controlPrivateKey: privateKey), Admitted())
        }
    }

    /// A host's uplink: its first line is `host/hello` on channel 0 (kept from the first
    /// build), then the router reads it.
    func hostArrived(_ host: HostID, _ reader: PrefixReader) async {
        guard let first = try? await reader.next(within: 15),
              case .message(0, let message)? = try? ControlWire.readHost(first),
              case .request(let id, DaemonAPI.Method.hostHello, let params)? = try? JSONRPCCodec.decode(line: message) else {
            log("host \(host) connected without saying hello; closing it")
            reader.close()
            return
        }
        await router.attachHost(host, transport: reader)
        let reply: JSONRPCMessage
        do {
            reply = .success(id: id, result: try await methods.hostSaid(host, method: DaemonAPI.Method.hostHello, params: params))
        } catch let error as JSONRPCError {
            reply = .failure(id: id, error: error)
        } catch let error as StoreError {
            reply = .failure(id: id, error: error.rpcError)
        } catch {
            reply = .failure(id: id, error: .internalError("\(error)"))
        }
        if let line = try? JSONRPCCodec.encode(reply) { try? reader.write(line: ControlWire.channel(0, message: line)) }
        log("host \(host) connected")
    }

    /// Someone holding a code says who they are, once, and hangs up (wire.md).
    func announce(_ reader: PrefixReader, code id: String) async {
        defer { reader.close() }
        guard let line = try? await reader.next(within: 15),
              case .request(let request, let method, let params)? = try? JSONRPCCodec.decode(line: line) else { return }
        let reply: JSONRPCMessage
        do {
            let stored = try await codes.stored(id)
            let admitted: DaemonAPI.Admitted
            switch (stored.purpose, method) {
            case (.client, DaemonAPI.Method.clientsAnnounce):
                guard let announce = try? params?.decode(DaemonAPI.ClientAnnounce.self), !announce.publicKey.isEmpty else {
                    throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Say who you are.")
                }
                let grant = stored.grant ?? .device
                try await codes.spend(id)
                try await methods.admit(ClientRecord(id: announce.id, name: announce.name, kind: announce.kind,
                                                     publicKey: announce.publicKey, grant: grant, paired: Date()))
                admitted = DaemonAPI.Admitted(client: announce.id, grant: grant)
                log("\(announce.name) paired as \(grant.rawValue)")
            case (.host, DaemonAPI.Method.hostsAnnounce):
                guard let announce = try? params?.decode(DaemonAPI.HostAnnounce.self) else {
                    throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Say which host you are.")
                }
                try await codes.spend(id)
                let host = HostID.make()
                try await methods.enroll(HostRecord(id: host, name: announce.name, publicKey: announce.publicKey,
                                                    platform: announce.platform, version: announce.version,
                                                    machineID: announce.machineID))
                await router.know(host)
                admitted = DaemonAPI.Admitted(host: host)
                log("host \(announce.name) enrolled as \(host)")
            default:
                throw JSONRPCError(code: DaemonAPI.Failure.notPermitted, message: "That code is not for \(method).")
            }
            reply = .success(id: request, result: try JSONValue.encoding(admitted))
        } catch let error as JSONRPCError {
            reply = .failure(id: request, error: error)
        } catch let error as StoreError {
            reply = .failure(id: request, error: error.rpcError)
        } catch let refusal as ControlAuth.Refusal {
            reply = .failure(id: request, error: JSONRPCError(code: DaemonAPI.Failure.notPermitted,
                                                               message: "That code can't be used: \(refusal.reason.rawValue)."))
        } catch {
            reply = .failure(id: request, error: .internalError("\(error)"))
        }
        if let line = try? JSONRPCCodec.encode(reply) { try? reader.write(line: line) }
        // Give the reply time to leave before the socket closes.
        try? await Task.sleep(for: .milliseconds(200))
    }

    func log(_ line: String) {
        FileHandle.standardError.write(Data("agents-control[\(copyID)]: \(line)\n".utf8))
    }
}

/// Every WebSocket this copy has open, so stopping can close them.
final class Sockets: @unchecked Sendable {
    private let lock = NSLock()
    private var open: [ObjectIdentifier: WebSocketLineTransport] = [:]

    func add(_ socket: WebSocketLineTransport) {
        lock.withLock { open[ObjectIdentifier(socket)] = socket }
        socket.whenClosed { [weak self] in _ = self?.lock.withLock { self?.open.removeValue(forKey: ObjectIdentifier(socket)) } }
    }

    func closeAll() {
        for socket in lock.withLock({ Array(open.values) }) { socket.close() }
    }
}

/// Whether the store answered lately: `/readyz`. Read on an event loop, so it is a lock,
/// not an actor.
final class Readiness: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    var now: Bool { lock.withLock { ready } }
    func set(_ value: Bool) async { lock.withLock { ready = value } }
}

/// Pairing and enrolment codes (data-model.md "Code"): stored by id, with nothing
/// secret, used once at any copy.
public actor ControlCodes {
    public enum Purpose: String, Codable, Sendable {
        case client, host
    }

    public struct Stored: Codable, Sendable {
        public var purpose: Purpose
        public var grant: Grant?
        public var owner: PersonID?
        public var expires: Date
    }

    static func key(_ id: String) -> String { "v1/codes/\(id).json" }
    static func spentKey(_ id: String) -> String { "v1/codes/\(id).spent" }

    let store: any ControlStore
    let privateKey: Data
    let publicKey: Data
    let url: String
    let pin: String?
    let name: String

    init(store: any ControlStore, privateKey: Data, publicKey: Data, url: String, pin: String?, name: String) {
        self.store = store
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.url = url
        self.pin = pin
        self.name = name
    }

    /// A new code, written to the store, for `clients/startPairing` or `hosts/startEnroll`
    /// or `agents-control code`.
    public func issue(_ purpose: ControlCode.Purpose, lifetime: TimeInterval = ControlCode.lifetime)
        async throws -> DaemonAPI.ControlCodeShown {
        let (id, secret) = ControlAuth.makeCodeSecret(controlPrivateKey: privateKey)
        let expires = Date().addingTimeInterval(lifetime)
        let stored: Stored = switch purpose {
        case .client(let grant): Stored(purpose: .client, grant: grant, expires: expires)
        case .host: Stored(purpose: .host, expires: expires)
        }
        _ = try await store.put(Self.key(id), try ControlRecords.encoder.encode(stored), when: .absent)
        let code = ControlCode(purpose: purpose, controlKey: publicKey, secret: secret, url: url, pin: pin, name: name)
        return DaemonAPI.ControlCodeShown(text: code.text, expires: expires)
    }

    /// A code as stored, refused if unknown, expired or spent.
    public func stored(_ id: String) async throws -> Stored {
        guard let object = try await store.get(Self.key(id)),
              let stored = try? ControlRecords.decoder.decode(Stored.self, from: object.data) else {
            throw ControlAuth.Refusal(.unknown)
        }
        guard stored.expires > Date() else { throw ControlAuth.Refusal(.expired) }
        if try await store.get(Self.spentKey(id)) != nil { throw ControlAuth.Refusal(.spent) }
        return stored
    }

    /// Uses a code: the first copy to write its `.spent` wins (rule on codes, US3-3).
    public func spend(_ id: String) async throws {
        do {
            _ = try await store.put(Self.spentKey(id), Data("{}".utf8), when: .absent)
        } catch StoreError.conflict {
            throw ControlAuth.Refusal(.spent)
        }
    }
}

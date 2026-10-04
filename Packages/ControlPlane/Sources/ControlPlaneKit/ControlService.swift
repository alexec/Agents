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
        /// Where other copies reach this one. Nil for a single copy (Agents Host's), which
        /// takes leases all the same but links with nobody.
        public var peerURL: URL?
        /// How often a copy beats and looks for the others; shorter in tests.
        public var copyBeat: TimeInterval = CopyRecord.beatEvery
        /// Start empty, for a handover to fill (R16): no settings made, every member
        /// refused, only the copy handing over answered, until it says take over.
        public var receive = false
        /// Start forwarding again if this copy was forwarding when it stopped (#61 P4).
        /// Agents Host turns it off once its own copy should serve again.
        public var resumeForwarding = true

        /// The web remote's loopback listener (071): the built app and the port, or nil
        /// for none, which is the container's default.
        public var web: Web?
        /// Where each log line goes, already prefixed with this copy; standard error unless a
        /// test listens (071 FR-033: no line may hold a code, a key, a MAC or a message).
        public var log: (@Sendable (String) -> Void)?
        /// Told whenever the web remote's listener starts or fails to (071 R3): `serve --home`
        /// writes it beside the log for Agents Host.
        public var webChanged: (@Sendable (DaemonAPI.WebRemoteStatus) -> Void)?
        /// How the host on this Mac says its join stands (#113): `serve --host-root` reads
        /// its `control-join.json`, for `control/status`.
        public var thisMacHost: (@Sendable () -> DaemonAPI.HostJoinStatus?)?

        public struct Web: Sendable {
            /// `Web/dist`, with its MANIFEST.
            public var folder: URL
            /// 0 lets the system choose (tests); Agents Host's copy uses `Loopback.defaultPort`.
            public var port: Int
            public init(folder: URL, port: Int) {
                self.folder = folder
                self.port = port
            }
        }

        public init(store: any ControlStore, privateKey: Data, url: URL, pin: String? = nil, tls: NIOSSLContext? = nil,
                    bind: String = "0.0.0.0", port: Int, name: String, machineID: String = "", version: String = ControlPlaneKit.version,
                    peerURL: URL? = nil, receive: Bool = false) {
            self.peerURL = peerURL
            self.receive = receive
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
    /// The origin peers dial, which the key exchange of a copy is bound to.
    let peerOrigin: String?
    public let leases: Leases
    public let mesh: CopyMesh?
    private var server: (any Channel)?
    private let loopback = LoopbackListener()
    /// The loopback listener's port once it is up, or nil (071).
    public var webPort: Int? { loopback.port == 0 ? nil : loopback.port }
    private var refresher: Task<Void, Never>?
    private let readiness = Readiness()
    let sockets = Sockets()
    /// What this copy has told its relay host for each need (T097).
    let desk = NoticeDesk()
    /// Where this copy is in a handover (R16): serving, receiving, frozen or forwarding.
    let phase: PhaseBox
    /// When a forwarding copy stops telling members where to go.
    let forwardingUntil = DateBox()

    public init(_ configuration: Configuration) throws {
        self.configuration = configuration
        phase = PhaseBox(configuration.receive ? .receiving : .serving)
        publicKey = try ControlAgreement.publicKey(privateKey: configuration.privateKey)
        guard let origin = ControlAuth.origin(configuration.url) else {
            throw Failure("\(configuration.url) is not an address clients can dial")
        }
        self.origin = origin
        peerOrigin = configuration.peerURL.flatMap(ControlAuth.origin)
        records = ControlRecords(store: configuration.store)
        let settings = ControlSettings(name: configuration.name, machineID: configuration.machineID)
        methods = ControlMethods(records: records, settings: settings, version: configuration.version,
                                 port: configuration.port)
        let router = ControlRouter(handler: methods)
        let leases = Leases(store: configuration.store, copy: copyID)
        self.router = router
        self.leases = leases
        let publicKey = self.publicKey
        let copy = copyID
        mesh = configuration.peerURL.map { url in
            CopyMesh(.init(copy: copy, peerURL: url, privateKey: configuration.privateKey, publicKey: publicKey,
                           beat: configuration.copyBeat, pin: configuration.pin),
                     store: configuration.store, router: router, leases: leases,
                     log: { [sink = configuration.log] line in
                         let line = "agents-control[\(copy)]: \(line)"
                         if let sink { sink(line) } else { FileHandle.standardError.write(Data((line + "\n").utf8)) }
                     })
        }
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
        if phase.now == .receiving, let object = try await store.get(ControlRecords.settingsKey) {
            // Started again after it took over (R16): it serves, as any copy would. A store
            // with records that it never took is a handover that didn't finish.
            let settings = try? ControlRecords.decoder.decode(ControlSettings.self, from: object.data)
            // Or it took over, then handed over again and forwards (#61, T129): its own
            // forwarding note says so, and it forwards again below.
            let forwarded = try await store.get(forwardingKey) != nil
            guard settings?.currentEndpoints.first?.url == configuration.url.absoluteString || forwarded else {
                throw Failure("this store holds records from a handover that didn't finish; empty it and receive again")
            }
            phase.set(.serving)
        }
        if phase.now == .receiving {
            // Ready for the copy handing over, which may come through a load balancer.
            await readiness.set(true)
        } else {
            try await takeUp()
            try await resumeForwardingIfMarked()
        }
        let configuration = self.configuration
        let servers = ServerFiles.folder()
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self, readiness] channel in
                let service = self
                return ControlWebSocketServer.configure(channel, tls: configuration.tls, reply: { head in
                    let path = head.uri.split(separator: "?").first.map(String.init) ?? ""
                    switch path {
                    case "/healthz": return PlainReply(.ok, text: "ok\n")
                    case "/readyz":
                        return readiness.now ? PlainReply(.ok, text: "ready\n")
                            : PlainReply(.serviceUnavailable, text: "the store can't be reached\n")
                    // A server installs itself from here (T070): the script, then the host.
                    case "/v1/install.sh":
                        return PlainReply(.ok, Data(HostInstallScript.text.utf8), contentType: "text/x-shellscript")
                    case let served where served.hasPrefix("/v1/servers/"):
                        guard let data = ServerFiles.read(String(served.dropFirst("/v1/servers/".count)), in: servers) else {
                            return PlainReply(.notFound, text: "this control plane has no such file\n")
                        }
                        return PlainReply(.ok, data)
                    default: return PlainReply(.notFound, text: "not here\n")
                    }
                }, opened: { socket in
                    guard let service else { return socket.close() }
                    service.sockets.add(socket)
                    Task { await service.accept(socket, arrival: .tls) }
                })
            }
        let channel = try await bootstrap.bind(host: configuration.bind, port: configuration.port).get()
        server = channel
        if let web = configuration.web { await startWeb(web) }
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.refresh()
            }
        }
        let port = channel.localAddress?.port ?? configuration.port
        log("listening on \(configuration.bind):\(port) for \(configuration.url.absoluteString)\(phase.now == .receiving ? ", receiving a handover" : "")")
        if phase.now != .receiving { await mesh?.start() }
        return port
    }

    /// The store's records taken up, and everything that runs on them: done at start, or
    /// when a receiving copy takes over at the end of a move (R16).
    func takeUp() async throws {
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
        await syncRelays()
        await methods.setThisMacHost(configuration.thisMacHost)
        await methods.attach(router)
        let codes = self.codes
        var hooks = ControlMethods.Hooks(
            startPairing: { browser in try JSONValue.encoding(try await codes.issue(.client, browser: browser)) },
            startEnroll: { try JSONValue.encoding(try await codes.issue(.host)) })
        hooks.changed = { [weak self] event in await self?.announce(event) }
        // hosts/install (T072): once over ssh with the key given, then the host is on its own.
        let install = HostInstall(codes: codes, servers: ServerFiles.folder()) { [router = self.router] name, step in
            await router.broadcastControl(DaemonAPI.Notification.controlInstallProgress,
                                          ["name": .string(name), "step": .string(step)])
        }
        hooks.install = { params in try await install.run(params) }
        // Notices (T097): a need goes to the relay host, wherever it is held.
        hooks.need = { [weak self] _, params in await self?.heard(params) }
        hooks.relayChanged = { [weak self] _ in await self?.syncRelays() }
        hooks.clientsChanged = { [weak self] _ in await self?.tellRelayDevices() }
        await methods.setHooks(hooks)
        await readiness.set(true)

        // Leases (T063): a host whose uplink ends here, or whose lease another copy took.
        let leases = self.leases, mesh = self.mesh, router = self.router
        await router.onLocalHostEnded { host in
            if let epoch = await leases.release(host) { await mesh?.released(host, epoch: epoch) }
        }
        await leases.onLost { [weak self] host, epoch in
            self?.log("another copy took \(host); closing its uplink here")
            await router.closeLocal(host)
            await mesh?.released(host, epoch: epoch)
        }
        await leases.start()
        // Copies (T064, T066).
        await router.onPresence { client, device, report in
            Task { await mesh?.broadcast(PeerWire.presence(client: client, device: device, report: report)) }
        }
        await mesh?.onEvent { [weak self] event in await self?.apply(event) }
        await mesh?.onNeed { [weak self] need in await self?.deliver(need, fromPeer: true) }
        await mesh?.onLinked { [weak self] _ in
            await self?.reconcile()
            // A copy that just linked hears how every client here reaches it (T080).
            guard let self else { return }
            for (client, relayed) in await self.router.linksHere() {
                await self.mesh?.broadcast(PeerWire.link(client: client, relayed: relayed))
            }
        }
        await router.onLinkChanged { client, relayed in
            Task { await mesh?.broadcast(PeerWire.link(client: client, relayed: relayed)) }
        }

    }

    /// Stops listening and drops every connection, as a copy that stopped would: its
    /// clients and hosts redial another copy, or this one when it is back.
    public func stop() async {
        refresher?.cancel()
        await leases.stop()
        await mesh?.stop()
        try? await server?.close()
        server = nil
        await loopback.stop()
        sockets.closeAll()
    }

    /// The backstop for changes another copy made (R4), and the readiness probe's answer.
    func refresh() async {
        guard phase.now != .receiving else { return }
        do {
            try await methods.refresh()
            for host in await methods.knownHosts { await router.know(host) }
            await readiness.set(true)
            await reconcile()
            await syncRelays()
        } catch {
            await readiness.set(false)
            log("store: \(error)")
        }
    }

    // MARK: Changes across copies (T066)

    /// A change made here: on every peer link first, then into `events/` for a copy that
    /// missed it.
    func announce(_ event: ControlEvent) async {
        await mesh?.broadcast(PeerWire.event(event))
        let millis = Int(event.at.timeIntervalSince1970 * 1000)
        let day = event.at.formatted(Date.ISO8601FormatStyle().year().month().day())
        let key = "v1/events/\(day)/\(String(format: "%013d", millis))-\(UUID().uuidString.prefix(8).lowercased()).json"
        _ = try? await configuration.store.put(key, try ControlRecords.encoder.encode(event), when: .absent)
    }

    /// A change another copy made: the records again, then its effect on sessions here.
    func apply(_ event: ControlEvent) async {
        try? await methods.refresh()
        switch event.kind {
        case .clientForgotten:
            if let id = UUID(uuidString: event.subject) { await router.forgetClient(id) }
        case .grantChanged:
            // From a copy older than #111. A grant changes nothing here.
            break
        case .hostRemoved:
            await router.forgetHost(HostID(rawValue: event.subject))
        case .clientPaired, .hostEnrolled, .hostMoved:
            for host in await methods.knownHosts { await router.know(host) }
        case .endpointsChanged:
            // Another copy announced where the control plane answers (R16): members here
            // reconnect, and their `ok` gives them the list.
            sockets.closeAll()
        }
        await syncRelays()
        log("applied \(event.kind.rawValue) \(event.subject) from another copy")
    }

    /// The backstop for an event missed: every session here is held to the records as
    /// they are now (R4, re-listed every 15 s and whenever a peer link comes up).
    func reconcile() async {
        for client in await router.connectedClients() where await methods.client(client) == nil {
            await router.forgetClient(client)
        }
        let known = Set(await methods.knownHosts)
        for host in await router.hostStates.keys where !known.contains(host) { await router.forgetHost(host) }
    }

    // MARK: The web remote's listener (071)

    /// Starts the loopback listener. A build that doesn't match its manifest, or a port
    /// that's taken, leaves it off and says so (071 R3): in the log, in `control/status`
    /// and to `Configuration.webChanged`; the TLS listener and hosts carry on.
    func startWeb(_ web: Configuration.Web) async {
        let status: DaemonAPI.WebRemoteStatus
        do {
            let files = try WebFiles.load(from: web.folder)
            do {
                let port = try await loopback.start(port: web.port, files: files, log: { [weak self] in self?.log($0) }) {
                    [weak self] socket, origin in
                    guard let self else { return socket.close() }
                    self.sockets.add(socket)
                    Task { await self.accept(socket, arrival: .loopback(origin: origin)) }
                }
                log("web: serving the web remote at \(Loopback.origin(port: port))")
                status = .init(port: port, served: true)
            } catch {
                log("web: port \(web.port) not bound (\(error)); not serving the web remote")
                let inUse = (error as? IOError)?.errnoCode == EADDRINUSE
                status = .init(port: web.port, served: false,
                               reason: inUse ? DaemonAPI.WebRemoteStatus.portInUse : DaemonAPI.WebRemoteStatus.failed,
                               detail: "\(error)")
            }
        } catch {
            log("web: not serving, \(error)")
            status = .init(port: web.port, served: false, reason: DaemonAPI.WebRemoteStatus.build, detail: "\(error)")
        }
        await methods.setWeb(status)
        configuration.webChanged?(status)
        await router.broadcastControl(DaemonAPI.Notification.controlWebChanged, (try? JSONValue.encoding(status)) ?? [:])
    }

    /// Tries the loopback listener again when it isn't serving (071 R3): Agents Host's
    /// *Try Again*, once whatever held the port has let it go. Nothing changes while it is.
    public func retryWeb() async {
        guard let web = configuration.web, await methods.web?.served != true else { return }
        await startWeb(web)
    }

    /// This Mac's host's join changed (#113): every window's Settings reads it again.
    public func thisMacHostChanged(_ status: DaemonAPI.HostJoinStatus?) async {
        await router.broadcastControl(DaemonAPI.Notification.controlThisMacHostChanged,
                                      (try? JSONValue.encoding(status)) ?? .null)
    }

    /// The web remote's listener as it stands, or nil when this copy wasn't asked to serve it.
    public var webStatus: DaemonAPI.WebRemoteStatus? { get async { await methods.web } }

    // MARK: A socket

    /// Every origin a member may have dialled: this copy's own, and each endpoint
    /// announced (R16), in that order and once each.
    static func origins(_ own: String, _ settings: ControlSettings) -> [String] {
        var seen: [String] = [own]
        for endpoint in settings.currentEndpoints {
            if let url = URL(string: endpoint.url), let origin = ControlAuth.origin(url), !seen.contains(origin) {
                seen.append(origin)
            }
        }
        return seen
    }

    /// Which listener a socket came in on. The exchange is bound to that listener's own
    /// origin, never to anything the peer says (071, FR-006).
    enum Arrival: Equatable {
        case tls
        /// The web remote's loopback listener: browsers only.
        case loopback(origin: String)
    }

    /// The server's side of the key exchange, then the socket goes where its identity
    /// says: a client to the router, a host's uplink to the router, a code holder to a
    /// one-time announce.
    func accept(_ socket: WebSocketLineTransport, arrival: Arrival) async {
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
            // A peer copy dials the address copies reach each other at, and proves that.
            // Anyone else may have dialled any place the control plane answers (R16). On the
            // loopback listener only a browser or its code may prove anything, and only to
            // that listener's own origin (071).
            let settings = await methods.controlSettings
            let bound: [String]
            switch arrival {
            case .tls:
                let peerCopy = auth.id.hasPrefix("x:") && !auth.id.hasPrefix("x:" + Handover.prefix)
                bound = peerCopy ? [peerOrigin ?? origin] : Self.origins(origin, settings)
            case .loopback(let web):
                guard auth.id.hasPrefix("c:") || auth.id.hasPrefix("p:") else { throw ControlAuth.Refusal(.unknown) }
                bound = [web]
            }
            let (identity, mac) = try await ControlAuth.verify(auth, serverNonce: serverNonce, origins: bound) { identity in
                let (key, who) = try await self.key(for: identity)
                admitted = who
                return key
            }
            guard let admitted else { throw ControlAuth.Refusal(.unknown) }
            // In a handover (R16): a receiving copy answers only the copy filling it, and
            // no code is used while records can't be written.
            switch (phase.now, identity) {
            case (.receiving, .copy): break
            // Being filled, so its records are not whole yet: not a verdict on anyone (#81).
            case (.receiving, _): throw ControlAuth.Refusal(.unavailable)
            case (.frozen, .pairing), (.frozen, .enrolling), (.forwarding, .pairing), (.forwarding, .enrolling):
                throw ControlAuth.Refusal(.unknown)
            case (.forwarding, .client), (.forwarding, .host):
                // Forwarding ended (30 days at most): anyone still to hear pairs again.
                if let until = forwardingUntil.now, until < Date() { throw ControlAuth.Refusal(.unknown) }
            default: break
            }
            // A browser's key works only through the loopback listener, and nothing else's
            // does there (071).
            if let client = admitted.client, (client.kind == .browser) != (arrival != .tls) {
                throw ControlAuth.Refusal(.unknown)
            }
            // A device through `agents-relay` (T096): the exchange is its own, end to end,
            // and it says it came that way, for itself only.
            let relayed = auth.kind == "relay"
            if relayed {
                guard case .client(let id) = identity, auth.for == id.uuidString, admitted.client?.kind.isDevice == true else {
                    throw ControlAuth.Refusal(.badMessage)
                }
            }
            // Once a list has been announced, every member is given it, and says back
            // which it holds (R16).
            let announced = settings.epoch != nil
            try reader.write(line: ControlAuth.Message.ok(ControlAuth.OK(
                mac: ControlCode.base64url(mac), client: admitted.client != nil, host: admitted.host,
                relayed: relayed ? true : nil, endpoints: announced ? settings.currentEndpoints : nil,
                epoch: settings.epoch)).line)
            // A member that says an epoch keeps a list, and takes the one just given: it
            // now holds the newer of the two. One that says none can't follow a move.
            if let held = auth.epoch {
                let epoch = max(held, announced ? settings.epoch ?? 0 : 0)
                switch identity {
                case .client(let id): Task { await self.methods.noteEpoch(client: id, epoch) }
                case .host(let id): Task { await self.methods.noteEpoch(host: id, epoch) }
                default: break
                }
            }
            // A forwarding copy's `ok` gave the new list; that is all it has to say.
            if phase.now == .forwarding, case .client = identity { reader.close(); return }
            if phase.now == .forwarding, case .host = identity { reader.close(); return }
            switch identity {
            case .client:
                guard let client = admitted.client else { throw ControlAuth.Refusal(.unknown) }
                await router.attachClient(client, transport: reader, relayed: relayed)
                try? await methods.admit(client)
                log("client \(client.name) (\(client.kind.rawValue)) connected\(relayed ? " through the relay" : "") from \(socket.remote)")
            case .host(let host):
                await hostArrived(host, reader)
            case .pairing(let id), .enrolling(let id):
                await announce(reader, code: id, arrival: arrival)
            case .copy(let id) where id.hasPrefix(Handover.prefix):
                // Not a member: announcing or forwarding leaves it open.
                sockets.keepOpen(socket)
                await Handover.session(reader, service: self)
            case .copy(let id):
                guard let mesh else { throw ControlAuth.Refusal(.unknown) }
                await mesh.accepted(id, transport: reader)
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
            // Paired at another copy moments ago: this one reads the store again. A store
            // that cannot be read says so; "unknown" would have the device forget its
            // pairing over a hiccup (#81).
            if await records.client(id) == nil { try await readAgain() }
            // A browser hears it was forgotten, and deletes its key (071 FR-014).
            if await records.client(id) == nil, await records.wasForgotten(id) { throw ControlAuth.Refusal(.forgotten) }
            guard let client = await records.client(id), !client.publicKey.isEmpty else { throw ControlAuth.Refusal(.unknown) }
            return (try ControlAuth.clientKey(privateKey: privateKey, peer: client.publicKey, client: id),
                    Admitted(client: client))
        case .host(let id):
            if await records.host(id) == nil { try await readAgain() }
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

    /// The store read again for a member not in the records, or `unavailable` when it
    /// cannot be: not known yet is not the same as not a member.
    private func readAgain() async throws {
        do {
            try await methods.refresh()
        } catch {
            log("store: could not read it to admit a member: \(error)")
            throw ControlAuth.Refusal(.unavailable)
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
        // This copy holds the host now (T063): every peer reaches it through here.
        if let epoch = try? await leases.take(host) {
            await mesh?.holding(host, epoch: epoch)
        } else {
            log("the store would not give \(host)'s lease to this copy; serving it anyway")
        }
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
    func announce(_ reader: PrefixReader, code id: String, arrival: Arrival) async {
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
                // A browser pairs through the loopback listener, and only a browser does (071).
                guard (announce.kind == .browser) == (arrival != .tls) else {
                    throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Pair that kind of client elsewhere.")
                }
                // And with a code made for one, which is good nowhere else (R2). Refused before
                // it is spent, so the browser it was made for can still use it.
                guard (stored.browser == true) == (arrival != .tls) else {
                    throw JSONRPCError(code: JSONRPCError.invalidParams, message: stored.browser == true
                        ? "That code is for a browser on this Mac."
                        : "That code is for a window or a phone. Get one from Pair a Browser….")
                }
                let name = announce.kind == .browser ? Self.browserName(announce.name) : announce.name
                try await codes.spend(id)
                try await methods.admit(ClientRecord(id: announce.id, name: name, kind: announce.kind,
                                                     publicKey: announce.publicKey, paired: Date()))
                admitted = DaemonAPI.Admitted(client: announce.id)
                log("\(name) paired (\(announce.kind.rawValue))")
                // Known at every copy at once: the relay host may be held at another.
                await self.announce(ControlEvent(kind: .clientPaired, subject: announce.id.uuidString, at: Date(), by: "code"))
                Task { await self.tellRelayDevices() }
            case (.host, DaemonAPI.Method.hostsAnnounce):
                guard let announce = try? params?.decode(DaemonAPI.HostAnnounce.self) else {
                    throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Say which host you are.")
                }
                try await codes.spend(id)
                // The host on the control plane's own machine is its home host, `mac`, as
                // a moved set-up's is: the window's own client is that host (data-model.md).
                let macTaken = await records.host(.mac) != nil
                let home = !configuration.machineID.isEmpty && announce.machineID == configuration.machineID && !macTaken
                    && announce.relay != true
                let host = home ? HostID.mac : HostID.make()
                try await methods.enroll(HostRecord(id: host, name: announce.name, publicKey: announce.publicKey,
                                                    platform: announce.platform, version: announce.version,
                                                    machineID: announce.machineID, relay: announce.relay == true ? true : nil))
                if announce.relay == true { await router.setRelay(host, true) }
                // Every other copy knows it at once: a relay host must be given no channels
                // there either, and a host must be reachable before the next re-list.
                await self.announce(ControlEvent(kind: .hostEnrolled, subject: host.rawValue, at: Date(), by: "code"))
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
        if case .failure(_, let error) = reply { log("a \(method) with a code failed: \(error.message)") }
        if let line = try? JSONRPCCodec.encode(reply) { try? reader.write(line: line) }
        // Give the reply time to leave before the socket closes.
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// "Safari on Alex's MacBook": the page can't learn the Mac's name, and the loopback
    /// listener only ever runs on the Mac it names (071, FR-010).
    static func browserName(_ said: String) -> String {
        let product = String(said.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        #if os(macOS)
        let mac = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        let mac = ProcessInfo.processInfo.hostName
        #endif
        return "\(product.isEmpty ? "A browser" : product) on \(mac)"
    }

    // MARK: Relay hosts and notices (T096–T097)

    /// The router is held to the records: which hosts only relay. Then every relay host
    /// here hears the devices again.
    func syncRelays() async {
        for record in await records.hosts { await router.setRelay(record.id, record.relay) }
        await tellRelayDevices()
    }

    /// Every device client and its key, to each relay host whose uplink ends here: whom
    /// it may carry for (FR-008).
    func tellRelayDevices() async {
        let relays = await router.relaysHeldHere()
        guard !relays.isEmpty else { return }
        let devices = await methods.allClients.compactMap { record -> DaemonAPI.RelayDevices.Device? in
            // A browser has no mailbox to carry for (071), and a Mac's window no relay.
            guard record.kind.isDevice, !record.publicKey.isEmpty else { return nil }
            return .init(id: record.id, publicKey: record.publicKey)
        }
        guard let params = try? JSONValue.encoding(DaemonAPI.RelayDevices(devices: devices)) else { return }
        for relay in relays { await router.tell(relay, DaemonAPI.Method.relayDevices, params) }
    }

    /// A host's `attention/need` (R6): to the relay host if it is held here, otherwise
    /// to the other copies, one of which may hold it. With no relay host anywhere, a need
    /// reaches only the clients connected to its host, over their own channels.
    func heard(_ params: JSONValue?) async {
        guard let need = try? params?.decode(DaemonAPI.AttentionNeed.self) else { return }
        await deliver(need, fromPeer: false)
    }

    func deliver(_ need: DaemonAPI.AttentionNeed, fromPeer: Bool) async {
        guard let relay = await router.relayHeldHere() else {
            if !fromPeer { await mesh?.broadcast(PeerWire.need(need)) }
            return
        }
        let flags = await router.notifyFlags()
        let devices = await methods.allClients.compactMap { record -> Device? in
            guard record.kind.isDevice, !record.publicKey.isEmpty else { return nil }
            let kind: Device.Kind = switch record.kind {
            case .iPhone: .iPhone
            case .iPad: .iPad
            case .mac, .browser, .unknown: .unknown
            }
            return Device(id: record.id, publicKey: record.publicKey, name: record.name, kind: kind,
                          announcedAt: record.paired, lastSeenAt: record.lastSeen,
                          mayNotify: flags[record.id] ?? record.mayNotify)
        }
        let deliveries = await desk.heard(need, presences: await router.foldedPresences(), devices: devices)
        for delivery in deliveries {
            guard let params = try? JSONValue.encoding(delivery) else { continue }
            await router.tell(relay, DaemonAPI.Method.relayDeliver, params)
            log("notice: \(delivery.headline == nil ? "withdrew" : "sent") \(delivery.needID) for \(delivery.device) to relay \(relay)")
        }
    }

    func log(_ line: String) {
        let line = "agents-control[\(copyID)]: \(line)"
        if let sink = configuration.log { sink(line) } else { FileHandle.standardError.write(Data((line + "\n").utf8)) }
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

    /// Every socket open now, for measuring what each holds (#167).
    var all: [WebSocketLineTransport] { lock.withLock { Array(open.values) } }

    /// Left out of `closeAll`: a handover's own session.
    func keepOpen(_ socket: WebSocketLineTransport) {
        _ = lock.withLock { open.removeValue(forKey: ObjectIdentifier(socket)) }
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
        /// Made for a browser on this Mac (071 security review, R2): good only through the
        /// loopback listener, as any other client code is good only over TLS. A code read
        /// through a page that wasn't Agents' can't then pair a phone or a Mac elsewhere.
        public var browser: Bool?
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

    /// For `agents-control code`, which makes a code against the store with no copy running
    /// in its process.
    public static func forCommandLine(store: any ControlStore, privateKey: Data, url: String, pin: String?,
                                      name: String) -> ControlCodes {
        let publicKey = (try? ControlAgreement.publicKey(privateKey: privateKey)) ?? Data()
        return ControlCodes(store: store, privateKey: privateKey, publicKey: publicKey, url: url, pin: pin, name: name)
    }

    /// A new code, written to the store, for `clients/startPairing` or `hosts/startEnroll`
    /// or `agents-control code`.
    public func issue(_ purpose: ControlCode.Purpose, lifetime: TimeInterval = ControlCode.lifetime,
                      browser: Bool = false) async throws -> DaemonAPI.ControlCodeShown {
        let (id, secret) = ControlAuth.makeCodeSecret(controlPrivateKey: privateKey)
        let expires = Date().addingTimeInterval(lifetime)
        let stored: Stored = switch purpose {
        case .client: Stored(purpose: .client, browser: browser ? true : nil, expires: expires)
        case .host: Stored(purpose: .host, expires: expires)
        }
        _ = try await store.put(Self.key(id), try ControlRecords.encoder.encode(stored), when: .absent)
        let code = ControlCode(purpose: purpose, controlKey: publicKey, secret: secret, url: url, pin: pin, name: name)
        let command: String? = if case .host = purpose { HostInstallScript.command(url: url, pin: pin, code: code.text) } else { nil }
        return DaemonAPI.ControlCodeShown(text: code.text, expires: expires, command: command)
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

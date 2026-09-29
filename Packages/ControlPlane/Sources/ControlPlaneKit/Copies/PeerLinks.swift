import AgentsKitCore
import ControlDial
import Foundation

/// The copies of one control plane, and the links between them (058, US3, T064).
///
/// - Each copy writes `copies/<id>.json` every 10 s; one not heard from for 30 s is gone.
/// - Every pair of live copies has one WebSocket between them, dialled by the copy with the
///   smaller id and proved with identity `x:<id>`. Either end redials while both are there.
/// - A host is held by one copy (its lease). Every other copy reaches it through a stream on
///   the link to the holder (`ProxyUplink`), which its router treats as the host's uplink.
/// - Changes and presence go out on every link.
public actor CopyMesh {
    public struct Configuration: Sendable {
        public var copy: String
        /// Where other copies reach this one: `http://cp1:8791` inside a deployment.
        public var peerURL: URL
        public var privateKey: Data
        public var publicKey: Data
        public var beat: TimeInterval
        public init(copy: String, peerURL: URL, privateKey: Data, publicKey: Data, beat: TimeInterval = CopyRecord.beatEvery) {
            self.copy = copy
            self.peerURL = peerURL
            self.privateKey = privateKey
            self.publicKey = publicKey
            self.beat = beat
        }
    }

    final class Link: @unchecked Sendable {
        let peer: String
        let transport: any LineTransport
        let generation = UUID()
        init(peer: String, transport: any LineTransport) {
            self.peer = peer
            self.transport = transport
        }
        func send(_ line: String) { try? transport.write(line: line) }
    }

    let configuration: Configuration
    let store: any ControlStore
    let router: ControlRouter
    let leases: Leases
    let started = Date()
    private var links: [String: Link] = [:]
    private var dialling: Set<String> = []
    /// Streams this copy carries to hosts other copies hold, by host.
    private var proxies: [HostID: ProxyUplink] = [:]
    private var ticker: Task<Void, Never>?
    /// A change from another copy, for the service to apply.
    private var applyEvent: (@Sendable (ControlEvent) async -> Void)?
    /// A link came up: a chance to catch up on changes missed while it was down.
    private var linked: (@Sendable (String) async -> Void)?
    let log: @Sendable (String) -> Void

    public init(_ configuration: Configuration, store: any ControlStore, router: ControlRouter, leases: Leases,
                log: @escaping @Sendable (String) -> Void) {
        self.configuration = configuration
        self.store = store
        self.router = router
        self.leases = leases
        self.log = log
    }

    public func onEvent(_ apply: @escaping @Sendable (ControlEvent) async -> Void) { applyEvent = apply }
    public func onLinked(_ linked: @escaping @Sendable (String) async -> Void) { self.linked = linked }

    static func key(_ copy: String) -> String { "v1/copies/\(copy).json" }

    public var peers: [String] { Array(links.keys).sorted() }

    // MARK: Running

    public func start() async {
        await tick()
        ticker = Task { [weak self, beat = configuration.beat] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(beat))
                await self?.tick()
            }
        }
    }

    public func stop() async {
        ticker?.cancel()
        ticker = nil
        try? await store.delete(Self.key(configuration.copy))
        for link in links.values { link.transport.close() }
        links = [:]
        for proxy in proxies.values { proxy.finish() }
        proxies = [:]
    }

    /// The heartbeat, a look at who else is there, and a look for hosts nobody here reaches.
    func tick() async {
        let record = CopyRecord(id: configuration.copy, peerURL: configuration.peerURL.absoluteString,
                                started: started, heartbeat: Date())
        _ = try? await store.put(Self.key(configuration.copy), try ControlRecords.encoder.encode(record), when: .always)
        guard let listed = try? await store.list(prefix: "v1/copies/") else { return }
        var live: [String: CopyRecord] = [:]
        for entry in listed {
            guard let object = try? await store.get(entry.key),
                  let copy = try? ControlRecords.decoder.decode(CopyRecord.self, from: object.data) else { continue }
            if Date().timeIntervalSince(copy.heartbeat) > CopyRecord.goneAfter {
                // Gone: any copy tidies its record away.
                try? await store.delete(entry.key)
                continue
            }
            if copy.id != configuration.copy { live[copy.id] = copy }
        }
        for (id, copy) in live where links[id] == nil && !dialling.contains(id) && configuration.copy < id {
            guard let url = URL(string: copy.peerURL) else { continue }
            dialling.insert(id)
            Task { await self.dial(id, url) }
        }
        await findHosts()
    }

    private func dial(_ id: String, _ url: URL) async {
        defer { dialling.remove(id) }
        let credentials = ControlAuth.Credentials(identity: .copy(configuration.copy),
                                                  key: ControlAuth.copyKey(controlPrivateKey: configuration.privateKey),
                                                  kind: "copy", controlKey: configuration.publicKey)
        do {
            let reader = try await ControlJoin.dial(url, pin: nil, as: credentials)
            await linkUp(id, transport: reader)
        } catch {
            log("could not reach copy \(id) at \(url.absoluteString): \(error)")
        }
    }

    /// A peer that dialled this copy and proved it is one of ours.
    public func accepted(_ id: String, transport: any LineTransport) async {
        await linkUp(id, transport: transport)
    }

    private func linkUp(_ id: String, transport: any LineTransport) async {
        if let old = links[id] { old.transport.close() }
        let link = Link(peer: id, transport: transport)
        links[id] = link
        await router.setPeer(id) { [link] line in link.send(line) }
        log("linked with copy \(id)")
        // Say which hosts are held here, so the peer reaches them through this link.
        for host in await router.hostStates.keys where await router.holds(host) {
            link.send(PeerWire.host(host, online: true, epoch: await leases.epoch(of: host) ?? 0))
        }
        Task { await self.read(link) }
        await linked?(id)
    }

    private func read(_ link: Link) async {
        do {
            for try await line in link.transport.lines() {
                guard let frame = PeerWire.read(line) else { continue }
                await received(frame, on: link)
            }
        } catch {}
        await linkDown(link)
    }

    private func linkDown(_ link: Link) async {
        guard links[link.peer]?.generation == link.generation else { return }
        links[link.peer] = nil
        await router.dropPeer(link.peer)
        for (host, proxy) in proxies where proxy.peer == link.peer {
            proxies[host] = nil
            proxy.finish()
        }
        log("lost the link with copy \(link.peer)")
    }

    // MARK: What a peer says

    private func received(_ frame: PeerWire.Frame, on link: Link) async {
        switch frame {
        case .stream(let host, let hostFrame):
            if await router.holds(host) {
                // The peer carries a client of its own to a host held here (T065).
                switch hostFrame {
                case .open(let channel, let open): await router.openFromPeer(link.peer, host: host, channel: channel, open)
                case .message(let channel, let message): await router.fromPeer(link.peer, host: host, channel: channel, message: message)
                case .close(let channel): await router.closeFromPeer(link.peer, host: host, channel: channel)
                }
            } else if let proxy = proxies[host], proxy.peer == link.peer {
                // The holder answering on this copy's stream.
                switch hostFrame {
                case .message(let channel, let message): proxy.deliver(ControlWire.channel(channel, message: message))
                case .close(let channel): proxy.deliver(ControlWire.close(channel))
                case .open: break
                }
            }
        case .gone(let host, _):
            if let proxy = proxies[host], proxy.peer == link.peer {
                proxies[host] = nil
                proxy.finish()
            }
            // Whoever holds it now says so; until then, look.
            Task { try? await Task.sleep(for: .seconds(1)); await self.find(host) }
        case .host(let host, let online, _):
            if online {
                await reach(host, through: link)
            } else if let proxy = proxies[host], proxy.peer == link.peer {
                proxies[host] = nil
                proxy.finish()
            }
        case .event(let event):
            await applyEvent?(event)
        case .presence(let client, let grant, let report):
            await router.notePeerPresence(client: client, grant: grant, report: report)
        }
    }

    /// Reach `host` through `link`: a stream the router takes for the host's uplink.
    private func reach(_ host: HostID, through link: Link) async {
        guard await !router.holds(host) else { return }
        if let proxy = proxies[host] {
            if proxy.peer == link.peer, proxy.isOpen { return }
            proxy.finish()
        }
        let proxy = ProxyUplink(host: host, peer: link.peer) { [link] line in link.send(line) }
        proxies[host] = proxy
        await router.attachHost(host, transport: proxy, local: false)
    }

    /// Hosts known but not reached here: whoever holds a live lease on one is asked.
    private func findHosts() async {
        for host in await router.hostStates.keys where await !router.reaches(host) {
            await find(host)
        }
    }

    private func find(_ host: HostID) async {
        guard await !router.reaches(host), let lease = await leases.holder(of: host),
              lease.copy != configuration.copy, let link = links[lease.copy] else { return }
        await reach(host, through: link)
    }

    // MARK: Telling the others

    public func broadcast(_ line: String) {
        for link in links.values { link.send(line) }
    }

    /// This copy took a host: every peer reaches it through here now.
    public func holding(_ host: HostID, epoch: Int) {
        if let proxy = proxies.removeValue(forKey: host) { proxy.finish() }
        broadcast(PeerWire.host(host, online: true, epoch: epoch))
    }

    /// This copy no longer holds a host.
    public func released(_ host: HostID, epoch: Int) {
        broadcast(PeerWire.gone(host, epoch: epoch))
    }
}

/// A host held by another copy, as this copy's router sees it: a stream on the peer link
/// that speaks the host wire (T061). What the router writes goes to the holder with the host
/// in front; what the holder sends back comes out as if from the host's own uplink.
final class ProxyUplink: LineTransport, @unchecked Sendable {
    let host: HostID
    let peer: String
    private let send: @Sendable (String) -> Void
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?
    private var stream: AsyncThrowingStream<String, any Error>?
    private var open = true
    /// Channels this copy opened at the holder, closed there when the router lets go.
    private var channels: Set<Int> = []

    init(host: HostID, peer: String, send: @escaping @Sendable (String) -> Void) {
        self.host = host
        self.peer = peer
        self.send = send
        var continuation: AsyncThrowingStream<String, any Error>.Continuation?
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    var isOpen: Bool { lock.withLock { open } }

    func write(line: String) throws {
        guard isOpen else { throw ControlService.Failure("the stream to \(host) is closed") }
        if !line.hasPrefix(#"{"c":"#) || !line.contains(#","m":"#) {
            switch try? ControlWire.readHost(line) {
            case .open(let channel, _)?: lock.withLock { _ = channels.insert(channel) }
            case .close(let channel)?: lock.withLock { _ = channels.remove(channel) }
            default: break
            }
        }
        send(PeerWire.frame(host, line))
    }

    func lines() -> AsyncThrowingStream<String, any Error> {
        lock.withLock {
            let taken = stream ?? AsyncThrowingStream { $0.finish() }
            stream = nil
            return taken
        }
    }

    func deliver(_ line: String) {
        let continuation = lock.withLock { open ? self.continuation : nil }
        continuation?.yield(line)
    }

    /// The router dropped this stream (the host moved, or another took its place): the
    /// holder closes this copy's channels on the host.
    func close() {
        let open = lock.withLock { self.open ? channels : [] }
        for channel in open { send(PeerWire.frame(host, ControlWire.close(channel))) }
        finish()
    }

    func finish() {
        let continuation: AsyncThrowingStream<String, any Error>.Continuation? = lock.withLock {
            guard open else { return nil }
            open = false
            return self.continuation
        }
        continuation?.finish()
    }
}

import Foundation

/// What the control plane answers itself (T008), handed to the router so the router
/// stays ignorant of pairing, stores and ssh.
public protocol ControlHandling: Sendable {
    /// Whether a method with no host named is the control plane's own. A legacy client's
    /// bare line for any other method goes to the home host.
    func handles(_ method: String) -> Bool
    /// A request from a client for the control plane itself. Any paired client may ask
    /// any of them (#111); a method with a rule of its own keeps it in the handler.
    func handle(method: String, params: JSONValue?, from caller: ControlRouter.Caller) async throws -> JSONValue
    /// A request on a host's channel 0: `host/hello`, `attention/need`.
    func hostSaid(_ host: HostID, method: String, params: JSONValue?) async throws -> JSONValue
}

/// The middle of the control plane (058, R3): client sessions on one side, host
/// uplinks on the other, and a channel for every pair of them.
///
/// It routes connections, not calls. For each client and each online host it opens a
/// channel on the host's uplink, which the host turns into one virtual connection with
/// everything a `daemon.sock` connection has today. A request is passed down its
/// channel as the bytes it arrived as (every paired client may ask anything, #111); whatever
/// the host says on that channel goes back to that client with the host's id on it.
/// Credential lending, broadcast filtering and device pinning are the host's, per
/// connection, as they always were, so none of them is here.
public actor ControlRouter {
    /// Who is calling, as the control plane's own methods need to know.
    public struct Caller: Sendable, Hashable {
        public var session: UUID
        public var client: UUID
        public var kind: ClientRecord.Kind
        /// The device came through `agents-relay` (T096), not straight here.
        public var relayed: Bool
        public init(session: UUID, client: UUID, kind: ClientRecord.Kind, relayed: Bool = false) {
            self.relayed = relayed
            self.session = session
            self.client = client
            self.kind = kind
        }
    }

    private struct ClientSession {
        var caller: Caller
        var transport: any LineTransport
        var channels: [HostID: Int] = [:]
        /// Set by the first wrapped line. Until then the client is today's Remote, which
        /// speaks bare JSON-RPC to one daemon: the home host (R7).
        var wrapped = false
        /// Requests sent to each host and not answered yet, so a host that goes answers
        /// them with `hostOffline` rather than leaving the client to wait for ever (#77).
        var inFlight: [HostID: Set<JSONRPCID>] = [:]
    }

    /// Who a channel on a host's uplink is for: a client session here, or a stream a
    /// peer copy carries for one of its own clients (058, US3, T065).
    private enum Target: Hashable {
        case session(UUID)
        case peer(String, Int)
        /// The other end of a tunnel between two hosts (T091): that host's channel.
        case tunnel(HostID, Int)
    }

    private struct HostSession {
        var transport: any LineTransport
        var nextChannel = 1
        var channels: [Int: Target] = [:]
        /// Distinguishes this uplink from the one it replaced, so the old one ending
        /// does not take the new one down with it.
        var generation: UUID
        /// The host's real uplink is here. Otherwise the session is a stream on the peer
        /// link to the copy that holds it, and its channel numbers are this copy's own.
        var local: Bool
        /// A peer's stream `(peer, c)` to the channel it was given here.
        var proxied: [Target: Int] = [:]
    }

    private let handler: any ControlHandling
    private var homeHost: HostID?
    private var clients: [UUID: ClientSession] = [:]
    private var hosts: [HostID: HostSession] = [:]
    private var known: Set<HostID>
    /// Hosts that only relay (T096), and whether each is relaying now: they carry
    /// devices through iCloud and are given no client channels, only channel 0.
    private var relays: [HostID: Bool] = [:]
    private var states: [HostID: HostState] = [:]
    /// Where each session last said the person was, keyed by the session, or by the client for
    /// a report made at another copy. Folded per surface, so a client with two sockets (two tabs
    /// of one browser, 071 R11) is active while either is: one record per client let the last
    /// report win, and a hidden tab marked the person away from the one they were reading.
    private var notedPresence: [UUID: NotedPresence] = [:]
    /// How to reach each peer copy on its link, for streams carried for it (T064).
    private var peers: [String: @Sendable (String) -> Void] = [:]
    /// How each client connected at another copy reaches it: relayed or not (T080).
    private var peerLinks: [String: [UUID: Bool]] = [:]
    /// Told when a client here connects, or its last session ends (nil), so other copies know.
    private var linkChanged: (@Sendable (UUID, Bool?) -> Void)?
    /// Told each presence report a client here makes, so other copies fold it too.
    /// The `Bool` says whether the client is a device (`ClientRecord.Kind.isDevice`).
    private var presenceHeard: (@Sendable (UUID, Bool, DaemonAPI.PresenceReport) -> Void)?

    private struct NotedPresence {
        var client: UUID
        var surface: Surface
        var watching: UUID?
        var active: Bool
        var heardAt: Date
        /// The device's own report. Omitted from a later report means unchanged.
        var mayNotify: Bool?
    }

    public init(handler: any ControlHandling, knownHosts: [HostID] = [], homeHost: HostID? = nil) {
        self.handler = handler
        self.known = Set(knownHosts)
        self.homeHost = homeHost
        for host in knownHosts { states[host] = .offline(since: Date()) }
    }

    // MARK: What it knows

    public func setHomeHost(_ host: HostID?) { homeHost = host }

    public func state(of host: HostID) -> HostState? { states[host] }

    public var hostStates: [HostID: HostState] { states }

    public var sessionCount: Int { clients.count }

    /// How many calls to `host` are waiting on an answer, across every session.
    public func inFlight(of host: HostID) -> Int {
        clients.values.reduce(0) { $0 + ($1.inFlight[host]?.count ?? 0) }
    }

    /// Every client's presence, folded the way a daemon folds its own: one record per
    /// surface, an active one beating a later quiet one (058, R6). An operator is the
    /// Mac's screen, whichever host it reported through.
    public func foldedPresences() -> [Surface: Presence] {
        var folded: [Surface: Presence] = [:]
        for note in notedPresence.values {
            let presence = Presence(surface: note.surface, watching: note.watching,
                                    active: note.active, heardAt: note.heardAt)
            if let held = folded[note.surface] {
                let better = presence.active != held.active ? presence.active : presence.heardAt > held.heardAt
                if !better { continue }
            }
            folded[note.surface] = presence
        }
        return folded
    }

    /// What each device last said about showing a notification, where it has said.
    public func notifyFlags() -> [UUID: Bool] {
        var flags: [UUID: (Bool, Date)] = [:]
        for note in notedPresence.values {
            guard let may = note.mayNotify else { continue }
            if let held = flags[note.client], held.1 > note.heardAt { continue }
            flags[note.client] = (may, note.heardAt)
        }
        return flags.mapValues(\.0)
    }

    /// A presence report made at another copy (US3): folded here as the client's own.
    public func notePeerPresence(client: UUID, device: Bool, report: DaemonAPI.PresenceReport, at: Date = Date()) {
        notePresence(client: client, device: device, report: report, at: at)
    }

    public func onPresence(_ heard: @escaping @Sendable (UUID, Bool, DaemonAPI.PresenceReport) -> Void) {
        presenceHeard = heard
    }

    /// `session` is the socket the report came on; nil for one made at another copy.
    private func notePresence(client: UUID, device: Bool, report: DaemonAPI.PresenceReport,
                              session: UUID? = nil, at: Date = Date()) {
        let surface: Surface = device ? .device(client) : .mac
        let key = session ?? client
        let previous = notedPresence[key]
        notedPresence[key] = NotedPresence(client: client, surface: surface, watching: report.watching,
                                           active: report.active, heardAt: at,
                                           mayNotify: report.mayNotify ?? previous?.mayNotify)
    }

    public func sessions(of client: UUID) -> [UUID] {
        clients.filter { $0.value.caller.client == client }.map(\.key)
    }

    /// The channels open on a host's uplink, for tests and for Settings.
    public func channels(of host: HostID) -> [Int] {
        hosts[host].map { Array($0.channels.keys).sorted() } ?? []
    }

    /// Whether this copy holds the host's real uplink, as against a stream to the copy
    /// that does.
    public func holds(_ host: HostID) -> Bool { hosts[host]?.local == true }

    /// Whether the host is reachable from here at all, directly or through a peer.
    public func reaches(_ host: HostID) -> Bool { hosts[host] != nil }

    /// Every client with a session here, for the backstop that catches a forget another
    /// copy made while its event was missed (T066).
    public func connectedClients() -> Set<UUID> {
        Set(clients.values.map(\.caller.client))
    }

    // MARK: Hosts

    /// A host enrolled with the control plane (online or not). Calls naming one that is
    /// not known are refused as `noSuchHost`, not `hostOffline`.
    public func know(_ host: HostID) {
        guard known.insert(host).inserted else { return }
        states[host] = .offline(since: Date())
    }

    /// Removing a host (FR-014): its uplink closes and it is forgotten. Its agents are
    /// left as they are.
    public func forgetHost(_ host: HostID) {
        dropHost(host, generation: nil, newState: nil)
        known.remove(host)
        states[host] = nil
        broadcastControl(DaemonAPI.Notification.controlHostChanged,
                         ["host": .string(host.rawValue), "state": .string("removed")])
    }

    /// A host's uplink is up, or (with `local: false`) a stream to the peer copy that
    /// holds it. Opens a channel to it for every client session, then reads it until it
    /// ends. A proxied stream that ends leaves the state alone: the host has usually moved,
    /// and is shown offline only if nobody holds it again soon (wire.md, `gone`).
    public func attachHost(_ host: HostID, transport: any LineTransport, local: Bool = true) {
        if hosts[host] != nil { dropHost(host, generation: nil, newState: nil) }
        known.insert(host)
        let generation = UUID()
        hosts[host] = HostSession(transport: transport, generation: generation, local: local)
        setState(.online, of: host)
        for session in clients.keys { openChannel(for: session, to: host) }
        Task { [weak self] in
            do {
                for try await line in transport.lines() { await self?.hostLine(line, from: host) }
            } catch {}
            if local {
                guard let self else { return }
                let current = await self.isCurrent(host, generation)
                await self.dropHost(host, generation: generation, newState: .offline(since: Date()))
                if current { await self.localEnded?(host) }
            } else {
                await self?.dropHost(host, generation: generation, newState: nil)
                await self?.offlineUnlessBack(host, after: .seconds(5))
            }
        }
    }

    private func isCurrent(_ host: HostID, _ generation: UUID) -> Bool { hosts[host]?.generation == generation }

    /// Told when a host's real uplink here ends, so its lease is let go (T063).
    private var localEnded: (@Sendable (HostID) async -> Void)?
    public func onLocalHostEnded(_ ended: @escaping @Sendable (HostID) async -> Void) { localEnded = ended }

    /// Closes a host's real uplink here: its lease went to another copy. The host redials.
    public func closeLocal(_ host: HostID) {
        guard hosts[host]?.local == true else { return }
        dropHost(host, generation: nil, newState: nil)
    }

    /// Ends whatever this copy has for `host`, saying nothing yet: another copy is taking
    /// it over. Shown offline only if nothing is back within `grace`.
    public func dropQuietly(_ host: HostID, grace: Duration = .seconds(5)) {
        dropHost(host, generation: nil, newState: nil)
        Task { [weak self] in await self?.offlineUnlessBack(host, after: grace) }
    }

    private func offlineUnlessBack(_ host: HostID, after grace: Duration) async {
        try? await Task.sleep(for: grace)
        if hosts[host] == nil, known.contains(host), states[host]?.isOnline == true {
            setState(.offline(since: Date()), of: host)
        }
    }

    // MARK: Streams carried for peer copies (T065)

    /// A peer copy's link is up: streams it asks for are answered through `write`.
    public func setPeer(_ id: String, write: @escaping @Sendable (String) -> Void) {
        peers[id] = write
    }

    /// A peer's link went: every stream it had open on a host here closes there.
    public func dropPeer(_ id: String) {
        peers[id] = nil
        if let gone = peerLinks.removeValue(forKey: id), !gone.isEmpty {
            broadcastControl(DaemonAPI.Notification.controlClientChanged, [:])
        }
        for (host, session) in hosts where session.local {
            for (target, channel) in session.proxied {
                guard case .peer(id, _) = target else { continue }
                closeHostChannel(channel, on: host)
            }
        }
    }

    /// A peer opens a stream to a host held here: a fresh channel on the real uplink.
    public func openFromPeer(_ peer: String, host: HostID, channel: Int, _ open: ControlWire.ChannelOpen) {
        guard relays[host] == nil, var session = hosts[host], session.local else {
            peers[peer]?(PeerWire.frame(host, ControlWire.close(channel)))
            return
        }
        let target = Target.peer(peer, channel)
        if let old = session.proxied[target] {
            session.channels[old] = nil
            try? session.transport.write(line: ControlWire.close(old))
        }
        let mine = session.nextChannel
        session.nextChannel += 1
        session.channels[mine] = target
        session.proxied[target] = mine
        hosts[host] = session
        // This copy reads fan-out frames and hands each peer its part channel by channel,
        // which every copy reads, so the host may fan out whatever the peer is.
        var open = open
        open.fanOut = true
        try? session.transport.write(line: ControlWire.open(mine, open))
    }

    /// A message on a peer's stream, for the host.
    public func fromPeer(_ peer: String, host: HostID, channel: Int, message: String) {
        guard let session = hosts[host], session.local, let mine = session.proxied[.peer(peer, channel)] else {
            peers[peer]?(PeerWire.frame(host, ControlWire.close(channel)))
            return
        }
        try? session.transport.write(line: ControlWire.channel(mine, message: message))
    }

    /// The peer closed its stream.
    public func closeFromPeer(_ peer: String, host: HostID, channel: Int) {
        guard let mine = hosts[host]?.proxied[.peer(peer, channel)] else { return }
        closeHostChannel(mine, on: host)
    }

    private func closeHostChannel(_ channel: Int, on host: HostID) {
        guard var session = hosts[host], let target = session.channels.removeValue(forKey: channel) else { return }
        session.proxied[target] = nil
        hosts[host] = session
        try? session.transport.write(line: ControlWire.close(channel))
    }

    public func setState(_ state: HostState, of host: HostID) {
        guard states[host] != state else { return }
        states[host] = state
        broadcastControl(DaemonAPI.Notification.controlHostChanged, Self.describe(host, state))
    }

    private func dropHost(_ host: HostID, generation: UUID?, newState: HostState?) {
        guard let session = hosts[host], generation == nil || session.generation == generation else { return }
        hosts[host] = nil
        session.transport.close()
        var bareGone: [UUID] = []
        for (channel, target) in session.channels {
            switch target {
            case .session(let sessionID):
                clients[sessionID]?.channels[host] = nil
                // What was asked of it is answered, not lost (#77).
                let waiting = clients[sessionID]?.inFlight.removeValue(forKey: host) ?? []
                let wrapped = clients[sessionID]?.wrapped ?? true
                for id in waiting {
                    reply(to: sessionID, host: host, id: id, wrapped: wrapped,
                          error: JSONRPCError(code: DaemonAPI.Failure.hostOffline,
                                              message: "That host went offline before it answered."))
                }
                // A bare-wire client (the Remote) talks to the home host's daemon and hears
                // nothing else: no `control/hostChanged`, and the daemon that comes back
                // knows nothing of it. Its connection ends, so it reconnects, says who it is
                // again and reads everything afresh.
                if !wrapped, host == homeHost { bareGone.append(sessionID) }
            // The peer's stream ends with the uplink; the peer finds the host again.
            case .peer(let peer, let theirs):
                _ = channel
                peers[peer]?(PeerWire.frame(host, ControlWire.close(theirs)))
            // A tunnel ends at both hosts with either.
            case .tunnel(let other, let theirs):
                hosts[other]?.channels[theirs] = nil
                try? hosts[other]?.transport.write(line: ControlWire.close(theirs))
            }
        }
        if let newState { setState(newState, of: host) }
        for sessionID in bareGone { detachClient(sessionID) }
    }

    /// The id of a reply, or nil for anything else (a notification, or a request the host
    /// makes of the client, whose ids are the host's own).
    ///
    /// Scanned, not decoded: every reply a host sends passes here, a page of transcript is
    /// a hundred kilobytes, and all this needs is two keys at the top of the object. Only
    /// the top level is read (#167): a nested value is stepped over without a string being
    /// made of anything in it, and the scan stops once an id and `result` or `error` have
    /// both been seen, which is usually long before the result itself.
    static func answeredID(_ message: String) -> JSONRPCID? {
        var id: JSONRPCID?
        var isReply = false
        var bytes = message.utf8[...].drop(while: isSpace)
        guard bytes.first == UInt8(ascii: "{") else { return nil }
        bytes = bytes.dropFirst()
        while true {
            bytes = bytes.drop(while: { isSpace($0) || $0 == UInt8(ascii: ",") })
            guard let first = bytes.first else { return nil }
            if first == UInt8(ascii: "}") { break }
            guard first == UInt8(ascii: "\""), let (key, rest) = Self.string(bytes) else { return nil }
            var value = rest.drop(while: isSpace)
            guard value.first == UInt8(ascii: ":") else { return nil }
            value = value.dropFirst().drop(while: isSpace)
            switch key {
            case "method":
                return nil
            case "id":
                if value.first == UInt8(ascii: "\"") {
                    guard let (string, after) = Self.string(value) else { return nil }
                    id = .string(string)
                    bytes = after
                } else {
                    let digits = value.prefix(while: { $0 == UInt8(ascii: "-") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
                    id = Int(String(decoding: digits, as: UTF8.self)).map(JSONRPCID.number)
                    bytes = Self.skipValue(value)
                }
            default:
                if key == "result" || key == "error" { isReply = true }
                bytes = Self.skipValue(value)
            }
            if isReply, id != nil { return id }
        }
        return id
    }

    /// What follows the JSON value `bytes` starts with, stepped over without reading it.
    private static func skipValue(_ bytes: Substring.UTF8View.SubSequence) -> Substring.UTF8View.SubSequence {
        var depth = 0
        var inString = false
        var escaped = false
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") {
                    inString = false
                    if depth == 0 { return bytes[bytes.index(after: index)...] }
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    if depth == 0 { return bytes[index...] }
                    depth -= 1
                    if depth == 0 { return bytes[bytes.index(after: index)...] }
                case UInt8(ascii: ","):
                    if depth == 0 { return bytes[index...] }
                default: break
                }
            }
            index = bytes.index(after: index)
        }
        return bytes[bytes.endIndex...]
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// The JSON string `bytes` starts with, unescaped enough to compare a key or an id,
    /// and what follows it.
    private static func string(_ bytes: Substring.UTF8View.SubSequence) -> (String, Substring.UTF8View.SubSequence)? {
        var index = bytes.index(after: bytes.startIndex)
        var text: [UInt8] = []
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                let next = bytes.index(after: index)
                guard next < bytes.endIndex else { return nil }
                text.append(bytes[next])
                index = bytes.index(after: next)
                continue
            }
            if byte == UInt8(ascii: "\"") {
                return (String(decoding: text, as: UTF8.self), bytes[bytes.index(after: index)...])
            }
            text.append(byte)
            index = bytes.index(after: index)
        }
        return nil
    }

    private func hostLine(_ line: String, from host: HostID) async {
        guard let frame = try? ControlWire.readHost(line) else { return }
        switch frame {
        case .message(0, let message):
            await channelZero(message, from: host)
        case .message(let channel, let message):
            guard let target = hosts[host]?.channels[channel] else { return }
            guard case .session(let sessionID) = target else {
                if case .peer(let peer, let theirs) = target {
                    peers[peer]?(PeerWire.frame(host, ControlWire.channel(theirs, message: message)))
                }
                // A tunnel's bytes go to the other host as they came, never read.
                if case .tunnel(let other, let theirs) = target {
                    try? hosts[other]?.transport.write(line: ControlWire.channel(theirs, message: message))
                }
                return
            }
            guard let session = clients[sessionID] else { return }
            // Read only while something is waiting on this host, and only for its id: the
            // line itself goes on as it came.
            if session.inFlight[host]?.isEmpty == false, let id = Self.answeredID(message) {
                clients[sessionID]?.inFlight[host]?.remove(id)
            }
            if session.wrapped {
                write(ControlWire.wrap(host: host, message: message), to: sessionID)
            } else if host == homeHost {
                write(message, to: sessionID)
            }
        case .close(let channel):
            // The host hung up on a client (a device it was told to forget, say). The
            // client's whole connection goes, as it would have today.
            guard let target = hosts[host]?.channels.removeValue(forKey: channel) else { return }
            switch target {
            case .session(let sessionID): detachClient(sessionID)
            case .peer(let peer, let theirs):
                hosts[host]?.proxied[target] = nil
                peers[peer]?(PeerWire.frame(host, ControlWire.close(theirs)))
            case .tunnel(let other, let theirs):
                hosts[other]?.channels[theirs] = nil
                try? hosts[other]?.transport.write(line: ControlWire.close(theirs))
            }
        case .fanOut(let channels, let message):
            fanOut(message, to: channels, from: host)
        case .open:
            // Only the control plane opens channels. A host that tries is ignored.
            return
        }
    }

    /// A host's broadcast said once for every channel named (#167): copied here to each
    /// one's client, wrapped once for them all. Only notifications come this way, so there
    /// is no reply in it to look for. A client whose transport has given up on it (too far
    /// behind) is detached by `write`, and reconnects to read everything afresh.
    private func fanOut(_ message: String, to channels: [Int], from host: HostID) {
        guard let session = hosts[host] else { return }
        var wrapped: String?
        for channel in channels {
            switch session.channels[channel] {
            case .session(let sessionID)?:
                guard let client = clients[sessionID] else { continue }
                if client.wrapped {
                    if wrapped == nil { wrapped = ControlWire.wrap(host: host, message: message) }
                    write(wrapped!, to: sessionID)
                } else if host == homeHost {
                    write(message, to: sessionID)
                }
            case .peer(let peer, let theirs)?:
                // Channel by channel, which a copy of any age reads.
                peers[peer]?(PeerWire.frame(host, ControlWire.channel(theirs, message: message)))
            case .tunnel?, nil:
                continue
            }
        }
    }

    private func channelZero(_ message: String, from host: HostID) async {
        guard let decoded = try? JSONRPCCodec.decode(line: message) else { return }
        guard case .request(let id, let method, let params) = decoded else { return }
        let reply: JSONRPCMessage
        do {
            reply = .success(id: id, result: try await handler.hostSaid(host, method: method, params: params))
        } catch let error as JSONRPCError {
            reply = .failure(id: id, error: error)
        } catch {
            reply = .failure(id: id, error: JSONRPCError(code: JSONRPCError.internalError, message: "\(error)"))
        }
        if let line = try? JSONRPCCodec.encode(reply) {
            try? hosts[host]?.transport.write(line: ControlWire.channel(0, message: line))
        }
    }

    // MARK: Clients

    /// A paired client has connected. Returns its session, which ends when the
    /// transport does.
    @discardableResult
    public func attachClient(_ client: ClientRecord, transport: any LineTransport, relayed: Bool = false) -> UUID {
        let id = UUID()
        clients[id] = ClientSession(caller: Caller(session: id, client: client.id, kind: client.kind,
                                                   relayed: relayed),
                                    transport: transport)
        for host in hosts.keys { openChannel(for: id, to: host) }
        noteLink(client.id)
        Task { [weak self] in
            do {
                for try await line in transport.lines() { await self?.clientLine(line, from: id) }
            } catch {}
            await self?.detachClient(id)
        }
        return id
    }

    /// Ends a session: its channels are closed on every host, then its transport.
    /// The close code a forgotten client's sockets end with (071 contracts/browser-auth.md).
    public static let forgottenCloseCode: UInt16 = 4403

    public func detachClient(_ id: UUID) { detachClient(id, closing: nil) }

    private func detachClient(_ id: UUID, closing code: UInt16?) {
        guard let session = clients.removeValue(forKey: id) else { return }
        let client = session.caller.client
        notedPresence.removeValue(forKey: id)
        if !clients.values.contains(where: { $0.caller.client == client }) {
            notedPresence.removeValue(forKey: client)
        }
        for (host, channel) in session.channels {
            hosts[host]?.channels[channel] = nil
            try? hosts[host]?.transport.write(line: ControlWire.close(channel))
        }
        if let code { session.transport.close(code: code, reason: "forgotten") } else { session.transport.close() }
        noteLink(client)
    }

    // MARK: How clients reach the control plane (T080)

    /// How a client reaches this copy now: nil when it doesn't, true when only through
    /// the relay. A client with a direct session counts as direct.
    private func linkHere(_ client: UUID) -> Bool? {
        let mine = clients.values.filter { $0.caller.client == client }
        guard !mine.isEmpty else { return nil }
        return mine.allSatisfy(\.caller.relayed)
    }

    private var toldLinks: [UUID: Bool] = [:]

    /// A client's link changed here: other copies are told, and operators' Settings.
    private func noteLink(_ client: UUID) {
        let now = linkHere(client)
        guard toldLinks[client] != now else { return }
        toldLinks[client] = now
        linkChanged?(client, now)
        broadcastControl(DaemonAPI.Notification.controlClientChanged, ["client": .string(client.uuidString)])
    }

    public func onLinkChanged(_ changed: @escaping @Sendable (UUID, Bool?) -> Void) { linkChanged = changed }

    /// Every client connected here, as `onLinkChanged` said it: for a peer that just linked.
    public func linksHere() -> [UUID: Bool] { toldLinks }

    /// A peer copy said how one of its clients reaches it.
    public func notePeerLink(_ peer: String, client: UUID, relayed: Bool?) {
        peerLinks[peer, default: [:]][client] = relayed
        broadcastControl(DaemonAPI.Notification.controlClientChanged, ["client": .string(client.uuidString)])
    }

    /// How every connected client reaches the control plane, at any copy: true when only
    /// through the relay.
    public func connections() -> [UUID: Bool] {
        var all: [UUID: Bool] = [:]
        for links in peerLinks.values {
            for (client, relayed) in links { all[client] = (all[client] ?? true) && relayed }
        }
        for (client, relayed) in toldLinks { all[client] = (all[client] ?? true) && relayed }
        return all
    }

    /// `clients/forget`: every session of that client, at once (FR-008).
    /// Every session of a forgotten client ends, each told why with 4403 (FR-014).
    public func forgetClient(_ client: UUID) {
        for id in sessions(of: client) { detachClient(id, closing: Self.forgottenCloseCode) }
    }

    private func openChannel(for sessionID: UUID, to host: HostID) {
        guard relays[host] == nil, var hostSession = hosts[host], let caller = clients[sessionID]?.caller else { return }
        let channel = hostSession.nextChannel
        hostSession.nextChannel += 1
        hostSession.channels[channel] = .session(sessionID)
        hosts[host] = hostSession
        clients[sessionID]?.channels[host] = channel
        // Bound to the client unless it is a Mac's window, which is the Mac, as a window
        // on the socket is: presence is reported as it, and it names no other device.
        let open = ControlWire.ChannelOpen(client: caller.client.uuidString,
                                           device: caller.kind == .mac ? nil : caller.client,
                                           relayed: caller.relayed ? true : nil, fanOut: true)
        try? hostSession.transport.write(line: ControlWire.open(channel, open))
    }

    private func clientLine(_ line: String, from sessionID: UUID) {
        let frame: ControlWire.ClientFrame
        do {
            frame = try ControlWire.readClient(line)
        } catch {
            unreadable(line, error, from: sessionID)
            return
        }
        switch frame {
        case .toControl(let message):
            clients[sessionID]?.wrapped = true
            toControl(message, from: sessionID, wrapped: true)
        case .toHost(let host, let message):
            clients[sessionID]?.wrapped = true
            toHost(host, message, from: sessionID)
        case .legacy(let message):
            if let request = ControlWire.request(in: message), handler.handles(request.method) {
                toControl(message, from: sessionID, wrapped: false)
            } else if let homeHost {
                toHost(homeHost, message, from: sessionID)
            } else if let request = ControlWire.request(in: message) {
                reply(to: sessionID, host: nil, id: request.id, wrapped: false,
                      error: JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "This control plane has no home host."))
            }
        }
    }

    private func toHost(_ host: HostID, _ message: String, from sessionID: UUID) {
        guard let session = clients[sessionID] else { return }
        let wrapped = session.wrapped
        let decoded = try? JSONRPCCodec.decode(line: message)
        switch decoded {
        case .request(let id, let method, let params)?:
            if method == DaemonAPI.Method.presenceReport, let params,
               let report = try? params.decode(DaemonAPI.PresenceReport.self) {
                notePresence(client: session.caller.client, device: session.caller.kind.isDevice, report: report,
                             session: sessionID)
                presenceHeard?(session.caller.client, session.caller.kind.isDevice, report)
            }
            guard known.contains(host) else {
                return reply(to: sessionID, host: host, id: id, wrapped: wrapped,
                             error: JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No host is called \(host.rawValue)."))
            }
            guard let channel = session.channels[host], let uplink = hosts[host] else {
                return reply(to: sessionID, host: host, id: id, wrapped: wrapped,
                             error: JSONRPCError(code: DaemonAPI.Failure.hostOffline, message: "That host is offline."))
            }
            // An uplink that has ended but is not yet dropped takes nothing: said, not lost (#62).
            do {
                try uplink.transport.write(line: ControlWire.channel(channel, message: message))
                clients[sessionID]?.inFlight[host, default: []].insert(id)
            } catch {
                reply(to: sessionID, host: host, id: id, wrapped: wrapped,
                      error: JSONRPCError(code: DaemonAPI.Failure.hostOffline, message: "That host is offline."))
            }
        case .notification?, .success?, .failure?:
            // A notification, or an answer to something the host asked this client.
            guard let channel = session.channels[host] else { return }
            try? hosts[host]?.transport.write(line: ControlWire.channel(channel, message: message))
        case nil:
            // Unreadable, so nobody can say what it asks: it goes nowhere.
            return
        }
    }

    private func toControl(_ message: String, from sessionID: UUID, wrapped: Bool) {
        guard let caller = clients[sessionID]?.caller,
              case .request(let id, let method, let params)? = try? JSONRPCCodec.decode(line: message) else { return }
        let handler = self.handler
        // Its own task: `hosts/install` takes minutes, and nothing else this client says
        // may wait behind it.
        Task.detached { [weak self] in
            let reply: JSONRPCMessage
            do {
                reply = .success(id: id, result: try await handler.handle(method: method, params: params, from: caller))
            } catch let error as JSONRPCError {
                reply = .failure(id: id, error: error)
            } catch {
                reply = .failure(id: id, error: JSONRPCError(code: JSONRPCError.internalError, message: "\(error)"))
            }
            guard let line = try? JSONRPCCodec.encode(reply) else { return }
            await self?.write(wrapped ? ControlWire.wrap(host: nil, message: line) : line, to: sessionID)
        }
    }

    /// A line from a client that is not a frame. JSON-RPC's answer to a request it cannot
    /// read is a parse error with no id, and the client fails what it has in flight
    /// rather than waiting for a reply that will not come (#93). It goes back on the
    /// route the line named, when it named one, so it reaches the connection that sent it.
    private func unreadable(_ line: String, _ error: any Error, from sessionID: UUID) {
        WireLog.write("control: unreadable line from client \(sessionID) (\(error)): \(WireLog.excerpt(line))")
        guard let session = clients[sessionID] else { return }
        let object = try? JSONValue.parse(Data(line.utf8)).objectValue
        let host = object?["h"]?.stringValue.flatMap { ControlWire.isHostID($0) ? HostID(rawValue: $0) : nil }
        let wrapped = session.wrapped || object?["m"] != nil || object?["h"] != nil
        let failure = JSONRPCError(code: JSONRPCError.parseError, message: "The control plane could not read that message.")
        guard let reply = try? JSONRPCCodec.encode(.failure(id: nil, error: failure)) else { return }
        write(wrapped ? ControlWire.wrap(host: host, message: reply) : reply, to: sessionID)
    }

    private func reply(to sessionID: UUID, host: HostID?, id: JSONRPCID, wrapped: Bool, error: JSONRPCError) {
        guard let line = try? JSONRPCCodec.encode(.failure(id: id, error: error)) else { return }
        write(wrapped ? ControlWire.wrap(host: host, message: line) : line, to: sessionID)
    }

    private func write(_ line: String, to sessionID: UUID) {
        guard let session = clients[sessionID] else { return }
        do { try session.transport.write(line: line) } catch { detachClient(sessionID) }
    }

    // MARK: Tunnels between hosts (T091)

    /// A channel on each of two hosts, joined: what one sends on its end reaches the other
    /// untouched. For a sign-in `lender` relays to `borrower`, which asked with `ref`. Either
    /// end closing, or either host going, closes both. False when either host is not here.
    @discardableResult
    public func openTunnel(borrower: HostID, lender: HostID, runtime: String, ref: String) -> Bool {
        guard borrower != lender, var near = hosts[borrower], var far = hosts[lender] else { return false }
        let nearChannel = near.nextChannel
        near.nextChannel += 1
        let farChannel = far.nextChannel
        far.nextChannel += 1
        near.channels[nearChannel] = .tunnel(lender, farChannel)
        far.channels[farChannel] = .tunnel(borrower, nearChannel)
        hosts[borrower] = near
        hosts[lender] = far
        try? far.transport.write(line: ControlWire.open(farChannel, ControlWire.ChannelOpen(
            client: "tunnel:" + borrower.rawValue, tunnel: runtime)))
        try? near.transport.write(line: ControlWire.open(nearChannel, ControlWire.ChannelOpen(
            client: "tunnel:" + lender.rawValue, tunnel: runtime, tunnelRef: ref)))
        return true
    }

    /// The tunnels open now, as (borrower, lender) pairs: for tests.
    public func tunnels() -> [(HostID, HostID)] {
        hosts.flatMap { host, session in
            session.channels.values.compactMap { target -> (HostID, HostID)? in
                guard case .tunnel(let other, _) = target else { return nil }
                return (host, other)
            }
        }
    }

    // MARK: Relay hosts (T096–T097)

    /// Whether a host only relays (`HostRecord.relay`): nil for a host that runs agents,
    /// false for a relay switched off, true for one relaying. A host found to be a relay
    /// has its client channels closed.
    public func setRelay(_ host: HostID, _ relay: Bool?) {
        guard let relay else {
            guard relays.removeValue(forKey: host) != nil else { return }
            for sessionID in clients.keys { openChannel(for: sessionID, to: host) }
            return
        }
        let was = relays.updateValue(relay, forKey: host)
        guard was == nil else { return }
        for (sessionID, session) in clients {
            guard let channel = session.channels[host] else { continue }
            clients[sessionID]?.channels[host] = nil
            hosts[host]?.channels[channel] = nil
            try? hosts[host]?.transport.write(line: ControlWire.close(channel))
        }
    }

    /// A relaying host whose uplink ends at this copy, if there is one online.
    public func relayHeldHere() -> HostID? { relaysHeldHere().first }

    /// Relaying hosts whose uplinks end here.
    public func relaysHeldHere() -> [HostID] {
        relays.filter { $0.value && hosts[$0.key]?.local == true }.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// A notification on a host's channel 0, when its uplink ends here.
    @discardableResult
    public func tell(_ host: HostID, _ method: String, _ params: JSONValue) -> Bool {
        guard let session = hosts[host], session.local,
              let line = try? JSONRPCCodec.encode(.notification(method: method, params: params)) else { return false }
        do {
            try session.transport.write(line: ControlWire.channel(0, message: line))
            return true
        } catch {
            return false
        }
    }

    // MARK: The control plane's own notifications

    /// Tells every client that speaks the wrapped wire.
    public func broadcastControl(_ method: String, _ params: JSONValue) {
        guard let line = try? JSONRPCCodec.encode(.notification(method: method, params: params)) else { return }
        let wrapped = ControlWire.wrap(host: nil, message: line)
        for (id, session) in clients where session.wrapped {
            write(wrapped, to: id)
        }
    }

    public static func describe(_ host: HostID, _ state: HostState) -> JSONValue {
        var params: [String: JSONValue] = ["host": .string(host.rawValue)]
        switch state {
        case .online: params["state"] = "online"
        case .connecting: params["state"] = "connecting"
        case .offline(let since):
            params["state"] = "offline"
            params["since"] = .string(since.formatted(Date.ISO8601FormatStyle()))
        case .needsUpdate(let from, let to):
            params["state"] = "needsUpdate"
            params["from"] = .string(from)
            params["to"] = .string(to)
        case .failed(let reason):
            params["state"] = "failed"
            params["reason"] = .string(reason)
        }
        return .object(params)
    }
}

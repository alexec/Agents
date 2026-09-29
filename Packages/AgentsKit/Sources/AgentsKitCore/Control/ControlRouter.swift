import Foundation

/// What the control plane answers itself (T008), handed to the router so the router
/// stays ignorant of pairing, stores and ssh.
public protocol ControlHandling: Sendable {
    /// Whether a method with no host named is the control plane's own. A legacy client's
    /// bare line for any other method goes to the home host.
    func handles(_ method: String) -> Bool
    /// A request from a client for the control plane itself. The grant has not been
    /// checked: each method has its own rule, in the handler.
    func handle(method: String, params: JSONValue?, from caller: ControlRouter.Caller) async throws -> JSONValue
    /// A request on a host's channel 0: `host/hello`, `attention/need`.
    func hostSaid(_ host: HostID, method: String, params: JSONValue?) async throws -> JSONValue
}

/// The middle of the control plane (058, R3): client sessions on one side, host
/// uplinks on the other, and a channel for every pair of them.
///
/// It routes connections, not calls. For each client and each online host it opens a
/// channel on the host's uplink, which the host turns into one virtual connection with
/// everything a `daemon.sock` connection has today. A request is checked against the
/// client's grant, then passed down its channel as the bytes it arrived as; whatever
/// the host says on that channel goes back to that client with the host's id on it.
/// Credential lending, broadcast filtering and device pinning are the host's, per
/// connection, as they always were, so none of them is here.
public actor ControlRouter {
    /// Who is calling, as the control plane's own methods need to know.
    public struct Caller: Sendable, Hashable {
        public var session: UUID
        public var client: UUID
        public var grant: Grant
        public var kind: ClientRecord.Kind
    }

    private struct ClientSession {
        var caller: Caller
        var transport: any LineTransport
        var channels: [HostID: Int] = [:]
        /// Set by the first wrapped line. Until then the client is today's Remote, which
        /// speaks bare JSON-RPC to one daemon: the home host (R7).
        var wrapped = false
    }

    private struct HostSession {
        var transport: any LineTransport
        var nextChannel = 1
        var channels: [Int: UUID] = [:]
        /// Distinguishes this uplink from the one it replaced, so the old one ending
        /// does not take the new one down with it.
        var generation: UUID
    }

    private let handler: any ControlHandling
    private var homeHost: HostID?
    private var clients: [UUID: ClientSession] = [:]
    private var hosts: [HostID: HostSession] = [:]
    private var known: Set<HostID>
    private var states: [HostID: HostState] = [:]
    /// Where each client last said the person was. One record per client, across every
    /// host that client has a channel to (058, R6).
    private var notedPresence: [UUID: NotedPresence] = [:]

    private struct NotedPresence {
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
        var flags: [UUID: Bool] = [:]
        for (id, note) in notedPresence {
            if let may = note.mayNotify { flags[id] = may }
        }
        return flags
    }

    private func notePresence(client: UUID, grant: Grant, report: DaemonAPI.PresenceReport, at: Date = Date()) {
        let surface: Surface = grant == .device ? .device(client) : .mac
        let previous = notedPresence[client]
        notedPresence[client] = NotedPresence(surface: surface, watching: report.watching, active: report.active,
                                              heardAt: at, mayNotify: report.mayNotify ?? previous?.mayNotify)
    }

    public func sessions(of client: UUID) -> [UUID] {
        clients.filter { $0.value.caller.client == client }.map(\.key)
    }

    /// The channels open on a host's uplink, for tests and for Settings.
    public func channels(of host: HostID) -> [Int] {
        hosts[host].map { Array($0.channels.keys).sorted() } ?? []
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

    /// A host's uplink is up. Opens a channel to it for every client session, then reads
    /// it until it ends.
    public func attachHost(_ host: HostID, transport: any LineTransport) {
        if hosts[host] != nil { dropHost(host, generation: nil, newState: nil) }
        known.insert(host)
        let generation = UUID()
        hosts[host] = HostSession(transport: transport, generation: generation)
        setState(.online, of: host)
        for session in clients.keys { openChannel(for: session, to: host) }
        Task { [weak self] in
            do {
                for try await line in transport.lines() { await self?.hostLine(line, from: host) }
            } catch {}
            await self?.dropHost(host, generation: generation, newState: .offline(since: Date()))
        }
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
        for (_, sessionID) in session.channels { clients[sessionID]?.channels[host] = nil }
        if let newState { setState(newState, of: host) }
    }

    private func hostLine(_ line: String, from host: HostID) async {
        guard let frame = try? ControlWire.readHost(line) else { return }
        switch frame {
        case .message(0, let message):
            await channelZero(message, from: host)
        case .message(let channel, let message):
            guard let sessionID = hosts[host]?.channels[channel], let session = clients[sessionID] else { return }
            if session.wrapped {
                write(ControlWire.wrap(host: host, message: message), to: sessionID)
            } else if host == homeHost {
                write(message, to: sessionID)
            }
        case .close(let channel):
            // The host hung up on a client (a device it was told to forget, say). The
            // client's whole connection goes, as it would have today.
            guard let sessionID = hosts[host]?.channels.removeValue(forKey: channel) else { return }
            detachClient(sessionID)
        case .open:
            // Only the control plane opens channels. A host that tries is ignored.
            return
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
    public func attachClient(_ client: ClientRecord, transport: any LineTransport) -> UUID {
        let id = UUID()
        clients[id] = ClientSession(caller: Caller(session: id, client: client.id, grant: client.grant, kind: client.kind),
                                    transport: transport)
        for host in hosts.keys { openChannel(for: id, to: host) }
        Task { [weak self] in
            do {
                for try await line in transport.lines() { await self?.clientLine(line, from: id) }
            } catch {}
            await self?.detachClient(id)
        }
        return id
    }

    /// Ends a session: its channels are closed on every host, then its transport.
    public func detachClient(_ id: UUID) {
        guard let session = clients.removeValue(forKey: id) else { return }
        let client = session.caller.client
        if !clients.values.contains(where: { $0.caller.client == client }) {
            notedPresence.removeValue(forKey: client)
        }
        for (host, channel) in session.channels {
            hosts[host]?.channels[channel] = nil
            try? hosts[host]?.transport.write(line: ControlWire.close(channel))
        }
        session.transport.close()
    }

    /// `clients/forget`: every session of that client, at once (FR-008).
    public func forgetClient(_ client: UUID) {
        for id in sessions(of: client) { detachClient(id) }
    }

    /// `clients/setGrant`: the next call is judged by the new grant, and every channel is
    /// reopened so each host judges it by the new one too.
    public func setGrant(_ grant: Grant, of client: UUID) {
        for id in sessions(of: client) {
            guard var session = clients[id] else { continue }
            session.caller.grant = grant
            clients[id] = session
            for host in Array(session.channels.keys) {
                if let channel = clients[id]?.channels.removeValue(forKey: host) {
                    hosts[host]?.channels[channel] = nil
                    try? hosts[host]?.transport.write(line: ControlWire.close(channel))
                }
                openChannel(for: id, to: host)
            }
        }
    }

    private func openChannel(for sessionID: UUID, to host: HostID) {
        guard var hostSession = hosts[host], let caller = clients[sessionID]?.caller else { return }
        let channel = hostSession.nextChannel
        hostSession.nextChannel += 1
        hostSession.channels[channel] = sessionID
        hosts[host] = hostSession
        clients[sessionID]?.channels[host] = channel
        let open = ControlWire.ChannelOpen(grant: caller.grant, client: caller.client.uuidString,
                                           device: caller.grant == .device ? caller.client : nil)
        try? hostSession.transport.write(line: ControlWire.open(channel, open))
    }

    private func clientLine(_ line: String, from sessionID: UUID) {
        guard let frame = try? ControlWire.readClient(line) else { return }
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
                notePresence(client: session.caller.client, grant: session.caller.grant, report: report)
            }
            guard session.caller.grant.allows(method) else {
                return reply(to: sessionID, host: host, id: id, wrapped: wrapped,
                             error: JSONRPCError(code: DaemonAPI.Failure.notPermitted,
                                                 message: "\(method) is not open to this client (\(session.caller.grant.rawValue))."))
            }
            guard known.contains(host) else {
                return reply(to: sessionID, host: host, id: id, wrapped: wrapped,
                             error: JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No host is called \(host.rawValue)."))
            }
            guard let channel = session.channels[host], let uplink = hosts[host] else {
                return reply(to: sessionID, host: host, id: id, wrapped: wrapped,
                             error: JSONRPCError(code: DaemonAPI.Failure.hostOffline, message: "That host is offline."))
            }
            try? uplink.transport.write(line: ControlWire.channel(channel, message: message))
        case .notification(let method, _)?:
            // A notification from a client is held to the same grant; there is nobody
            // to tell when it is refused.
            guard session.caller.grant.allows(method), let channel = session.channels[host] else { return }
            try? hosts[host]?.transport.write(line: ControlWire.channel(channel, message: message))
        case .success?, .failure?:
            // An answer to something the host asked this client. It can invoke nothing.
            guard let channel = session.channels[host] else { return }
            try? hosts[host]?.transport.write(line: ControlWire.channel(channel, message: message))
        case nil:
            // Unreadable, so its grant cannot be checked: it goes nowhere.
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

    private func reply(to sessionID: UUID, host: HostID?, id: JSONRPCID, wrapped: Bool, error: JSONRPCError) {
        guard let line = try? JSONRPCCodec.encode(.failure(id: id, error: error)) else { return }
        write(wrapped ? ControlWire.wrap(host: host, message: line) : line, to: sessionID)
    }

    private func write(_ line: String, to sessionID: UUID) {
        guard let session = clients[sessionID] else { return }
        do { try session.transport.write(line: line) } catch { detachClient(sessionID) }
    }

    // MARK: The control plane's own notifications

    /// Tells every client that speaks the wrapped wire, or only operators.
    public func broadcastControl(_ method: String, _ params: JSONValue, operatorsOnly: Bool = false) {
        guard let line = try? JSONRPCCodec.encode(.notification(method: method, params: params)) else { return }
        let wrapped = ControlWire.wrap(host: nil, message: line)
        for (id, session) in clients where session.wrapped && (!operatorsOnly || session.caller.grant == .operator) {
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

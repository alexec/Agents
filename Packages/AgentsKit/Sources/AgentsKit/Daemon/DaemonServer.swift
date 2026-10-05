import Foundation

public enum DaemonServerError: Error, Sendable {
    case socketPathTooLong(Int)
    case cannotCreateSocket(errno: Int32)
    case cannotBind(errno: Int32)
    case cannotListen(errno: Int32)
}

/// The daemon's front door: a Unix socket, and a JSON-RPC connection per window.
///
/// Several connections at once are normal, and all of them get every notification, so
/// two windows agree without either of them being in charge.
public final class DaemonServer: @unchecked Sendable {
    /// Who a request came from. `surface` is the identity presence is reported under —
    /// a window is `.mac`; a connection the bridge opens on behalf of a device is that
    /// device (Slice C) — and it is set by the server, never said by the caller (021).
    public struct ConnectionContext: Hashable, Sendable {
        public var id: UUID
        public var surface: Surface?
        /// The process that connected, as the kernel said when it did. What ties an
        /// agent's token to the helper its own runtime started, rather than to anything
        /// that read the token off `ps`.
        public var peer: Int32?
        /// What the connection is, as the server has it now: a device's rights, or a
        /// pairing phone's, reach the daemon with the request so it can tell them apart.
        public var role: ConnectionRole
        /// A device's channel the control plane opened (058): the control plane paired the
        /// device and vouches for it, so it may record itself here without this Mac's
        /// code (#232).
        public var vouched: Bool

        public init(id: UUID, surface: Surface?, peer: Int32? = nil, role: ConnectionRole = .control,
                    vouched: Bool = false) {
            self.id = id
            self.surface = surface
            self.peer = peer
            self.role = role
            self.vouched = vouched
        }
    }

    public typealias Handler = @Sendable (ConnectionContext, String, JSONValue?) async -> Result<JSONValue, JSONRPCError>

    /// How a connection carried on a control-plane uplink hears broadcasts (#167): with the
    /// others on the same uplink, in one frame naming every channel that should hear it,
    /// which the control plane copies to each. Without one, a notification crossed the
    /// uplink, and the control plane's router, once per client.
    public struct FanOutRoute: Sendable {
        /// Which uplink: connections with the same one share a frame.
        public var uplink: ObjectIdentifier
        public var channel: Int
        /// The uplink's own queue, so its frames go up in the order the daemon said them.
        public var queue: DispatchQueue
        /// Writes one frame for `channels`.
        public var send: @Sendable ([Int], String) throws -> Void

        public init(uplink: ObjectIdentifier, channel: Int, queue: DispatchQueue,
                    send: @escaping @Sendable ([Int], String) throws -> Void) {
            self.uplink = uplink
            self.channel = channel
            self.queue = queue
            self.send = send
        }
    }

    /// The most a connection's notifications may queue before it is given up on (#167). A
    /// client that reads, slowly, never blocks a write for `sendWait`, so without this its
    /// backlog had no end.
    public static let backlogLimit = 8 << 20

    /// One connection's identity, held by the server for the connection's life. It
    /// starts as a window and becomes a device only through `surface/identify`, which
    /// the server reads before the request reaches the daemon — so the daemon never
    /// sees a surface a caller merely claimed in some other request's parameters.
    final class ConnectionIdentity: @unchecked Sendable {
        let id = UUID()
        let peer: Int32?

        /// Set once, before a line is read, by the uplink alone.
        let vouched: Bool

        init(peer: Int32?, role: ConnectionRole = .control, vouched: Bool = false) {
            self.peer = peer
            self.vouched = vouched
            _role = role
        }

        private let lock = NSLock()
        private var _surface: Surface? = .mac
        private var _role: ConnectionRole
        private var _device: UUID?

        var surface: Surface? {
            get { lock.lock(); defer { lock.unlock() }; return _surface }
            set { lock.lock(); defer { lock.unlock() }; _surface = newValue }
        }

        /// What this connection may ask for: decided from who made it, and lowered to a
        /// device's once the bridge says it carries one. Never raised.
        var role: ConnectionRole {
            lock.lock(); defer { lock.unlock() }; return _role
        }

        /// A window's connection becomes a device's, for good. Only a window's may: a
        /// helper or a stranger that could say this would be choosing its own rights.
        func bindDevice(_ device: UUID?, pairing: Bool = false) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard _role == .control else { return false }
            _role = pairing ? .pairing : .device
            if let device {
                _device = device
                _surface = .device(device)
            }
            return true
        }

        /// Whether a device's connection may call itself `claimed`. The first id a bound
        /// connection names is the only one it may ever use; a window may name any, as
        /// it always could.
        func mayClaim(_ claimed: UUID) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard _role == .device || _role == .pairing else { return true }
            if let _device { return _device == claimed }
            _device = claimed
            _surface = .device(claimed)
            return true
        }

        var context: ConnectionContext {
            ConnectionContext(id: id, surface: surface, peer: peer, role: role, vouched: vouched)
        }
    }

    private let url: URL
    private let handler: Handler
    private let roles: RolePolicy
    /// Readable inside the module so a test can ask whether it would survive an exec.
    /// There is no other way to see the flag: it only shows itself in a child.
    private(set) var listenFD: Int32 = -1
    private let connections = ConnectionSet()
    private let stopped = ManagedAtomicFlag()
    /// Lines a caller could have said every few seconds: once, then a count (#168).
    private let repeated = NSLock()
    private var notices = RepeatedNotice()
    private let onConnectionCountChanged: @Sendable (Int) -> Void
    /// A connection that has gone, by id. What is known about where its person was
    /// goes with it: gone is more truthful than stale (021).
    private let onDisconnected: @Sendable (UUID) -> Void
    private let backlogLimit: Int

    public init(url: URL,
                onConnectionCountChanged: @escaping @Sendable (Int) -> Void = { _ in },
                onDisconnected: @escaping @Sendable (UUID) -> Void = { _ in },
                roles: RolePolicy = .open,
                backlogLimit: Int = DaemonServer.backlogLimit,
                handler: @escaping Handler) {
        self.url = url
        self.backlogLimit = backlogLimit
        self.handler = handler
        self.roles = roles
        self.onConnectionCountChanged = onConnectionCountChanged
        self.onDisconnected = onDisconnected
    }

    public func start() throws {
        // sockaddr_un has room for 104 bytes and not one more, which is easy to exceed
        // with a temporary directory and worth saying plainly rather than truncating.
        let path = url.path
        guard path.utf8.count < 104 else { throw DaemonServerError.socketPathTooLong(path.utf8.count) }

        // The root is private to this account, whoever made it and wherever it is. A
        // scratch root under /tmp was otherwise readable by every account on the Mac,
        // transcripts and all.
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw DaemonServerError.cannotCreateSocket(errno: errno) }
        // The front door belongs to this process. A child holding a copy of it keeps
        // the socket answering after the daemon has gone, so the window connects to
        // nobody and waits for a reply that is never coming. Darwin has no
        // SOCK_CLOEXEC, so it is asked for the moment there is something to ask about.
        setCloseOnExec(listenFD)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bound == 0 else {
            close(listenFD)
            throw DaemonServerError.cannotBind(errno: errno)
        }
        // Only this account may connect. Connecting takes write permission on the
        // socket, and `bind` made it with whatever the umask left.
        chmod(path, 0o600)
        // The kernel's most, not 16: after a restart every helper, the bridge, the window and
        // Agents Host dial at once, and a burst of 200 had 111 refused (#172).
        guard listen(listenFD, SOMAXCONN) == 0 else {
            close(listenFD)
            throw DaemonServerError.cannotListen(errno: errno)
        }

        let listenFD = self.listenFD
        let stopped = self.stopped
        let thread = Thread { [weak self] in
            let failures = AcceptFailures(name: "socket")
            while true {
                let fd = accept(listenFD, nil, nil)
                if fd < 0 {
                    // Not the end of the listener unless it was closed (#201): one
                    // descriptor spike used to leave daemon.sock taking nobody, for good.
                    let error = errno
                    if stopped.isSet { return }
                    if failures.after(error, listener: listenFD) == .stop {
                        DaemonLog.shared.write("socket: the listener failed (\(String(cString: strerror(error)))); no more connections")
                        return
                    }
                    continue
                }
                failures.accepted()
                // accept() hands back a descriptor with the flag clear however the
                // listener was opened, so each window's connection says it again.
                // This is the one a long-lived shell is most likely to be handed: a
                // window connects, an agent starts a terminal, and the window's
                // connection is held open by a shell that will never read it.
                setCloseOnExec(fd)
                // Said by the kernel, not the caller: another account is turned away
                // before it can send a line, whatever the socket's mode has become.
                guard PeerCredentials.uid(of: fd) == geteuid() else { close(fd); continue }
                DaemonServer.limitSendWait(fd)
                guard let self, !self.stopped.isSet else { close(fd); return }
                self.accepted(fd, peer: PeerCredentials.pid(of: fd), role: self.roles.role(fd))
            }
        }
        thread.name = "AgentsKit.DaemonServer"
        thread.start()
    }

    private func accepted(_ fd: Int32, peer: Int32?, role: ConnectionRole) {
        // Only what is not a window: a window connects all day, and a helper or a
        // stranger is what anybody reading the log about the socket is looking for.
        // A helper connects once per tool call, which is worth a line each; a stranger or
        // Agents Host the same pid again and again, which is said once and then counted.
        let line = "socket: pid \(peer.map(String.init) ?? "?") connected as \(role.rawValue)"
        switch role {
        case .control: break
        case .agent: DaemonLog.shared.write(line)
        default: sayOnce(line)
        }
        // Everything that reaches this socket is a window on this Mac, until the bridge
        // exists to say otherwise: helpers and probes that connect here never report
        // presence, and a window that does is the Mac.
        serve(FDTransport(socket: fd, maximumLine: FDTransport.clientLineLimit),
              identity: ConnectionIdentity(peer: peer, role: role))
    }

    /// `line` the first time, then how many more times it came, at most once an hour.
    private func sayOnce(_ line: String) {
        let now = Date()
        let say = repeated.withLock { notices.note(line, at: now) }
        switch say {
        case .first?:
            DaemonLog.shared.write(line + " (again within the hour is counted, not logged)")
        case .again(let times, let since)?:
            DaemonLog.shared.write(line + ": \(times) more time\(times == 1 ? "" : "s") since "
                                   + ISO8601DateFormatter().string(from: since))
        case nil:
            break
        }
    }

    /// A channel the control plane opened on this host's uplink (058, R3): one virtual
    /// connection, the same in every respect as one accepted on the socket. It may do
    /// everything a window may (#111). One for a phone, an iPad or a browser is bound to
    /// that device before a line of it is read, exactly as the bridge binds one today, so
    /// it reports presence as itself and speaks for no other device. Nothing else can
    /// make one.
    ///
    /// `ended` is called once the connection is gone, from either end.
    ///
    /// `fanOut`, when the control plane reads fan-out frames: how broadcasts reach it.
    public func acceptVirtual(_ transport: any LineTransport, device: UUID?, fanOut: FanOutRoute? = nil,
                              ended: @escaping @Sendable () -> Void = {}) {
        let identity = ConnectionIdentity(peer: nil, role: .control, vouched: device != nil)
        if let device { _ = identity.bindDevice(device) }
        DaemonLog.shared.write("uplink: a channel opened for \(device.map { "device \($0.uuidString)" } ?? "a window")")
        serve(transport, identity: identity, fanOut: fanOut, ended: ended)
    }

    private func serve(_ transport: any LineTransport, identity: ConnectionIdentity, fanOut: FanOutRoute? = nil,
                       ended: @escaping @Sendable () -> Void = {}) {
        let handler = self.handler
        let connection = JSONRPCConnection(transport: transport) { method, params in
            // Refused by the server, before the daemon hears of it: a helper asking for
            // what only a person may, or a shell asking for anything at all.
            let role = identity.role
            guard role.allows(method) else {
                // A phone refused is a phone that does less than it did, and the phone's
                // own screen is the only other place that would say so.
                if role == .pairing {
                    self.sayOnce("socket: refused \(method) to a \(role.rawValue) connection")
                }
                return .failure(JSONRPCError(code: DaemonAPI.Failure.notPermitted,
                                             message: "\(method) is not open to this connection (\(role.rawValue))."))
            }
            // The bridge saying this connection carries a device. The server's business
            // alone: the daemon never hears it, only the rights that follow from it.
            if method == DaemonAPI.Method.connectionBindDevice {
                let binding = (try? params?.decode(DaemonAPI.DeviceBinding.self)) ?? DaemonAPI.DeviceBinding(id: nil)
                guard identity.bindDevice(binding.id, pairing: binding.pairing == true) else {
                    return .failure(JSONRPCError(code: DaemonAPI.Failure.notPermitted,
                                                 message: "Only a window's connection can be given to a device."))
                }
                DaemonLog.shared.write(binding.pairing == true
                    ? "socket: a connection now carries a device that is pairing"
                    : "socket: a connection now carries device \(binding.id?.uuidString ?? "(not yet named)")")
                if binding.pairing != true { self.tellMoved(identity.id) }
                return .success([:])
            }
            // A device naming itself, by saying which it is or announcing its key. On a
            // device's connection the first name is the only one: a phone cannot speak
            // as another phone, or announce a key under another phone's id.
            if method == DaemonAPI.Method.surfaceIdentify || method == DaemonAPI.Method.devicesAnnounce,
               let claimed = (try? params?.decode(ClaimedDevice.self))?.id,
               !identity.mayClaim(claimed) {
                return .failure(JSONRPCError(code: DaemonAPI.Failure.notPermitted,
                                             message: "This connection is another device's."))
            }
            // A device saying which it is. The server sets the identity here, once,
            // and only then hands the request on — so what the daemon registers under
            // is what every later request on this connection will carry (021 T051).
            if method == DaemonAPI.Method.surfaceIdentify,
               let who = try? params?.decode(DaemonAPI.SurfaceIdentification.self) {
                identity.surface = .device(who.id)
                if identity.role == .device { self.tellMoved(identity.id) }
            }
            return await handler(identity.context, method, params)
        }
        connections.add(connection, queue: DispatchQueue(label: "com.alexecollins.agents.broadcast.\(identity.id)"),
                        identity: identity, fanOut: fanOut)
        onConnectionCountChanged(connections.count)
        Task {
            await connection.start()
            // The connection ends when the window goes. Which it will: quitting the
            // app is the ordinary case, not the exceptional one.
            for await _ in connection.incomingNotifications() {}
            // The stream ending says the other side hung up; it does not close our
            // descriptor, and nothing else will. Left open, every window, phone and
            // helper that ever connected costs the daemon one descriptor for the rest
            // of its life, until `accept` fails and the front door is shut with the
            // daemon still standing behind it — 2,422 of them, one Sunday morning.
            await connection.close()
            self.connections.remove(connection)
            self.onConnectionCountChanged(self.connections.count)
            self.onDisconnected(identity.id)
            ended()
        }
    }

    /// Tell every window at once.
    ///
    /// On one queue of its own, rather than a task per notification. A task each put
    /// the order in the runtime's hands, and two chunks of a shell's output that
    /// arrive the wrong way round are not slow, they are wrong; one serial queue keeps
    /// them in the order the daemon said them. It is a queue rather than a plain call
    /// because this is reached from inside the actor that owns every agent, and
    /// writing to a socket blocks until the window on the other end reads. A window
    /// that has stopped reading should cost the windows their news, not the daemon its
    /// agents.
    ///
    /// One queue **per connection**, not one for them all. With one, a window that
    /// stopped reading blocked the queue on its write, and every other window and the
    /// bridge stopped hearing anything while the backlog grew without bound. Each
    /// connection's own queue keeps its own order, which is the only order that
    /// matters; and a write that cannot finish in `sendWait` fails, the connection is
    /// closed, and the client reconnects and asks for everything again — which a
    /// window already does whenever its connection goes.
    ///
    /// Encoded once and the same line written to each. A shell's output is a
    /// notification per chunk, and with the Mac, the phone and the bridge listening it
    /// was being turned into JSON once per listener. The encoding is on a serial queue
    /// of its own, not the caller's, because the caller is the actor that owns every
    /// agent; serial, and handing on in the order it was given, so each connection's
    /// queue still receives what the daemon said in the order it said it.
    public func broadcast(_ method: String, _ params: JSONValue?) {
        broadcast(method, params, to: { _ in true })
    }

    /// After a move (058, T085): a device that connects the old way, through the bridge or
    /// the relay, is told where the control plane is now, once it has said which it is.
    /// A moment later, so the answer to what it asked goes first.
    private func tellMoved(_ connection: UUID) {
        let file = url.deletingLastPathComponent().appendingPathComponent("control-moved.json")
        guard let data = try? Data(contentsOf: file), let moved = try? JSONValue.parse(data) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.broadcast(DaemonAPI.Notification.controlMoved, moved, to: { $0.id == connection })
            DaemonLog.shared.write("socket: told a device where the control plane is now")
        }
    }

    /// Tell only the connections `wanted` picks, in the same order and on the same
    /// queues as everything else they are told (034).
    ///
    /// For what belongs to somebody: the folder a phone is watching, the shell it has
    /// open. The rest of what the daemon says still goes to everyone. A phone on WiFi
    /// should not carry an unrelated agent's build output because a Mac window happens
    /// to have that shell open.
    ///
    /// Through the same encoding queue as everything else, so a connection that hears
    /// some notifications this way and the rest the other way still hears them all in
    /// the order the daemon said them.
    public func broadcast(_ method: String, _ params: JSONValue?,
                          to wanted: @escaping @Sendable (ConnectionContext) -> Bool) {
        encoding.async { [connections, backlogLimit] in
            let targets = connections.allAddressed.filter { $0.role.hearsNotifications && wanted($0.context) }
            guard !targets.isEmpty,
                  let line = try? JSONRPCCodec.encode(.notification(method: method, params: params))
            else { return }
            // Those on a control-plane uplink: one frame per uplink, naming who hears it (#167).
            var routed: [ObjectIdentifier: (FanOutRoute, [Int], [JSONRPCConnection])] = [:]
            for target in targets {
                guard let route = target.fanOut else { continue }
                routed[route.uplink, default: (route, [], [])].1.append(route.channel)
                routed[route.uplink]?.2.append(target.connection)
            }
            for (route, channels, carried) in routed.values {
                route.queue.async {
                    do {
                        try route.send(channels.sorted(), line)
                    } catch {
                        // The uplink is gone or gave up: every channel on it has missed this.
                        for connection in carried { Task { await connection.close() } }
                    }
                }
            }
            let size = line.utf8.count
            for target in targets where target.fanOut == nil {
                let connection = target.connection
                // A reader that has fallen this far behind is closed rather than queued for
                // without end; it reconnects and reads everything afresh (#167).
                guard connections.reserve(size, for: connection, limit: backlogLimit) else {
                    if connections.contains(connection) {
                        DaemonLog.shared.write("socket: closing a connection \(backlogLimit >> 20) MB behind")
                    }
                    Task { await connection.close() }
                    continue
                }
                target.queue.async {
                    defer { connections.release(size, for: connection) }
                    do {
                        try connection.notify(line: line)
                    } catch {
                        // Closed, or stuck past the wait. Either way this connection has
                        // missed something, and a client that carried on would be showing
                        // a list that is no longer true. Half a line may also be on the
                        // wire. Closing is what tells it to start again.
                        Task { await connection.close() }
                    }
                }
            }
        }
    }

    private let encoding = DispatchQueue(label: "com.alexecollins.agents.broadcast.encode")

    /// End the connections `wanted` picks. The other end sees its connection go, as it
    /// would if the daemon had quit, and a bridge takes the device's link down with it.
    public func closeConnections(where wanted: @escaping @Sendable (ConnectionContext) -> Bool) {
        for target in connections.allAddressed where wanted(target.context) {
            Task { await target.connection.close() }
        }
    }

    /// How long a write to one client may block before that client is given up on.
    /// Long enough for a window busy for a moment; a client that has read nothing for
    /// this long has stopped.
    static let sendWait = timeval(tv_sec: 10, tv_usec: 0)

    /// Bound every blocking write on this descriptor by `sendWait`.
    static func limitSendWait(_ fd: Int32) {
        var wait = sendWait
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    }

    public var connectionCount: Int { connections.count }

    /// Bytes queued for each connection and not yet written, for tests (#167).
    var backlogs: [Int] { connections.backlogs }

    public func stop() {
        guard stopped.set() else { return }
        if listenFD >= 0 { close(listenFD) }
        unlink(url.path)
        for connection in connections.all {
            Task { await connection.close() }
        }
    }
}

/// The one field `surface/identify` and `devices/announce` share: which device.
private struct ClaimedDevice: Decodable {
    var id: UUID
}

final class ConnectionSet: @unchecked Sendable {
    struct Addressed {
        var connection: JSONRPCConnection
        var queue: DispatchQueue
        var context: DaemonServer.ConnectionContext
        var role: ConnectionRole
        var fanOut: DaemonServer.FanOutRoute?
    }

    private struct Entry {
        var connection: JSONRPCConnection
        /// The queue its notifications go out on, in order.
        var queue: DispatchQueue
        /// Who it is, read as it is sent to: a window becomes a device when it says so,
        /// after it was added here.
        var identity: DaemonServer.ConnectionIdentity
        var fanOut: DaemonServer.FanOutRoute?
        /// Bytes queued for it and not yet written (#167).
        var backlog = 0
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    func add(_ connection: JSONRPCConnection, queue: DispatchQueue,
             identity: DaemonServer.ConnectionIdentity, fanOut: DaemonServer.FanOutRoute? = nil) {
        lock.lock(); defer { lock.unlock() }
        entries[ObjectIdentifier(connection)] = Entry(connection: connection, queue: queue, identity: identity, fanOut: fanOut)
    }

    func remove(_ connection: JSONRPCConnection) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: ObjectIdentifier(connection))
    }

    func contains(_ connection: JSONRPCConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[ObjectIdentifier(connection)] != nil
    }

    /// Counts `size` more bytes queued for `connection`, or says no once that would take a
    /// backlog already waiting past `limit`. A single line larger than it still goes to a
    /// connection with nothing waiting.
    func reserve(_ size: Int, for connection: JSONRPCConnection, limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(connection)
        guard let backlog = entries[key]?.backlog else { return false }
        if backlog > 0, backlog + size > limit { return false }
        entries[key]?.backlog = backlog + size
        return true
    }

    func release(_ size: Int, for connection: JSONRPCConnection) {
        lock.lock(); defer { lock.unlock() }
        entries[ObjectIdentifier(connection)]?.backlog -= size
    }

    /// Bytes waiting for each connection, for tests.
    var backlogs: [Int] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.backlog)
    }

    var allAddressed: [Addressed] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map {
            Addressed(connection: $0.connection, queue: $0.queue, context: $0.identity.context,
                      role: $0.identity.role, fanOut: $0.fanOut)
        }
    }

    var all: [JSONRPCConnection] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.map(\.connection)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}

import Foundation

/// A client's one connection to the control plane, carrying a `DaemonClient` per host
/// (058, R3).
///
/// The window and the Remote keep one `DaemonClient` per host, as the window already
/// did for servers. What changes is where each gets its lines: every host's link here
/// wraps what its client writes with the host's id, and hands it back only what came
/// from that host. The control plane's own client is one more link, with no host.
///
/// A host's link ends when the control plane says the host went offline, so its
/// client runs the reconnect it runs today; and every link ends when the connection
/// itself does, the next `transport()` dialling again.
public final class ControlLink: @unchecked Sendable {
    public typealias Dial = @Sendable () async throws -> any LineTransport

    private let dial: Dial
    private let lock = NSLock()
    private var physical: (any LineTransport)?
    private var generation = 0
    private var dialling: Task<any LineTransport, any Error>?
    /// Keyed by host; nil is the control plane itself.
    private var routes: [HostID?: Virtual] = [:]
    private var unreadableFrames = 0

    /// Frames from the control plane that could not be read, each also logged (#93).
    public var unreadableFrameCount: Int { lock.withLock { unreadableFrames } }

    public init(dial: @escaping Dial) {
        self.dial = dial
    }

    /// The link a host's `DaemonClient` is made with.
    public func link(for host: HostID) -> some DaemonLink { Route(owner: self, host: host) }

    /// The link the control plane's own `DaemonClient` is made with.
    public var controlLink: some DaemonLink { Route(owner: self, host: nil) }

    /// Ends every route and the connection. The next `transport()` dials again.
    public func disconnect() {
        lock.lock()
        let old = physical
        physical = nil
        generation += 1
        let ended = routes
        routes = [:]
        lock.unlock()
        old?.close()
        for (_, virtual) in ended { virtual.finish() }
    }

    struct Route: DaemonLink {
        let owner: ControlLink
        let host: HostID?
        func transport() async throws -> any LineTransport {
            try await owner.open(host)
        }
    }

    // MARK: Routes

    private func open(_ host: HostID?) async throws -> any LineTransport {
        let physical = try await connected()
        let virtual = Virtual(host: host, physical: physical)
        let replaced = lock.withLock { routes.updateValue(virtual, forKey: host) }
        replaced?.finish()
        return virtual
    }

    private func connected() async throws -> any LineTransport {
        let task: Task<any LineTransport, any Error> = lock.withLock {
            if let physical { return Task { physical } }
            if let dialling { return dialling }
            let dial = self.dial
            let task = Task { try await dial() }
            dialling = task
            return task
        }
        do {
            let transport = try await task.value
            return lock.withLock {
                if dialling == task {
                    dialling = nil
                    physical = transport
                    generation += 1
                    pump(transport, generation: generation)
                }
                return physical ?? transport
            }
        } catch {
            lock.withLock { if dialling == task { dialling = nil } }
            throw error
        }
    }

    private func pump(_ transport: any LineTransport, generation: Int) {
        Task.detached { [weak self] in
            do {
                for try await line in transport.lines() { self?.deliver(line) }
            } catch {}
            self?.ended(generation: generation)
        }
    }

    private func deliver(_ line: String) {
        let frame: ControlWire.ClientFrame
        do {
            frame = try ControlWire.readClient(line)
        } catch {
            // Which route it was for cannot be told, so nobody can be answered; said,
            // at least, rather than vanishing (#93).
            lock.withLock { unreadableFrames += 1 }
            WireLog.write("control link: unreadable frame from the control plane (\(error)): \(WireLog.excerpt(line))")
            return
        }
        switch frame {
        case .toHost(let host, let message):
            route(host)?.yield(message)
        case .toControl(let message):
            route(nil)?.yield(message)
            // A host gone offline ends its route, so its client notices at once
            // rather than when a ping times out.
            if message.contains(DaemonAPI.Notification.controlHostChanged),
               case .notification(_, let params)? = try? JSONRPCCodec.decode(line: message),
               let host = params?["host"]?.stringValue, let state = params?["state"]?.stringValue,
               state != "online", state != "connecting" {
                let id = HostID(rawValue: host)
                lock.lock()
                let gone = routes.removeValue(forKey: id)
                lock.unlock()
                gone?.finish()
            }
        case .legacy:
            // A control plane always wraps what it sends a client that wraps.
            return
        }
    }

    private func route(_ host: HostID?) -> Virtual? {
        lock.lock()
        defer { lock.unlock() }
        return routes[host]
    }

    private func ended(generation ended: Int) {
        lock.lock()
        guard ended == generation else { lock.unlock(); return }
        physical = nil
        let gone = routes
        routes = [:]
        lock.unlock()
        for (_, virtual) in gone { virtual.finish() }
    }

    /// One host's view of the connection: writes are wrapped with its id, reads are
    /// what the control plane passed on from it.
    final class Virtual: LineTransport, @unchecked Sendable {
        let host: HostID?
        private let physical: any LineTransport
        private let stream: AsyncThrowingStream<String, any Error>
        private let continuation: AsyncThrowingStream<String, any Error>.Continuation
        private let closed = ManagedAtomicFlag()

        init(host: HostID?, physical: any LineTransport) {
            self.host = host
            self.physical = physical
            var c: AsyncThrowingStream<String, any Error>.Continuation!
            self.stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
            self.continuation = c
        }

        func yield(_ line: String) { continuation.yield(line) }

        func finish() {
            closed.set()
            continuation.finish()
        }

        func write(line: String) throws {
            guard !closed.isSet else { throw JSONRPCTransportError.closed }
            try physical.write(line: ControlWire.wrap(host: host, message: line))
        }

        func lines() -> AsyncThrowingStream<String, any Error> { stream }

        /// Closing a host's route does not close the connection: the other hosts are
        /// still on it.
        func close() { finish() }
    }
}

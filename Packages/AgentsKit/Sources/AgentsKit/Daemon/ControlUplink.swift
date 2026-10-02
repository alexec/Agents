import AgentsKitCore
import Foundation

/// A host's one connection out to its control plane (058, R3; FR-010, FR-011).
///
/// The control plane opens a channel on it for each client, and each channel becomes a
/// virtual connection to this daemon's `DaemonServer`, with everything a socket
/// connection has. Channel 0 is the host's own conversation with the control plane:
/// `host/hello` on every connect.
///
/// Losing the uplink closes every channel and nothing else: agents carry on, and it
/// dials again, waiting a second, then twice as long each time up to half a minute.
public final class ControlUplink: @unchecked Sendable {
    public typealias Dial = @Sendable () async throws -> any LineTransport

    private let server: DaemonServer
    private let hello: DaemonAPI.HostHello
    private let dial: Dial
    private let lock = NSLock()
    private var channels: [Int: Channel] = [:]
    private var uplink: (any LineTransport)?
    private var task: Task<Void, Never>?
    private let stopped = ManagedAtomicFlag()
    private var nextHello = 1
    /// Said each time the uplink comes up or goes, for the log and for tests.
    private let onChange: @Sendable (Bool) -> Void
    /// A lending Mac's (058, T091): the loopback port of its relay for a runtime's sign-in.
    private var lendingPort: (@Sendable (String) async -> UInt16?)?
    /// A borrowing host's tunnels asked for and not yet opened, by reference, and the
    /// request each was asked with.
    private var waitingTunnels: [String: CheckedContinuation<any LineTransport, any Error>] = [:]
    private var tunnelAsks: [Int: String] = [:]

    public static let firstWait: Duration = .seconds(1)
    public static let longestWait: Duration = .seconds(30)
    /// The wait between dials, which `goBackNow()` cuts short (#82).
    private let backoff: Backoff

    public init(server: DaemonServer, hello: DaemonAPI.HostHello,
                onChange: @escaping @Sendable (Bool) -> Void = { _ in },
                backoff: Backoff = Backoff(first: ControlUplink.firstWait, longest: ControlUplink.longestWait),
                dial: @escaping Dial) {
        self.server = server
        self.backoff = backoff
        self.hello = hello
        self.dial = dial
        self.onChange = onChange
    }

    public func start() {
        guard task == nil else { return }
        task = Task.detached { [weak self] in await self?.run() }
    }

    public func stop() {
        guard stopped.set() else { return }
        task?.cancel()
        let (old, open) = lock.withLock { () -> ((any LineTransport)?, [Channel]) in
            defer { uplink = nil; channels = [:] }
            return (uplink, Array(channels.values))
        }
        old?.close()
        for channel in open { channel.end(tellingTheControlPlane: false) }
    }

    /// Where this host's relays listen, when it lends a sign-in (T091).
    public func setLendingPort(_ port: @escaping @Sendable (String) async -> UInt16?) {
        lock.withLock { lendingPort = port }
    }

    /// A tunnel to the host that lends this one `runtime`'s sign-in (T091): asked of the
    /// control plane on channel 0, which opens it only for a lend an operator allowed.
    public func openTunnel(runtime: String) async throws -> any LineTransport {
        let ref = UUID().uuidString.lowercased()
        let result = try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<any LineTransport, any Error>) in
            let (transport, id) = lock.withLock { () -> ((any LineTransport)?, Int) in
                let id = nextHello
                nextHello += 1
                waitingTunnels[ref] = waiting
                tunnelAsks[id] = ref
                return (uplink, id)
            }
            guard let transport,
                  let line = try? JSONRPCCodec.encode(.request(id: .number(id), method: DaemonAPI.Method.tunnelOpen,
                                                               params: try JSONValue.encoding(DaemonAPI.TunnelOpen(runtime: runtime, ref: ref)))),
                  (try? transport.write(line: ControlWire.channel(0, message: line))) != nil else {
                finishTunnel(ref, .failure(TunnelPipe.Failure("this host is not connected to its control plane")))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finishTunnel(ref, .failure(TunnelPipe.Failure("the control plane did not open the tunnel")))
            }
        }
        return result
    }

    private func finishTunnel(_ ref: String, _ result: Result<any LineTransport, any Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<any LineTransport, any Error>? in
            tunnelAsks = tunnelAsks.filter { $0.value != ref }
            return waitingTunnels.removeValue(forKey: ref)
        }
        waiting?.resume(with: result)
    }

    /// A tunnel channel opened by the control plane: the borrower's, for the connection
    /// that asked; the lender's, to its relay on loopback.
    private func tunnelOpened(_ number: Int, runtime: String, ref: String?, on transport: any LineTransport) {
        let channel = Channel(number: number, uplink: transport)
        channel.onEnd = { [weak self] in _ = self?.lock.withLock { self?.channels.removeValue(forKey: number) } }
        let replaced = lock.withLock { channels.updateValue(channel, forKey: number) }
        replaced?.end(tellingTheControlPlane: false)
        if let ref {
            finishTunnel(ref, .success(channel))
            return
        }
        let port = lock.withLock { lendingPort }
        Task.detached {
            guard let port, let relay = await port(runtime) else {
                DaemonLog.shared.write("relay: asked to lend \(runtime)'s sign-in, which this host does not relay")
                channel.end(tellingTheControlPlane: true)
                return
            }
            do {
                TunnelPipe.pump(try TunnelPipe.connectLoopback(port: relay), channel)
                DaemonLog.shared.write("relay: a tunnel for \(runtime) opened")
            } catch {
                DaemonLog.shared.write("relay: \(error)")
                channel.end(tellingTheControlPlane: true)
            }
        }
    }

    /// The network changed or the machine woke (#82): a wait between dials ends now, and
    /// the next is a second again. A dial in flight is left to finish.
    @discardableResult
    public func goBackNow() -> Backoff.Nudged {
        backoff.nudge()
    }

    /// The channels open now, for tests.
    public var openChannels: [Int] { lock.withLock { channels.keys.sorted() } }

    private func run() async {
        while !stopped.isSet && !Task.isCancelled {
            backoff.trying()
            do {
                let transport = try await dial()
                backoff.settle()
                lock.withLock { uplink = transport }
                try? sayHello(on: transport)
                DaemonLog.shared.write("uplink: connected to the control plane")
                onChange(true)
                do {
                    for try await line in transport.lines() { receive(line, from: transport) }
                } catch {}
                transport.close()
                let open = lock.withLock { () -> [Channel] in
                    defer { uplink = nil; channels = [:] }
                    return Array(channels.values)
                }
                for channel in open { channel.end(tellingTheControlPlane: false) }
                DaemonLog.shared.write("uplink: the control plane went; \(open.count) channels closed")
                onChange(false)
            } catch {
                DaemonLog.shared.write("uplink: could not reach the control plane: \(error)")
            }
            guard !stopped.isSet else { return }
            await backoff.wait()
        }
    }

    /// `attention/need` and anything else a host says on channel 0. Dropped when the
    /// uplink is down; the next decision says it again.
    public func tell(_ method: String, _ params: JSONValue) {
        let (transport, id) = lock.withLock { () -> ((any LineTransport)?, Int) in
            let id = nextHello
            nextHello += 1
            return (uplink, id)
        }
        guard let transport,
              let line = try? JSONRPCCodec.encode(.request(id: .number(id), method: method, params: params))
        else { return }
        try? transport.write(line: ControlWire.channel(0, message: line))
    }

    private func sayHello(on transport: any LineTransport) throws {
        let id = lock.withLock { () -> Int in defer { nextHello += 1 }; return nextHello }
        let line = try JSONRPCCodec.encode(.request(id: .number(id), method: DaemonAPI.Method.hostHello,
                                                    params: try JSONValue.encoding(hello)))
        try transport.write(line: ControlWire.channel(0, message: line))
    }

    private func receive(_ line: String, from transport: any LineTransport) {
        guard let frame = try? ControlWire.readHost(line) else { return }
        switch frame {
        case .open(let number, let open):
            guard number > 0 else { return }
            if let runtime = open.tunnel {
                tunnelOpened(number, runtime: runtime, ref: open.tunnelRef, on: transport)
                return
            }
            let channel = Channel(number: number, uplink: transport)
            let replaced = lock.withLock { channels.updateValue(channel, forKey: number) }
            replaced?.end(tellingTheControlPlane: false)
            server.acceptVirtual(channel, grant: open.grant, device: open.device) { [weak self] in
                self?.ended(channel)
            }
        case .close(let number):
            let channel = lock.withLock { channels.removeValue(forKey: number) }
            channel?.end(tellingTheControlPlane: false)
        case .message(0, let message):
            // Replies to `host/hello` and `control/ping`, which nothing waits on; and to
            // `tunnel/open`, whose refusal ends the wait for it.
            if case .failure(.number(let id), let error)? = try? JSONRPCCodec.decode(line: message),
               let ref = lock.withLock({ tunnelAsks[Int(id)] }) {
                finishTunnel(ref, .failure(error))
            }
            return
        case .message(let number, let message):
            lock.withLock { channels[number] }?.yield(message)
        }
    }

    private func ended(_ channel: Channel) {
        let wasOpen = lock.withLock { () -> Bool in
            guard channels[channel.number] === channel else { return false }
            channels[channel.number] = nil
            return true
        }
        if wasOpen { channel.end(tellingTheControlPlane: true) }
    }

    /// One client's connection to this daemon, carried on the uplink.
    final class Channel: LineTransport, @unchecked Sendable {
        let number: Int
        private let uplink: any LineTransport
        private let stream: AsyncThrowingStream<String, any Error>
        private let continuation: AsyncThrowingStream<String, any Error>.Continuation
        private let closed = ManagedAtomicFlag()
        /// A tunnel's: take it off the uplink's list when it ends.
        var onEnd: (@Sendable () -> Void)?

        init(number: Int, uplink: any LineTransport) {
            self.number = number
            self.uplink = uplink
            var c: AsyncThrowingStream<String, any Error>.Continuation!
            self.stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
            self.continuation = c
        }

        func yield(_ line: String) { continuation.yield(line) }

        func write(line: String) throws {
            guard !closed.isSet else { throw JSONRPCTransportError.closed }
            try uplink.write(line: ControlWire.channel(number, message: line))
        }

        func lines() -> AsyncThrowingStream<String, any Error> { stream }

        func close() { end(tellingTheControlPlane: true) }

        func end(tellingTheControlPlane: Bool) {
            guard closed.set() else { return }
            continuation.finish()
            if tellingTheControlPlane { try? uplink.write(line: ControlWire.close(number)) }
            onEnd?()
        }
    }
}

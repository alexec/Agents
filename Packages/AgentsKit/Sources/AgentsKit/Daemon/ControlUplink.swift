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

    public static let firstWait: Duration = .seconds(1)
    public static let longestWait: Duration = .seconds(30)

    public init(server: DaemonServer, hello: DaemonAPI.HostHello,
                onChange: @escaping @Sendable (Bool) -> Void = { _ in }, dial: @escaping Dial) {
        self.server = server
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

    /// The channels open now, for tests.
    public var openChannels: [Int] { lock.withLock { channels.keys.sorted() } }

    private func run() async {
        var wait = Self.firstWait
        while !stopped.isSet && !Task.isCancelled {
            do {
                let transport = try await dial()
                wait = Self.firstWait
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
            try? await Task.sleep(for: wait)
            wait = min(wait * 2, Self.longestWait)
        }
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
            let channel = Channel(number: number, uplink: transport)
            let replaced = lock.withLock { channels.updateValue(channel, forKey: number) }
            replaced?.end(tellingTheControlPlane: false)
            server.acceptVirtual(channel, grant: open.grant, device: open.device) { [weak self] in
                self?.ended(channel)
            }
        case .close(let number):
            let channel = lock.withLock { channels.removeValue(forKey: number) }
            channel?.end(tellingTheControlPlane: false)
        case .message(0, _):
            // Replies to `host/hello`, and `control/ping`. Nothing here waits on them.
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
        }
    }
}

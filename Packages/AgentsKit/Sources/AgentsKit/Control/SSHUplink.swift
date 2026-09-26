import AgentsKitCore
import Foundation

/// A host the control plane reaches over ssh, made to look like one that dialled in
/// (058, FR-012, R8, T040).
///
/// The router speaks channels to a host's uplink. A server that cannot dial out has no
/// uplink; what it has is its `daemon.sock`, forwarded to this machine by the ssh master
/// `ServerConnection` keeps. So each channel the router opens becomes a connection of its
/// own to that forward, exactly as the window made one before 058: a device's is bound to
/// the device first, as the bridge binds one. Closing a channel closes its connection.
/// The server's daemon needs nothing new.
final class SSHUplink: LineTransport, @unchecked Sendable {
    private let socket: String
    private let lock = NSLock()
    private var channels: [Int: FDTransport] = [:]
    private let stream: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let closed = ManagedAtomicFlag()

    /// The id a device binding is sent with; its answer is not the client's to hear.
    private static let bindID = "control-bind-device"

    init(socket: URL) {
        self.socket = socket.path
        var c: AsyncThrowingStream<String, any Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    func lines() -> AsyncThrowingStream<String, any Error> { stream }

    func write(line: String) throws {
        guard !closed.isSet else { throw JSONRPCTransportError.closed }
        switch try ControlWire.readHost(line) {
        case .open(let number, let open):
            try openChannel(number, open)
        case .message(let number, let message):
            guard let channel = lock.withLock({ channels[number] }) else { return }
            try channel.write(line: message)
        case .close(let number):
            lock.withLock { channels.removeValue(forKey: number) }?.close()
        }
    }

    /// The forward has gone, or the host was removed: every channel ends, and so does
    /// this uplink, which the router hears as the host going offline.
    func close() {
        guard closed.set() else { return }
        let open = lock.withLock { () -> [FDTransport] in
            defer { channels = [:] }
            return Array(channels.values)
        }
        for channel in open { channel.close() }
        continuation.finish()
    }

    private func openChannel(_ number: Int, _ open: ControlWire.ChannelOpen) throws {
        guard number > 0 else { return }
        let transport = FDTransport(socket: try connectUnixSocket(path: socket))
        if open.grant == .device {
            let bind = try JSONRPCCodec.encode(.request(id: .string(Self.bindID), method: DaemonAPI.Method.connectionBindDevice,
                                                        params: try JSONValue.encoding(DaemonAPI.DeviceBinding(id: open.device))))
            try transport.write(line: bind)
        }
        lock.withLock { channels[number] = transport }
        let continuation = self.continuation
        Task.detached { [weak self] in
            do {
                for try await line in transport.lines() {
                    // The binding's answer is ours, not the device's.
                    if line.contains(Self.bindID) { continue }
                    continuation.yield(ControlWire.channel(number, message: line))
                }
            } catch {}
            guard let self else { return }
            let wasOpen = self.lock.withLock { self.channels.removeValue(forKey: number) != nil }
            if wasOpen, !self.closed.isSet { continuation.yield(ControlWire.close(number)) }
        }
    }
}

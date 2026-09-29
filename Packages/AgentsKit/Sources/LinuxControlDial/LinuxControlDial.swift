import AgentsKitCore
import Foundation
import NIO
import NIOSSL
import NIOTLS

/// A Linux host's way in to a control plane (058, T044).
///
/// The listener speaks TLS 1.2 and only `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`.
/// BoringSSL, inside `swift-nio-ssl`, knows that suite as `ECDHE-PSK-CHACHA20-POLY1305`.
/// The key and the identity are the ones `ControlAgreement` derives, which are the ones
/// the Mac listener derived with CryptoKit.
public enum LinuxControlDial {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    /// The first address that finishes the handshake. Addresses are `host:port`, tried in order.
    public static func connect(_ addresses: [String], identity: String, key: Data) async throws -> any LineTransport {
        var last = Failure("No control plane answered at \(addresses.joined(separator: ", ")). Is it running, and is this machine on its network?")
        for address in addresses {
            guard let colon = address.lastIndex(of: ":"),
                  let port = Int(address[address.index(after: colon)...]),
                  (1...65535).contains(port) else { continue }
            let host = String(address[..<colon])
            guard !host.isEmpty else { continue }
            do {
                return try await dial(host: host, port: port, identity: identity, key: key)
            } catch {
                last = error as? Failure ?? Failure("\(error)")
            }
        }
        throw last
    }

    private static func dial(host: String, port: Int, identity: String, key: Data) async throws -> PSKTransport {
        let keyBytes = [UInt8](key)
        var configuration = TLSConfiguration.makePreSharedKeyConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.maximumTLSVersion = .tlsv12
        configuration.certificateVerification = .none
        configuration.cipherSuites = "ECDHE-PSK-CHACHA20-POLY1305"
        configuration.pskClientProvider = { _ in
            PSKClientIdentityResponse(key: NIOSSLSecureBytes(keyBytes), identity: identity)
        }
        let context = try NIOSSLContext(configuration: configuration)
        let handshake = group.any().makePromise(of: Void.self)
        let gate = Gate()
        var continuation: AsyncThrowingStream<String, any Error>.Continuation!
        let stream = AsyncThrowingStream<String, any Error> { continuation = $0 }
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssl = try NIOSSLClientHandler(context: context, serverHostname: nil)
                    try channel.pipeline.syncOperations.addHandler(ssl)
                    try channel.pipeline.syncOperations.addHandler(
                        LineHandler(handshake: handshake, gate: gate, lines: continuation))
                }
            }
            .connectTimeout(.seconds(5))
            .connect(host: host, port: port)
            .get()
        let timeout = group.any().scheduleTask(in: .seconds(5)) {
            gate.pass { handshake.fail(Failure("the handshake did not finish")) }
        }
        do {
            try await handshake.futureResult.get()
            timeout.cancel()
            return PSKTransport(channel: channel, stream: stream, continuation: continuation)
        } catch {
            timeout.cancel()
            continuation.finish()
            try? await channel.close()
            throw error
        }
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    func pass(_ body: () -> Void) {
        lock.lock()
        let run = open
        open = false
        lock.unlock()
        if run { body() }
    }
}

private final class PSKTransport: LineTransport, @unchecked Sendable {
    private let channel: Channel
    private let stream: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let closed = ManagedAtomicFlag()

    init(channel: Channel, stream: AsyncThrowingStream<String, any Error>,
         continuation: AsyncThrowingStream<String, any Error>.Continuation) {
        self.channel = channel
        self.stream = stream
        self.continuation = continuation
    }

    func write(line: String) throws {
        guard !closed.isSet, channel.isActive else { throw JSONRPCTransportError.closed }
        var buffer = channel.allocator.buffer(capacity: line.utf8.count + 1)
        buffer.writeString(line + "\n")
        channel.writeAndFlush(buffer, promise: nil)
    }

    func lines() -> AsyncThrowingStream<String, any Error> { stream }

    func close() {
        guard closed.set() else { return }
        continuation.finish()
        channel.close(promise: nil)
    }
}

private final class LineHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let handshake: EventLoopPromise<Void>
    let gate: Gate
    let lines: AsyncThrowingStream<String, any Error>.Continuation
    var splitter = LineSplitter()
    let ended = ManagedAtomicFlag()

    init(handshake: EventLoopPromise<Void>, gate: Gate,
         lines: AsyncThrowingStream<String, any Error>.Continuation) {
        self.handshake = handshake
        self.gate = gate
        self.lines = lines
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? TLSUserEvent, case .handshakeCompleted = event {
            gate.pass { handshake.succeed(()) }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        bytes.withUnsafeBufferPointer { splitter.append($0) }
        while let line = splitter.next() { lines.yield(line) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        gate.pass { handshake.fail(error) }
        finish(error)
        context.close(promise: nil)
    }

    private func finish(_ error: Error? = nil) {
        guard ended.set() else { return }
        if let error { lines.finish(throwing: error) } else { lines.finish() }
    }
}

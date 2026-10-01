import Crypto
import Foundation
import NIO
import NIOSSL

/// Dial a Network.framework TLS-PSK listener (058, spike S1).
///
/// The listener speaks TLS 1.2 and only `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`
/// (`LinkTLS.suite`). BoringSSL knows that suite as `ECDHE-PSK-CHACHA20-POLY1305`.
/// `swift-crypto` is linked on purpose: a real dialer would derive the key with it,
/// and the spike is measuring what both libraries add.
enum PSKDial {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5, let port = Int(args[2]) else {
            fputs("usage: psk-dial <host> <port> <identity> <keyhex>\n", stderr)
            exit(2)
        }
        let host = args[1]
        let identity = args[3]
        let key = try hex(args[4])
        // Kept live so the linker cannot drop swift-crypto. The identity is not a secret.
        _ = SHA256.hash(data: Data(identity.utf8))

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? await group.shutdownGracefully() }

        var configuration = TLSConfiguration.makePreSharedKeyConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.maximumTLSVersion = .tlsv12
        configuration.certificateVerification = .none
        configuration.cipherSuites = "ECDHE-PSK-CHACHA20-POLY1305"
        configuration.pskClientProvider = { _ in
            PSKClientIdentityResponse(key: NIOSSLSecureBytes(key), identity: identity)
        }
        let context = try NIOSSLContext(configuration: configuration)
        let ready = group.any().makePromise(of: String.self)

        fputs("connecting\n", stderr)
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssl = try NIOSSLClientHandler(context: context, serverHostname: nil)
                    try channel.pipeline.syncOperations.addHandler(ssl)
                    try channel.pipeline.syncOperations.addHandler(LineHandler(ready: ready))
                }
            }
            .connectTimeout(.seconds(5))
            .connect(host: host, port: port)
            .get()

        let timeout = group.any().scheduleTask(in: .seconds(8)) {
            ready.fail(Failure("the handshake did not finish"))
        }
        let answer = try await ready.futureResult.get()
        timeout.cancel()
        print(answer)
        // The listener closes once it has answered. Closing again is not a failure.
        try? await channel.close()
    }

    private static func hex(_ text: String) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            guard next > index, let byte = UInt8(text[index..<next], radix: 16) else {
                throw Failure("the key is not hex")
            }
            bytes.append(byte)
            index = next
        }
        guard bytes.count == 32 else { throw Failure("the key must be 32 bytes") }
        return bytes
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}

private final class LineHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let ready: EventLoopPromise<String>

    init(ready: EventLoopPromise<String>) { self.ready = ready }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: 5)
        buffer.writeString("ping\n")
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let text = buffer.readString(length: buffer.readableBytes) ?? ""
        if text.contains("ok") {
            ready.succeed("dialed")
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ready.fail(error)
        context.close(promise: nil)
    }
}

try await PSKDial.main()

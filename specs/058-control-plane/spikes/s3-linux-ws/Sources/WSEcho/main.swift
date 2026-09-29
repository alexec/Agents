import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// Spike S3 test server: a WebSocket echo on any path.
//
//   ws-echo <port>                          plain ws:// (behind Caddy)
//   ws-echo <port> --tls <cert.pem> <key.pem>   wss:// with a self-signed certificate
//
// Every text frame comes back as {"echo":<the text>}.

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count == 2 || (args.count == 5 && args[2] == "--tls"), let port = Int(args[1]) else {
    fputs("usage: ws-echo <port> [--tls cert.pem key.pem]\n", stderr)
    exit(2)
}

var sslContext: NIOSSLContext? = nil
if args.count == 5 {
    let chain = try NIOSSLCertificate.fromPEMFile(args[3]).map { NIOSSLCertificateSource.certificate($0) }
    let key = try NIOSSLPrivateKey(file: args[4], format: .pem)
    let tls = TLSConfiguration.makeServerConfiguration(certificateChain: chain, privateKey: .privateKey(key))
    sslContext = try NIOSSLContext(configuration: tls)
}

final class Echo: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var body = frame.unmaskedData
            let text = body.readString(length: body.readableBytes) ?? ""
            print("ws-echo: got \(text)")
            let answer = "{\"echo\":\(text)}"
            var buffer = context.channel.allocator.buffer(capacity: answer.utf8.count)
            buffer.writeString(answer)
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: buffer)), promise: nil)
        case .ping:
            let payload = frame.unmaskedData
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: payload)), promise: nil)
        case .connectionClose:
            let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: context.channel.allocator.buffer(capacity: 0))
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in context.close(promise: nil) }
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("ws-echo: error \(error)")
        context.close(promise: nil)
    }
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        do {
            if let sslContext {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
            }
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                print("ws-echo: upgrade \(head.uri)")
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in channel.pipeline.addHandler(Echo()) })
        return channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
    }

let channel = try bootstrap.bind(host: "0.0.0.0", port: port).wait()
print("ws-echo: listening on \(port)\(sslContext == nil ? "" : " (TLS)")")
try channel.closeFuture.wait()

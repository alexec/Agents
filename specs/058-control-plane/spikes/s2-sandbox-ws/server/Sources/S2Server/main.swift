// Throwaway wss:// echo-ish server for spike S2. Usage: S2Server <cert.pem> <key.pem> <port>
// On each text frame it logs the line and answers with one line: {"server":"got <line>"}.
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import Foundation
import CryptoKit

let args = CommandLine.arguments
guard args.count == 4, let port = Int(args[3]) else { print("usage: S2Server cert key port"); exit(2) }
let certs = try NIOSSLCertificate.fromPEMFile(args[1])
let key = try NIOSSLPrivateKey(file: args[2], format: .pem)
let tls = TLSConfiguration.makeServerConfiguration(certificateChain: certs.map { .certificate($0) }, privateKey: .privateKey(key))
let sslContext = try NIOSSLContext(configuration: tls)

// The pin: SHA-256 of the leaf certificate's SubjectPublicKeyInfo (DER), base64url, no padding.
let spki = try certs[0].extractPublicKey().toSPKIBytes()
let pin = Data(SHA256.hash(data: Data(spki))).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
print("server: spki-sha256 pin \(pin)"); fflush(stdout)

final class WSHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var d = frame.unmaskedData
            let text = d.readString(length: d.readableBytes) ?? ""
            print("server: got line from \(context.remoteAddress?.description ?? "?"): \(text)"); fflush(stdout)
            var buf = context.channel.allocator.buffer(capacity: 64)
            buf.writeString("{\"server\":\"got \(text.replacingOccurrences(of: "\"", with: "'"))\"}")
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: buf)), promise: nil)
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            print("server: close from peer"); fflush(stdout)
            context.close(promise: nil)
        default: break
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("server: error \(error)"); fflush(stdout)
        context.close(promise: nil)
    }
}

final class TLSErrorLogger: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("server: tls/channel error \(error)"); fflush(stdout)
        context.fireErrorCaught(error)
    }
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let upgrader = NIOWebSocketServerUpgrader(
    shouldUpgrade: { ch, head in
        print("server: upgrade request \(head.uri)"); fflush(stdout)
        return ch.eventLoop.makeSucceededFuture(head.uri == "/v1/connect" ? HTTPHeaders() : nil)
    },
    upgradePipelineHandler: { ch, _ in ch.pipeline.addHandler(WSHandler()) })

let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { ch in
        ch.pipeline.addHandler(NIOSSLServerHandler(context: sslContext)).flatMap {
            ch.pipeline.addHandler(TLSErrorLogger())
        }.flatMap {
            ch.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
        }
    }
// Bind on all interfaces so both 127.0.0.1 and the .local address reach it.
let ch = try bootstrap.bind(host: "::", port: port).wait()
print("server: listening on \(ch.localAddress!)"); fflush(stdout)
try ch.closeFuture.wait()

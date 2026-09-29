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

// Spike S3 (058, R7): dial wss://, send one text line, read one back.
//
//   ws-dial wss://host:port/path --ca <root.pem>      trust this root, full verification
//   ws-dial wss://host:port/path --pin <sha256-hex>   accept only this SPKI SHA-256
//
// Exit 0 when a line came back, 1 on any failure (a refused pin included).

func fail(_ message: String) -> Never {
    fputs("ws-dial: \(message)\n", stderr)
    exit(1)
}

func hex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef")
    return String(bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0xf)]] })
}

#if KEEP_FOUNDATION
if keepFoundation.isEmpty { exit(3) }
#endif

let args = CommandLine.arguments
guard args.count == 4, args[1].hasPrefix("wss://"), args[2] == "--ca" || args[2] == "--pin" else {
    fputs("usage: ws-dial wss://host:port/path (--ca root.pem | --pin sha256hex)\n", stderr)
    exit(2)
}

// wss://host[:port][/path]
let rest = args[1].dropFirst("wss://".count)
let authority = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
let path = authority.count > 1 ? "/" + authority[1] : "/"
let hostPort = authority[0].split(separator: ":")
let host = String(hostPort[0])
let port = hostPort.count > 1 ? Int(hostPort[1]) ?? 443 : 443

var tls = TLSConfiguration.makeClientConfiguration()
tls.minimumTLSVersion = .tlsv12
var verifyCallback: NIOSSLCustomVerificationCallback? = nil

if args[2] == "--ca" {
    // (a) As if publicly trusted: the root is the only trust anchor, full verification,
    // hostname included.
    let roots: [NIOSSLCertificate]
    do { roots = try NIOSSLCertificate.fromPEMFile(args[3]) } catch { fail("reading \(args[3]): \(error)") }
    tls.trustRoots = .certificates(roots)
    tls.certificateVerification = .fullVerification
} else {
    // (b) Self-signed, by pin. The custom callback replaces BoringSSL's chain check; it
    // runs only when verification is not `.none`.
    let want = args[3].lowercased()
    // An empty trust store: the default one reads the system roots, and on a box without
    // ca-certificates (debian:bookworm-slim) NIOSSLContext then fails with unknownError([]).
    tls.trustRoots = .certificates([])
    tls.certificateVerification = .noHostnameVerification
    verifyCallback = { certificates, promise in
        guard let leaf = certificates.first else { return promise.succeed(.failed) }
        do {
            let spki = try leaf.extractPublicKey().toSPKIBytes()
            let got = hex(SHA256.hash(spki))
            fputs("ws-dial: server SPKI sha256 \(got)\n", stderr)
            promise.succeed(got == want ? .certificateVerified : .failed)
        } catch {
            promise.succeed(.failed)
        }
    }
}

let sslContext: NIOSSLContext
do { sslContext = try NIOSSLContext(configuration: tls) } catch { fail("TLS context: \(error)") }

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let reply = group.next().makePromise(of: String.self)

/// Sends the upgrade request once the channel is up. NIOSSLHandler holds it until the
/// handshake is done.
final class UpgradeRequester: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    let failed: EventLoopPromise<String>

    init(failed: EventLoopPromise<String>) { self.failed = failed }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: port == 443 ? host : "\(host):\(port)")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Only reached when the server answered without upgrading.
        if case .head(let head) = unwrapInboundIn(data) {
            failed.fail(DialError("upgrade refused: HTTP \(head.status.code)"))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failed.fail(error)
        context.close(promise: nil)
    }
}

struct DialError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// After the upgrade: send one line, wait for one line, close.
final class LineExchange: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    let reply: EventLoopPromise<String>

    init(reply: EventLoopPromise<String>) { self.reply = reply }

    func handlerAdded(context: ChannelHandlerContext) {
        let line = "{\"h\":\"spike-s3\",\"m\":\"hello from ws-dial\"}"
        var buffer = context.channel.allocator.buffer(capacity: line.utf8.count)
        buffer.writeString(line)
        let frame = WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: buffer)
        fputs("ws-dial: sent \(line)\n", stderr)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var body = frame.unmaskedData
            let text = body.readString(length: body.readableBytes) ?? ""
            reply.succeed(text)
            let close = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(),
                                       data: context.channel.allocator.buffer(capacity: 0))
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in context.close(promise: nil) }
        case .connectionClose:
            reply.fail(DialError("closed before a reply"))
            context.close(promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        reply.fail(error)
        context.close(promise: nil)
    }
}

let bootstrap = ClientBootstrap(group: group)
    .connectTimeout(.seconds(5))
    .channelInitializer { channel in
        do {
            let ssl: NIOSSLClientHandler
            if let verifyCallback {
                ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host,
                                              customVerificationCallback: verifyCallback)
            } else {
                ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
            }
            try channel.pipeline.syncOperations.addHandler(ssl)
            let requester = UpgradeRequester(failed: reply)
            let upgrader = NIOWebSocketClientUpgrader(
                requestKey: NIOWebSocketClientUpgrader.randomRequestKey(),
                upgradePipelineHandler: { channel, _ in
                    channel.pipeline.addHandler(LineExchange(reply: reply))
                })
            let config: NIOHTTPClientUpgradeConfiguration = (
                upgraders: [upgrader],
                completionHandler: { context in
                    context.channel.pipeline.removeHandler(requester, promise: nil)
                })
            try channel.pipeline.syncOperations.addHTTPClientHandlers(withClientUpgrade: config)
            try channel.pipeline.syncOperations.addHandler(requester)
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

fputs("ws-dial: connecting \(host):\(port)\(path) (\(args[2]))\n", stderr)
do {
    let channel = try bootstrap.connect(host: host, port: port).wait()
    channel.closeFuture.whenComplete { _ in reply.fail(DialError("connection closed")) }
    let line = try reply.futureResult.wait()
    print("ws-dial: received \(line)")
    try? channel.closeFuture.wait()
    exit(0)
} catch {
    fail("\(error)")
}

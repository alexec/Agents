import AgentsKitCore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

/// Dials a control plane's `wss://…/v1/connect` (058, research R7, spike S3): the hosts'
/// way in, on a Mac and on Linux alike, and the service's own tests.
///
/// The certificate is checked one of two ways. With a pin, only a certificate whose
/// public key hashes to it is accepted, whatever its name, and no trust store is read: on a
/// box without system roots the default one fails outright (S3). Without a pin, the
/// certificate must be publicly trusted for the host name, or trusted by `roots`.
public enum ControlDial {
    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// One event loop group for every dial in this process.
    public static let group: MultiThreadedEventLoopGroup = .singleton

    /// A WebSocket to `url`, open and upgraded, as lines. The key exchange is the caller's
    /// (`ControlAuth.join`).
    public static func connect(_ url: URL, pin: String? = nil, roots: [NIOSSLCertificate]? = nil,
                               timeout: TimeAmount = .seconds(10)) async throws -> WebSocketLineTransport {
        guard let scheme = url.scheme?.lowercased(), let host = url.host else {
            throw Failure("\(url) is not an address to dial")
        }
        let secure = scheme == "https" || scheme == "wss"
        guard secure || scheme == "http" || scheme == "ws" else { throw Failure("\(url) is not http or https") }
        let port = url.port ?? (secure ? 443 : 80)
        let path = "/v1/connect"
        let context = secure ? try tlsContext(pinned: pin != nil, roots: roots) : nil
        let verify: NIOSSLCustomVerificationCallback? = pin.map { want in
            { certificates, promise in
                guard let leaf = certificates.first,
                      let spki = try? leaf.extractPublicKey().toSPKIBytes() else { return promise.succeed(.failed) }
                let got = ControlCode.base64url(ControlAgreement.sha256(Data(spki)))
                promise.succeed(got == want ? .certificateVerified : .failed)
            }
        }

        let opened = group.next().makePromise(of: WebSocketLineTransport.self)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    if let context {
                        let tls = if let verify {
                            try NIOSSLClientHandler(context: context, serverHostname: host.isIPAddress ? nil : host,
                                                    customVerificationCallback: verify)
                        } else {
                            try NIOSSLClientHandler(context: context, serverHostname: host.isIPAddress ? nil : host)
                        }
                        try channel.pipeline.syncOperations.addHandler(tls)
                    }
                    let requester = UpgradeRequester(host: host, port: port, secure: secure, path: path, failed: opened)
                    let upgrader = NIOWebSocketClientUpgrader(
                        requestKey: NIOWebSocketClientUpgrader.randomRequestKey(),
                        maxFrameSize: maxMessage,
                        upgradePipelineHandler: { channel, _ in
                            channel.pipeline.addHandlers([
                                NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 100_000,
                                                            maxAccumulatedFrameSize: maxMessage),
                                WebSocketLineHandler(isClient: true) { opened.succeed($0) },
                            ])
                        })
                    let config: NIOHTTPClientUpgradeConfiguration = (
                        upgraders: [upgrader],
                        completionHandler: { context in context.channel.pipeline.removeHandler(requester, promise: nil) })
                    // Forwarded, not dropped: behind a proxy (Caddy) the server's hello can
                    // arrive in the same read as the 101, and NIO's default throws it away.
                    try channel.pipeline.syncOperations.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes,
                                                                              withClientUpgrade: config)
                    try channel.pipeline.syncOperations.addHandler(requester)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            // Nothing will complete the promise now, and NIO traps on one left behind.
            opened.fail(error)
            throw error
        }
        channel.closeFuture.whenComplete { _ in opened.fail(Failure("the connection closed before the WebSocket opened")) }
        let deadline = channel.eventLoop.scheduleTask(in: timeout) {
            opened.fail(Failure("no WebSocket from \(url) within the time allowed"))
            channel.close(promise: nil)
        }
        defer { deadline.cancel() }
        return try await opened.futureResult.get()
    }

    static func tlsContext(pinned: Bool, roots: [NIOSSLCertificate]?) throws -> NIOSSLContext {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        if pinned {
            tls.trustRoots = .certificates([])
            tls.certificateVerification = .noHostnameVerification
        } else if let roots {
            tls.trustRoots = .certificates(roots)
            tls.certificateVerification = .fullVerification
        } else if let der = TestTrustRoot.der {
            // A walk's stand-in for a public root (Debug builds only).
            tls.trustRoots = .certificates([try NIOSSLCertificate(bytes: [UInt8](der), format: .der)])
            tls.certificateVerification = .fullVerification
        } else {
            tls.certificateVerification = .fullVerification
        }
        return try NIOSSLContext(configuration: tls)
    }

    /// The pin of a certificate: base64url of the SHA-256 of its public key (R6).
    public static func pin(of certificate: NIOSSLCertificate) throws -> String {
        ControlCode.base64url(ControlAgreement.sha256(Data(try certificate.extractPublicKey().toSPKIBytes())))
    }
}

/// Sends the upgrade request once the channel is up; TLS holds it until its handshake.
private final class UpgradeRequester: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    let host: String
    let port: Int
    let secure: Bool
    let path: String
    let failed: EventLoopPromise<WebSocketLineTransport>

    init(host: String, port: Int, secure: Bool, path: String, failed: EventLoopPromise<WebSocketLineTransport>) {
        self.host = host
        self.port = port
        self.secure = secure
        self.path = path
        self.failed = failed
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        let standard = secure ? 443 : 80
        headers.add(name: "Host", value: port == standard ? host : "\(host):\(port)")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data) {
            failed.fail(ControlDial.Failure("the control plane did not open a WebSocket: HTTP \(head.status.code)"))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failed.fail(error)
        context.close(promise: nil)
    }
}

// MARK: - The server's side

/// An answer to a request that is not a WebSocket: health checks, the install script and
/// the Linux host binaries (058, T070).
public struct PlainReply: Sendable {
    public var status: HTTPResponseStatus
    public var body: Data
    public var contentType: String
    public init(_ status: HTTPResponseStatus, _ body: Data, contentType: String = "application/octet-stream") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }
    public init(_ status: HTTPResponseStatus, text: String) {
        self.init(status, Data(text.utf8), contentType: "text/plain; charset=utf-8")
    }
}

public enum ControlWebSocketServer {
    /// Adds what a server needs to a new connection: TLS if it has a context, HTTP with the
    /// upgrade to a WebSocket at `/v1/connect`, and `plain` for every other request
    /// (`/healthz`, `/readyz`). `opened` is called with each WebSocket as lines.
    public static func configure(_ channel: any Channel, tls: NIOSSLContext?,
                                 plain: @escaping @Sendable (HTTPRequestHead) -> (HTTPResponseStatus, String),
                                 opened: @escaping @Sendable (WebSocketLineTransport) -> Void) -> EventLoopFuture<Void> {
        configure(channel, tls: tls, reply: { head in let (status, text) = plain(head); return PlainReply(status, text: text) },
                  opened: opened)
    }

    public static func configure(_ channel: any Channel, tls: NIOSSLContext?,
                                 reply plain: @escaping @Sendable (HTTPRequestHead) -> PlainReply,
                                 opened: @escaping @Sendable (WebSocketLineTransport) -> Void) -> EventLoopFuture<Void> {
        do {
            if let tls { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
        let http = PlainHTTP(answer: plain)
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: maxMessage,
            shouldUpgrade: { channel, head in
                channel.eventLoop.makeSucceededFuture(head.uri.split(separator: "?").first == "/v1/connect" ? HTTPHeaders() : nil)
            },
            upgradePipelineHandler: { channel, _ in
                channel.pipeline.addHandlers([
                    NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 100_000,
                                                maxAccumulatedFrameSize: maxMessage),
                    WebSocketLineHandler(isClient: false, opened: opened),
                ])
            })
        return channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (upgraders: [upgrader], completionHandler: { context in
                context.channel.pipeline.removeHandler(http, promise: nil)
            })
        ).flatMap { channel.pipeline.addHandler(http) }
    }
}

/// Everything that is not a WebSocket: a reply and a status, then close.
private final class PlainHTTP: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let answer: @Sendable (HTTPRequestHead) -> PlainReply
    private var head: HTTPRequestHead?

    init(answer: @escaping @Sendable (HTTPRequestHead) -> PlainReply) { self.answer = answer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body: break
        case .end:
            guard let head else { return }
            let reply = answer(head)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: reply.contentType)
            headers.add(name: "Content-Length", value: "\(reply.body.count)")
            headers.add(name: "Connection", value: "close")
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: reply.status, headers: headers))),
                          promise: nil)
            var body = context.channel.allocator.buffer(capacity: reply.body.count)
            body.writeBytes(reply.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
        }
    }
}

private extension String {
    /// A literal address needs no SNI, and BoringSSL refuses one as a server name.
    var isIPAddress: Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, self, &v4) == 1 || inet_pton(AF_INET6, self, &v6) == 1
    }
}

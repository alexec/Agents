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

    /// A connect that failed, in words a person can act on (#113): the name that doesn't
    /// resolve, the port nothing listens on, with NIO's own error after it.
    static func words(for error: any Error, host: String, port: Int) -> String {
        guard let failed = error as? NIOConnectionError else { return "\(host):\(port): \(error)" }
        if let dns = failed.dnsAError ?? failed.dnsAAAAError {
            return "\(host) can't be found on this network (\(dns))"
        }
        let refused = failed.connectionErrors.contains { ($0.error as? IOError)?.errnoCode == ECONNREFUSED }
        if refused { return "nothing is listening at \(host):\(port)" }
        if let first = failed.connectionErrors.first { return "\(host):\(port) didn't answer (\(first.error))" }
        return "\(host):\(port) didn't answer"
    }

    /// One event loop group for every dial in this process.
    public static let group: MultiThreadedEventLoopGroup = .singleton

    /// A WebSocket to `url`, open and upgraded, as lines. The key exchange is the caller's
    /// (`ControlAuth.join`). `origin` is sent as a browser sends it: the web remote's
    /// listener refuses an upgrade without its own (071); tests dial it as a page would.
    public static func connect(_ url: URL, pin: String? = nil, roots: [NIOSSLCertificate]? = nil,
                               origin: String? = nil,
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
                    let requester = UpgradeRequester(host: host, port: port, secure: secure, path: path, origin: origin,
                                                     failed: opened)
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
            throw Failure(Self.words(for: error, host: host, port: port))
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
    let origin: String?
    let failed: EventLoopPromise<WebSocketLineTransport>

    init(host: String, port: Int, secure: Bool, path: String, origin: String?,
         failed: EventLoopPromise<WebSocketLineTransport>) {
        self.host = host
        self.port = port
        self.secure = secure
        self.path = path
        self.origin = origin
        self.failed = failed
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        let standard = secure ? 443 : 80
        headers.add(name: "Host", value: port == standard ? host : "\(host):\(port)")
        headers.add(name: "Content-Length", value: "0")
        if let origin { headers.add(name: "Origin", value: origin) }
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
    /// Sent as well as the type, length and `Connection: close` (the web remote's CSP, 071).
    public var headers: [(String, String)] = []
    public init(_ status: HTTPResponseStatus, _ body: Data, contentType: String = "application/octet-stream",
                headers: [(String, String)] = []) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.headers = headers
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
                                 unproven: UnprovenGate? = nil,
                                 opened: @escaping @Sendable (WebSocketLineTransport) -> Void) -> EventLoopFuture<Void> {
        configure(channel, tls: tls, reply: { head in let (status, text) = plain(head); return PlainReply(status, text: text) },
                  unproven: unproven, opened: opened)
    }

    /// `upgrade` may refuse an upgrade at `/v1/connect` after reading its head (the web
    /// remote's `Host` and `Origin`, 071); a refused one is answered by `plain` instead.
    ///
    /// Until the WebSocket's owner calls `proven()` on it, the connection is held to
    /// `UnprovenGuard`'s limits and holds a place in `unproven` (#206).
    public static func configure(_ channel: any Channel, tls: NIOSSLContext?,
                                 reply plain: @escaping @Sendable (HTTPRequestHead) -> PlainReply,
                                 upgrade: (@Sendable (HTTPRequestHead) -> Bool)? = nil,
                                 unproven: UnprovenGate? = nil,
                                 opened: @escaping @Sendable (WebSocketLineTransport) -> Void) -> EventLoopFuture<Void> {
        let guarding = UnprovenGuard(gate: unproven)
        do {
            try channel.pipeline.syncOperations.addHandler(guarding)
            if let tls { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
        let http = PlainHTTP(answer: plain)
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: maxMessage,
            shouldUpgrade: { channel, head in
                let wanted = head.uri.split(separator: "?").first == "/v1/connect" && (upgrade?(head) ?? true)
                return channel.eventLoop.makeSucceededFuture(wanted ? HTTPHeaders() : nil)
            },
            upgradePipelineHandler: { channel, _ in
                guarding.didUpgrade()
                return channel.pipeline.addHandlers([
                    NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 100_000,
                                                maxAccumulatedFrameSize: maxMessage),
                    WebSocketLineHandler(isClient: false) { transport in
                        transport.onProven = { [eventLoop = channel.eventLoop] in eventLoop.execute { guarding.didProve() } }
                        opened(transport)
                    },
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
            for (name, value) in reply.headers { headers.add(name: name, value: value) }
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

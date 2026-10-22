import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import ControlDial

/// The control dial through a corporate network's proxy (#2177): HTTP CONNECT, and the
/// proxy each address takes.
@Suite("The control dial through a proxy")
struct ControlProxyTests {
    @Test func anEnvironmentProxyAndItsExceptions() {
        let environment = ["HTTPS_PROXY": "http://proxy.corp.example:3128", "HTTP_PROXY": "proxy.corp.example:8080",
                           "NO_PROXY": "localhost,.internal.example,intranet.example:443"]
        func proxy(_ address: String) -> ControlProxy? {
            ControlProxy.forURL(URL(string: address)!, environment: environment)
        }
        #expect(proxy("https://control.example.com") == ControlProxy(host: "proxy.corp.example", port: 3128))
        #expect(proxy("wss://control.example.com/v1/connect") == ControlProxy(host: "proxy.corp.example", port: 3128))
        #expect(proxy("http://control.example.com") == ControlProxy(host: "proxy.corp.example", port: 8080))
        #expect(proxy("https://a.internal.example") == nil)
        #expect(proxy("https://intranet.example") == nil)
        #expect(proxy("https://cp.intranet.example") == nil)
        #expect(proxy("https://127.0.0.1:8791") == nil)
        #expect(proxy("https://localhost:8791") == nil)
        #expect(ControlProxy.forURL(URL(string: "https://control.example.com")!, environment: ["NO_PROXY": "*", "HTTPS_PROXY": "p:1"]) == nil)
        // Only NO_PROXY set: the environment decides, and it names no proxy.
        #expect(ControlProxy.forURL(URL(string: "https://control.example.com")!, environment: ["NO_PROXY": "x"]) == nil)
    }

    @Test func aDialGoesThroughTheProxysTunnel() async throws {
        let server = try await HelloServer.start()
        defer { server.stop() }
        let proxy = try await TestConnectProxy.start(refuse: false)
        defer { proxy.stop() }

        let socket = try await ControlDial.connect(URL(string: "http://127.0.0.1:\(server.port)")!,
                                                   proxy: ControlProxy(host: "127.0.0.1", port: proxy.port))
        defer { socket.close() }
        var lines = socket.lines().makeAsyncIterator()
        #expect(try await lines.next() == "hello")
        #expect(proxy.asked == ["127.0.0.1:\(server.port)"])
    }

    @Test func aProxyThatRefusesSaysSo() async throws {
        let server = try await HelloServer.start()
        defer { server.stop() }
        let proxy = try await TestConnectProxy.start(refuse: true)
        defer { proxy.stop() }
        do {
            _ = try await ControlDial.connect(URL(string: "http://127.0.0.1:\(server.port)")!,
                                              proxy: ControlProxy(host: "127.0.0.1", port: proxy.port))
            Issue.record("a refused tunnel opened")
        } catch {
            #expect("\(error)".contains("the proxy refused the tunnel"))
        }
    }
}

/// A control plane's WebSocket, plain, that says "hello" to each socket.
private struct HelloServer {
    let channel: any Channel
    var port: Int { channel.localAddress?.port ?? 0 }

    static func start() async throws -> HelloServer {
        let channel = try await ServerBootstrap(group: ControlDial.group)
            .childChannelInitializer { channel in
                ControlWebSocketServer.configure(channel, tls: nil, plain: { _ in (.notFound, "") }) { socket in
                    try? socket.write(line: "hello")
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return HelloServer(channel: channel)
    }

    func stop() { channel.close(promise: nil) }
}

/// A proxy that only tunnels, as a corporate one does for HTTPS, noting each address asked.
private final class TestConnectProxy: @unchecked Sendable {
    let refuse: Bool
    private let lock = NSLock()
    private var addresses: [String] = []
    private var channel: (any Channel)?

    init(refuse: Bool) { self.refuse = refuse }

    var asked: [String] { lock.withLock { addresses } }
    var port: Int { channel?.localAddress?.port ?? 0 }

    static func start(refuse: Bool) async throws -> TestConnectProxy {
        let proxy = TestConnectProxy(refuse: refuse)
        proxy.channel = try await ServerBootstrap(group: ControlDial.group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Front(proxy: proxy)) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return proxy
    }

    func note(_ address: String) { lock.withLock { addresses.append(address) } }
    func stop() { channel?.close(promise: nil) }

    /// The client's side: the CONNECT, then bytes copied to the control plane.
    final class Front: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let proxy: TestConnectProxy
        var head: ByteBuffer?
        var back: (any Channel)?

        init(proxy: TestConnectProxy) { self.proxy = proxy }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            if let back {
                back.writeAndFlush(bytes, promise: nil)
                return
            }
            if head == nil { head = bytes } else { head!.writeBuffer(&bytes) }
            guard let text = head.flatMap({ $0.getString(at: $0.readerIndex, length: $0.readableBytes) }),
                  text.contains("\r\n\r\n") else { return }
            let target = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            proxy.note(target)
            let front = context.channel
            func answer(_ status: String) {
                var reply = front.allocator.buffer(capacity: 64)
                reply.writeString("HTTP/1.1 \(status)\r\n\r\n")
                front.writeAndFlush(reply, promise: nil)
            }
            guard !proxy.refuse, let colon = target.lastIndex(of: ":"), let port = Int(target[target.index(after: colon)...]) else {
                answer("403 Forbidden")
                front.close(promise: nil)
                return
            }
            ClientBootstrap(group: context.eventLoop)
                .channelInitializer { back in
                    back.eventLoop.makeCompletedFuture { try back.pipeline.syncOperations.addHandler(Back(front: front)) }
                }
                .connect(host: String(target[..<colon]), port: port)
                .whenComplete { result in
                    switch result {
                    case .success(let back):
                        self.back = back
                        answer("200 Connection established")
                    case .failure:
                        answer("502 Bad Gateway")
                        front.close(promise: nil)
                    }
                }
        }

        func channelInactive(context: ChannelHandlerContext) {
            back?.close(promise: nil)
        }
    }

    /// The control plane's side: bytes copied back to the client.
    final class Back: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let front: any Channel
        init(front: any Channel) { self.front = front }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            front.writeAndFlush(unwrapInboundIn(data), promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            front.close(promise: nil)
        }
    }
}

import AgentsKitCore
import Foundation
import NIOCore
import NIOWebSocket

/// A WebSocket carrying the control plane's wire: one text message per line (058,
/// contracts/wire.md). The same handler serves the service's end and a host's end; only a
/// client masks what it sends.
///
/// Keep-alive: a ping every 20 seconds, and the socket is closed after two missed pongs,
/// so a load balancer's idle timeout never cuts a quiet uplink and a dead one is noticed.
public final class WebSocketLineTransport: LineTransport, @unchecked Sendable {
    let channel: any Channel
    private let isClient: Bool
    private let stream: AsyncThrowingStream<String, any Error>
    let continuation: AsyncThrowingStream<String, any Error>.Continuation

    init(channel: any Channel, isClient: Bool) {
        self.channel = channel
        self.isClient = isClient
        var c: AsyncThrowingStream<String, any Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public func write(line: String) throws {
        guard channel.isActive else { throw WebSocketClosed() }
        let masked = isClient
        let channel = self.channel
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: line.utf8.count)
            buffer.writeString(line)
            let frame = WebSocketFrame(fin: true, opcode: .text, maskKey: masked ? .random() : nil, data: buffer)
            channel.writeAndFlush(frame, promise: nil)
        }
    }

    public func lines() -> AsyncThrowingStream<String, any Error> { stream }

    public func close() {
        let masked = isClient
        let channel = self.channel
        channel.eventLoop.execute {
            guard channel.isActive else { return }
            var data = channel.allocator.buffer(capacity: 2)
            data.write(webSocketErrorCode: .normalClosure)
            let frame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: masked ? .random() : nil, data: data)
            channel.writeAndFlush(frame).whenComplete { _ in channel.close(promise: nil) }
        }
    }

    /// Runs `body` once the connection is gone, however it went.
    public func whenClosed(_ body: @escaping @Sendable () -> Void) {
        channel.closeFuture.whenComplete { _ in body() }
    }

    /// The address at the other end, for the log.
    public var remote: String { channel.remoteAddress?.description ?? "?" }
}

public struct WebSocketClosed: Error, Sendable, CustomStringConvertible {
    public var description: String { "the WebSocket has closed" }
}

/// Turns frames into lines and back, answers pings, and sends its own.
final class WebSocketLineHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    static let pingEvery: TimeAmount = .seconds(20)
    static let missedPongsAllowed = 2

    private let isClient: Bool
    private let opened: @Sendable (WebSocketLineTransport) -> Void
    private var transport: WebSocketLineTransport?
    private var missed = 0
    private var pinger: RepeatedTask?

    init(isClient: Bool, opened: @escaping @Sendable (WebSocketLineTransport) -> Void) {
        self.isClient = isClient
        self.opened = opened
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let transport = WebSocketLineTransport(channel: context.channel, isClient: isClient)
        self.transport = transport
        let masked = isClient
        pinger = context.eventLoop.scheduleRepeatedTask(initialDelay: Self.pingEvery, delay: Self.pingEvery) {
            [weak self, channel = context.channel] _ in
            guard let self else { return }
            self.missed += 1
            if self.missed > Self.missedPongsAllowed {
                channel.close(promise: nil)
                return
            }
            let frame = WebSocketFrame(fin: true, opcode: .ping, maskKey: masked ? .random() : nil,
                                       data: channel.allocator.buffer(capacity: 0))
            channel.writeAndFlush(frame, promise: nil)
        }
        opened(transport)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var body = frame.unmaskedData
            if let text = body.readString(length: body.readableBytes) {
                // A peer that sent several lines in one message is still heard line by line.
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    transport?.continuation.yield(String(line))
                }
            }
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: isClient ? .random() : nil,
                                      data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .pong:
            missed = 0
        case .connectionClose:
            let close = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: isClient ? .random() : nil,
                                       data: context.channel.allocator.buffer(capacity: 0))
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in context.close(promise: nil) }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        pinger?.cancel()
        transport?.continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        pinger?.cancel()
        transport?.continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}

/// The most one message may carry (`LineSplitter`'s cap).
let maxMessage = 64 * 1024 * 1024

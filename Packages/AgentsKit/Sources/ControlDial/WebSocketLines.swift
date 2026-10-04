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
    /// What the other end sent and this end's reader hasn't taken yet. Past
    /// `inboundHigh` the socket stops being read, so TCP pushes back on the sender,
    /// until the reader brings it down to `inboundLow` (#167).
    let inbound: BoundedLines

    /// The most this end holds for the other end to read before giving up on it (#167): a
    /// phone on poor cellular or a page that stopped reading costs the control plane at
    /// most this, not everything said until its pings time out. The host's own uplink is
    /// given more (`uplinkOutboundLimit`), since everything its clients hear crosses it.
    public static let outboundLimit = 8 << 20
    public static let uplinkOutboundLimit = 32 << 20
    /// How long queued bytes may wait with none of them sent before the other end is
    /// given up on: the daemon socket's `sendWait`, for the same reason.
    public static let writeDeadline: Duration = .seconds(10)
    static let inboundHigh = 4 << 20
    static let inboundLow = 1 << 20
    /// The close code a reader that fell too far behind is told (4000–4999 are ours).
    public static let tooSlowCode: UInt16 = 4008

    private let lock = NSLock()
    private var limit: Int
    private var pending = 0
    /// When the bytes waiting last made progress; nil while nothing waits.
    private var waitingSince: ContinuousClock.Instant?
    private var gaveUp = false

    init(channel: any Channel, isClient: Bool, outboundLimit: Int = WebSocketLineTransport.outboundLimit) {
        self.channel = channel
        self.isClient = isClient
        self.limit = outboundLimit
        inbound = BoundedLines(high: Self.inboundHigh, low: Self.inboundLow,
                               onHigh: { [channel] in channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in } },
                               onLow: { [channel] in channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in } })
    }

    /// The cap on what may wait to be sent; the uplink raises it.
    public var outboundLimit: Int {
        get { lock.withLock { limit } }
        set { lock.withLock { limit = newValue } }
    }

    /// Bytes written and not yet handed to the kernel: this end's queue for the other.
    public var bytesQueued: Int { lock.withLock { pending } }

    public func write(line: String) throws {
        guard channel.isActive else { throw WebSocketClosed() }
        let size = line.utf8.count
        let now = ContinuousClock.now
        let refused = lock.withLock { () -> String? in
            if gaveUp { return "" }
            if let since = waitingSince, now - since > Self.writeDeadline {
                gaveUp = true
                return "nothing sent for \(Self.writeDeadline)"
            }
            if pending > 0, pending + size > limit {
                gaveUp = true
                return "\(pending + size) bytes waiting, more than \(limit)"
            }
            if pending == 0 { waitingSince = now }
            pending += size
            return nil
        }
        if let refused {
            if !refused.isEmpty { tooSlow(refused) }
            throw WebSocketTooSlow()
        }
        let masked = isClient
        let channel = self.channel
        weak let owner = self
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: size)
            buffer.writeString(line)
            let frame = WebSocketFrame(fin: true, opcode: .text, maskKey: masked ? .random() : nil, data: buffer)
            channel.writeAndFlush(frame).whenComplete { _ in owner?.sent(size) }
        }
    }

    private func sent(_ size: Int) {
        lock.withLock {
            pending -= size
            waitingSince = pending > 0 ? ContinuousClock.now : nil
        }
    }

    /// Bytes have waited past the deadline with none sent: the ping timer's check, for an
    /// end nobody is writing to any more.
    func stalled() -> Bool {
        let gone = lock.withLock { () -> Bool in
            guard !gaveUp, let since = waitingSince, ContinuousClock.now - since > Self.writeDeadline else { return false }
            gaveUp = true
            return true
        }
        if gone { tooSlow("nothing sent for \(Self.writeDeadline)") }
        return gone
    }

    /// Gives up on a reader that fell behind. What is queued is dropped with the socket;
    /// the other end reconnects and reads everything afresh, as it does after any drop.
    private func tooSlow(_ why: String) {
        WireLog.write("control: closing \(remote), too slow: \(why)")
        close(WebSocketErrorCode(codeNumber: Int(Self.tooSlowCode)), reason: "too slow")
        // The close frame waits behind the same queue, so the socket goes now.
        let channel = self.channel
        channel.eventLoop.scheduleTask(in: .seconds(1)) { channel.close(promise: nil) }
    }

    public func lines() -> AsyncThrowingStream<String, any Error> { inbound.lines }

    public func close() {
        close(.normalClosure, reason: "")
    }

    private func close(_ code: WebSocketErrorCode, reason: String) {
        let masked = isClient
        let channel = self.channel
        channel.eventLoop.execute {
            guard channel.isActive else { return }
            var data = channel.allocator.buffer(capacity: 2 + reason.utf8.count)
            data.write(webSocketErrorCode: code)
            data.writeString(reason)
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

extension WebSocketLineTransport: ReasonedClose {
    /// Closes with `code` (4000–4999 are the application's) and a short reason.
    public func close(code: UInt16, reason: String) {
        close(WebSocketErrorCode(codeNumber: Int(code)), reason: reason)
    }
}

public struct WebSocketClosed: Error, Sendable, CustomStringConvertible {
    public var description: String { "the WebSocket has closed" }
}

/// The other end fell too far behind and was given up on (#167).
public struct WebSocketTooSlow: Error, Sendable, CustomStringConvertible {
    public var description: String { "the other end stopped reading" }
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
            if self.transport?.stalled() == true { return }
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
                    transport?.inbound.yield(String(line))
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
        transport?.inbound.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        pinger?.cancel()
        transport?.inbound.finish(throwing: error)
        context.close(promise: nil)
    }
}

/// The most one message may carry (`LineSplitter`'s cap).
let maxMessage = 64 * 1024 * 1024

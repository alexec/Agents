import Foundation
import NIOCore

/// How many connections a listener holds that have not yet proved who they are (#206).
/// Without a cap about 250 connections that never sent a byte took every descriptor a
/// launchd job has, and locked every client and host out for good. Past `most`, the
/// oldest is closed to make room: closing the newcomer instead would let 64 silent
/// connections, opened again as each times out, keep every member out. A member proves
/// itself within milliseconds of arriving, so it is never the oldest for long.
public final class UnprovenGate: @unchecked Sendable {
    /// The most at once, by default: far more than members ever dial at once after a
    /// restart, far fewer than the descriptors the process has.
    public static let defaultMost = 64

    public let most: Int
    private let lock = NSLock()
    /// Each held connection's way to close it, by when it arrived.
    private var held: [UInt64: @Sendable () -> Void] = [:]
    private var next: UInt64 = 0

    public init(most: Int = UnprovenGate.defaultMost) { self.most = most }

    /// Connections held now that have not proved anything: for the tests.
    public var count: Int { lock.withLock { held.count } }

    /// A place for a new connection; the oldest held is closed if there is none free.
    func enter(close: @escaping @Sendable () -> Void) -> UInt64 {
        let (ticket, evicted) = lock.withLock { () -> (UInt64, (@Sendable () -> Void)?) in
            var evicted: (@Sendable () -> Void)?
            if held.count >= most, let oldest = held.keys.min() { evicted = held.removeValue(forKey: oldest) }
            next += 1
            held[next] = close
            return (next, evicted)
        }
        evicted?()
        return ticket
    }

    func leave(_ ticket: UInt64) { _ = lock.withLock { held.removeValue(forKey: ticket) } }
}

/// The first handler on a server's connection, before TLS (#206). Until the upgrade it
/// closes a connection that stays silent for `idle`, or has not upgraded within
/// `deadline` (the TLS handshake and the request's head both count). Until the control
/// plane's `ok` it lets through at most `bytes` after the upgrade, so a frame of up to
/// 64 MB is never gathered for a peer that has proved nothing; and it holds a place in
/// its listener's gate, which may close it to make room. Once proved, it passes
/// everything and costs nothing.
final class UnprovenGuard: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    static let idle: TimeAmount = .seconds(10)
    static let deadline: TimeAmount = .seconds(20)
    /// What a peer may send between the upgrade and `ok`: its auth line is under a kilobyte.
    static let bytes = 64 * 1024

    private let gate: UnprovenGate?
    private let idle: TimeAmount
    private let deadline: TimeAmount
    private var ticket: UInt64?
    private var upgraded = false
    private var proven = false
    private var received = 0
    private var idleTimer: Scheduled<Void>?
    private var deadlineTimer: Scheduled<Void>?

    init(gate: UnprovenGate?, idle: TimeAmount = UnprovenGuard.idle, deadline: TimeAmount = UnprovenGuard.deadline) {
        self.gate = gate
        self.idle = idle
        self.deadline = deadline
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        ticket = gate?.enter { channel.close(promise: nil) }
        deadlineTimer = context.eventLoop.scheduleTask(in: deadline) { channel.close(promise: nil) }
        armIdle(context)
    }

    func handlerRemoved(context: ChannelHandlerContext) { settle() }

    func channelInactive(context: ChannelHandlerContext) {
        settle()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !proven {
            if upgraded {
                received += unwrapInboundIn(data).readableBytes
                if received > Self.bytes {
                    context.close(promise: nil)
                    return
                }
            } else {
                armIdle(context)
            }
        }
        context.fireChannelRead(data)
    }

    /// The WebSocket is open: the service's own 15 s wait for `auth` bounds it from here.
    func didUpgrade() {
        upgraded = true
        idleTimer?.cancel()
        deadlineTimer?.cancel()
    }

    /// The control plane said `ok`. On the channel's event loop.
    func didProve() {
        proven = true
        settle()
    }

    private func armIdle(_ context: ChannelHandlerContext) {
        idleTimer?.cancel()
        let channel = context.channel
        idleTimer = context.eventLoop.scheduleTask(in: idle) { channel.close(promise: nil) }
    }

    private func settle() {
        idleTimer?.cancel()
        deadlineTimer?.cancel()
        if let ticket {
            self.ticket = nil
            gate?.leave(ticket)
        }
    }
}

import AgentsKitCore
@testable import ControlDial
import Foundation
import NIOCore
import NIOPosix
import Testing

/// A reader that stops costs the end writing to it a bounded queue, then its socket (#167).
/// At the WebSocket itself, with a small limit, so the test pushes megabytes rather than the
/// tens a whole control plane would need (`BackpressureMeasure` does that, on request).
@Suite("A WebSocket whose reader stops", .timeLimit(.minutes(1)))
struct SlowClientTests {
    final class Opened: @unchecked Sendable {
        private let lock = NSLock()
        private var socket: WebSocketLineTransport?
        func set(_ value: WebSocketLineTransport) { lock.withLock { socket = value } }
        var now: WebSocketLineTransport? { lock.withLock { socket } }
    }

    @Test func isGivenUpOnOnceItsQueueIsFull() async throws {
        let opened = Opened()
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                ControlWebSocketServer.configure(channel, tls: nil, plain: { _ in (.notFound, "") }) { opened.set($0) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { listener.close(promise: nil) }
        let port = try #require(listener.localAddress?.port)
        let reader = try await ControlDial.connect(URL(string: "http://127.0.0.1:\(port)")!)
        try await reader.channel.setOption(ChannelOptions.autoRead, value: false).get()
        await eventually { opened.now != nil }
        let writer = try #require(opened.now)
        let limit = 256 << 10
        writer.outboundLimit = limit

        // Written until refused: the kernel's buffers on both ends fill first, then the queue.
        let line = String(repeating: "x", count: 4_096)
        var peak = 0
        var refused: (any Error)?
        for _ in 0..<20_000 {
            do {
                try writer.write(line: line)
                peak = max(peak, writer.bytesQueued)
            } catch {
                refused = error
                break
            }
            if writer.bytesQueued > limit / 2 { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(refused is WebSocketTooSlow)
        #expect(peak <= limit)
        // Its socket goes, and nothing more is taken for it.
        await eventually { !writer.channel.isActive }
        #expect(throws: (any Error).self) { try writer.write(line: "more") }
        // Its reader never noticed: it reads nothing.
        #expect(reader.channel.isActive)
        reader.close()
    }

    @Test func aReaderThatKeepsUpIsNeverGivenUpOn() async throws {
        let opened = Opened()
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                ControlWebSocketServer.configure(channel, tls: nil, plain: { _ in (.notFound, "") }) { opened.set($0) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { listener.close(promise: nil) }
        let port = try #require(listener.localAddress?.port)
        let reader = try await ControlDial.connect(URL(string: "http://127.0.0.1:\(port)")!)
        await eventually { opened.now != nil }
        let writer = try #require(opened.now)
        writer.outboundLimit = 256 << 10
        let count = 2_000
        let heard = Task { () -> Int in
            var n = 0
            for try await _ in reader.lines() {
                n += 1
                if n == count { break }
            }
            return n
        }
        let line = String(repeating: "y", count: 1_024)
        for _ in 0..<count {
            try writer.write(line: line)
            while writer.bytesQueued > 128 << 10 { try await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(try await heard.value == count)
        #expect(writer.channel.isActive)
        reader.close()
    }
}

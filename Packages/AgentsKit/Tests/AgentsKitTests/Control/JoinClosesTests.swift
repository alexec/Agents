import Foundation
import Testing
@testable import AgentsKitCore

/// A join that fails closes its socket, however it fails (#445): one left open is one
/// more connection the control plane keeps for a window that has moved on.
@Suite("A failed join closes its socket")
struct JoinClosesTests {
    /// Says `lines`, then ends with `ending`, and counts its closes.
    final class Scripted: LineTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var closes = 0
        let script: [String]
        let ending: (any Error)?
        init(_ script: [String], ending: (any Error)? = nil) {
            self.script = script
            self.ending = ending
        }
        var closed: Bool { lock.withLock { closes > 0 } }
        func write(line: String) throws {}
        func lines() -> AsyncThrowingStream<String, any Error> {
            AsyncThrowingStream { continuation in
                for line in script { continuation.yield(line) }
                continuation.finish(throwing: ending)
            }
        }
        func close() { lock.withLock { closes += 1 } }
    }

    struct Dropped: Error {}

    let credentials = ControlAuth.Credentials(identity: .client(UUID()), key: Data(repeating: 1, count: 32),
                                              kind: "mac", controlKey: nil)

    @Test func aSocketThatFailsBeforeHelloIsClosed() async {
        let socket = Scripted([], ending: Dropped())
        await #expect(throws: (any Error).self) {
            _ = try await ControlAuth.join(socket, origin: "https://example.test", as: credentials, within: 2)
        }
        #expect(socket.closed)
    }

    @Test func aSocketWhoseHelloCannotBeAnsweredIsClosed() async {
        // A hello of a version this build does not speak: answering it throws.
        let socket = Scripted([#"{"type":"hello","v":999,"nonce":"x"}"#])
        await #expect(throws: (any Error).self) {
            _ = try await ControlAuth.join(socket, origin: "https://example.test", as: credentials, within: 2)
        }
        #expect(socket.closed)
    }
}

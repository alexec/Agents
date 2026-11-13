import AgentsKitCore
import Foundation

/// A link that answers once and then goes quiet (#5147): with `-fake-drop`, the canned
/// daemon's first link ends after 45 s, once the slow fake has given its lists, and every
/// try after it fails, so a walk sees the pages as they are when the Mac stops answering,
/// with the stale banner on them.
final class DroppingLink: DaemonLink, @unchecked Sendable {
    private let inner: any DaemonLink
    private let after: Duration
    private let lock = NSLock()
    private var used = false

    init(_ inner: any DaemonLink, after: Duration = .seconds(45)) {
        self.inner = inner
        self.after = after
    }

    func transport() async throws -> any LineTransport {
        let first = lock.withLock {
            defer { used = true }
            return !used
        }
        guard first else { throw URLError(.cannotConnectToHost) }
        let transport = DroppingTransport(try await inner.transport())
        let after = after
        Task.detached {
            try? await Task.sleep(for: after)
            transport.close()
        }
        return transport
    }
}

/// The fake's transport, whose lines end when it is closed, as a socket's do.
private final class DroppingTransport: LineTransport, @unchecked Sendable {
    private let inner: any LineTransport
    private let lock = NSLock()
    private var closed = false
    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?

    init(_ inner: any LineTransport) { self.inner = inner }

    func write(line: String) throws {
        if lock.withLock({ closed }) { throw URLError(.networkConnectionLost) }
        try inner.write(line: line)
    }

    func lines() -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            let pump = Task {
                do {
                    for try await line in inner.lines() { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func close() {
        let continuation = lock.withLock {
            closed = true
            return self.continuation
        }
        continuation?.finish(throwing: URLError(.networkConnectionLost))
        inner.close()
    }
}

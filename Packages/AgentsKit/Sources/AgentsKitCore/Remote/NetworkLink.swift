// Not on Linux: the server build of agentsd has no Network and no use for this (037).
#if canImport(Network)
import Foundation
import Network

/// A way to reach the daemon over the local network.
///
/// This is FR-004 — the direct connection, which the plan scheduled last and which is
/// the only channel that can exist before the mailbox does. It is the short way to see
/// the Mac's real agents on a real iPad: both are on the same WiFi, Bonjour finds the
/// Mac without an address being typed, and `JSONRPCConnection` does not know or care
/// that the bytes crossed a network rather than a pipe.
///
/// **It is not the channel this feature ships.** There is no pairing and no
/// encryption: anything on the same network that can find the service can drive the
/// daemon. That is why the Mac side is a process the user starts by hand rather than
/// anything that runs on its own, and why `Envelope` and `Mailbox` still have to be
/// built. Read this as scaffolding that happens to be the right shape.
public final class NetworkLink: DaemonLink {
    /// The Bonjour service the Mac advertises.
    public static let serviceType = "_agents._tcp"

    private let howLongToLook: Duration

    public init(howLongToLook: Duration = .seconds(10)) {
        self.howLongToLook = howLongToLook
    }

    public func transport() async throws -> any LineTransport {
        let endpoint = try await findTheMac()
        let connection = NWConnection(to: endpoint, using: .tcp)
        let transport = NWTransport(connection: connection)
        try await transport.waitUntilReady()
        return transport
    }

    /// The first Mac that answers. One person's own network, so the first is the one.
    private func findTheMac() async throws -> NWEndpoint {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil),
                                using: .tcp)
        defer { browser.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let answered = ManagedAtomicFlag()
            browser.browseResultsChangedHandler = { results, _ in
                guard let first = results.first, answered.set() else { return }
                continuation.resume(returning: first.endpoint)
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state, answered.set() {
                    continuation.resume(throwing: error)
                }
            }
            browser.start(queue: .global())

            Task {
                try? await Task.sleep(for: howLongToLook)
                guard answered.set() else { return }
                continuation.resume(throwing: Failure.noMacOnThisNetwork)
            }
        }
    }

    public enum Failure: Error, Sendable {
        case noMacOnThisNetwork
    }
}

/// One JSON object per line, over a TCP connection.
///
/// The third `LineTransport`, beside `FDTransport` and `PairedTransport`. Network
/// framework hands back whatever arrived rather than whole lines, so the splitting is
/// here — a line can arrive in three pieces, and two lines can arrive as one read.
public final class NWTransport: LineTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let stream: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let closed = ManagedAtomicFlag()
    private let lock = NSLock()
    private var pending = Data()

    public init(connection: NWConnection) {
        self.connection = connection
        var c: AsyncThrowingStream<String, any Error>.Continuation!
        self.stream = AsyncThrowingStream { c = $0 }
        self.continuation = c
        connection.start(queue: .global())
        read()
    }

    /// Wait for the handshake, so a connection that will never come up fails here
    /// rather than swallowing the first call sent over it.
    public func waitUntilReady(timeout: Duration = .seconds(8)) async throws {
        let ready = ManagedAtomicFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if ready.set() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if ready.set() { continuation.resume(throwing: error) }
                case .cancelled:
                    if ready.set() { continuation.resume(throwing: JSONRPCTransportError.closed) }
                default:
                    break
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if ready.set() { continuation.resume(throwing: JSONRPCTransportError.closed) }
            }
        }
        // Handed back, so state changes after this go nowhere rather than to a
        // continuation that has already been resumed.
        connection.stateUpdateHandler = nil
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.take(data) }
            if isComplete || error != nil {
                self.continuation.finish(throwing: error)
                return
            }
            self.read()
        }
    }

    private func take(_ data: Data) {
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let i = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pending = pending[pending.index(after: i)...]
            if !line.isEmpty { lines.append(line) }
        }
        lock.unlock()
        for line in lines { continuation.yield(line) }
    }

    public func write(line: String) throws {
        guard !closed.isSet else { throw JSONRPCTransportError.closed }
        connection.send(content: Data((line + "\n").utf8),
                        completion: .contentProcessed { _ in })
    }

    public func lines() -> AsyncThrowingStream<String, any Error> { stream }

    public func close() {
        guard closed.set() else { return }
        continuation.finish()
        connection.cancel()
    }
}
#endif

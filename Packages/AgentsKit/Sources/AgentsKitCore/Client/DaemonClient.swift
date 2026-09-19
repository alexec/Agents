import Foundation

/// How a client talks to the daemon, whatever is carrying the bytes.
///
/// The client holds no agent state: it connects, asks, subscribes, and renders what
/// arrives. Reconnecting after the window died is the same three steps, which is why
/// there is no special case for it.
///
/// It does not know what it is connected over. The Mac hands it a Unix socket and the
/// means to start the helper; a phone hands it a mailbox. Everything below this line
/// is the same either way, which is the whole reason a remote is not a protocol
/// change.
public actor DaemonClient {
    public enum ConnectError: Error, Sendable {
        case noHelper(lookedIn: [String])
        case couldNotStartHelper(String)
        case couldNotConnect
    }

    private let link: any DaemonLink
    private var connection: JSONRPCConnection?

    public init(link: any DaemonLink) {
        self.link = link
    }

    public var isConnected: Bool { connection != nil }

    /// Connect, starting the far end if nothing answers and there is anything to start.
    public func connect(startIfNeeded: Bool = true, timeout: Duration = .seconds(8)) async throws {
        if let connection {
            // A connection that has quietly died still looks like one, so it is asked
            // before it is trusted.
            if (try? await connection.call(DaemonAPI.Method.ping)) != nil { return }
            await connection.close()
            self.connection = nil
        }
        if let connection = try? await open() {
            self.connection = connection
            return
        }
        guard startIfNeeded else { throw ConnectError.couldNotConnect }
        try await link.start()

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let connection = try? await open() {
                self.connection = connection
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw ConnectError.couldNotConnect
    }

    private func open() async throws -> JSONRPCConnection {
        let connection = JSONRPCConnection(transport: try await link.transport())
        await connection.start()
        _ = try await connection.call(DaemonAPI.Method.ping)
        return connection
    }

    // MARK: Asking

    private func connected() throws -> JSONRPCConnection {
        guard let connection else { throw ConnectError.couldNotConnect }
        return connection
    }

    @discardableResult
    public func call(_ method: String, _ params: (some Encodable)? = Optional<String>.none) async throws -> JSONValue {
        let value = try params.map { try JSONValue.encoding($0) }
        return try await connected().call(method, value)
    }

    public func call<T: Decodable>(_ method: String, _ params: (some Encodable)? = Optional<String>.none,
                                   returning: T.Type) async throws -> T {
        try await call(method, params).decode(T.self)
    }

    public nonisolated func notifications() -> AsyncStream<(method: String, params: JSONValue?)> {
        AsyncStream { continuation in
            Task {
                guard let connection = await self.connection else { continuation.finish(); return }
                for await notification in connection.incomingNotifications() {
                    continuation.yield(notification)
                }
                continuation.finish()
            }
        }
    }

    public func disconnect() async {
        await connection?.close()
        connection = nil
    }
}

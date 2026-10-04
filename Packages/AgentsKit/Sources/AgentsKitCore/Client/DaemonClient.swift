import Foundation

/// How a client talks to the daemon, whatever is carrying the bytes.
///
/// The client holds no agent state: it connects, asks, subscribes, and renders what
/// arrives. Reconnecting after the window died is the same three steps, which is why
/// there is no special case for it.
///
/// It does not know what it is connected over. A helper on the Mac hands it a Unix
/// socket; the apps hand it a control plane's WebSocket. Everything below this line
/// is the same either way, which is the whole reason a remote is not a protocol
/// change.
public actor DaemonClient {
    public enum ConnectError: Error, Sendable {
        case couldNotConnect
        /// A root so deep that the socket inside it cannot be addressed. Only ever
        /// seen by somebody who named the root themselves.
        case socketPathTooLong(String)
    }

    private let link: any DaemonLink
    private var connection: JSONRPCConnection?

    /// What answers a server's `credentialWanted` (043): lends a credential on this
    /// connection, asking the person first if there is none, and says whether it did.
    /// When it did, the call that was refused is sent once more, as it was — a send's
    /// `sendID` or a start's `requestID` makes that the same send, not a second one.
    public typealias CredentialLender = @Sendable (DaemonAPI.CredentialWanted) async -> Bool
    private var lender: CredentialLender?

    public func setCredentialLender(_ lender: CredentialLender?) {
        self.lender = lender
    }

    public init(link: any DaemonLink) {
        self.link = link
    }

    /// A connection that ended is not one: a host client the control plane dropped would
    /// otherwise look connected, never be dialled again, and fail every call (#62).
    public var isConnected: Bool { connection.map { !$0.isClosed } ?? false }

    /// Connect, starting the far end if nothing answers and there is anything to start.
    public func connect(startIfNeeded: Bool = true, timeout: Duration = .seconds(8)) async throws {
        if let connection {
            // A connection that has quietly died still looks like one, so it is asked
            // before it is trusted — and a quiet one is not waited on for ever.
            if await Self.answers(connection, within: pingPatience) { return }
            await connection.close()
            self.connection = nil
        }
        if let connection = try? await open() {
            self.connection = connection
            return
        }
        guard startIfNeeded, link.startsSomething else { throw ConnectError.couldNotConnect }
        try await link.start()

        // Waiting for what was started to answer: from a tenth of a second, doubling to
        // two, each spread by jitter, rather than every 100 ms for the whole timeout (#172).
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var wait = Self.startWait.first
        while ContinuousClock.now < deadline {
            if let connection = try? await open() {
                self.connection = connection
                return
            }
            let left = deadline - ContinuousClock.now
            try? await Task.sleep(for: min(ReconnectSchedule.jittered(wait, ReconnectSchedule.randomJitter()), left))
            wait = Self.startWait.doubled(wait)
        }
        throw ConnectError.couldNotConnect
    }

    /// The waits while something just started comes up.
    static let startWait = ReconnectSchedule(first: .milliseconds(100), longest: .seconds(2))

    private func open() async throws -> JSONRPCConnection {
        let connection = JSONRPCConnection(transport: try await link.transport())
        await connection.start()
        // Up is not answering: the bridge finishes the handshake before it has reached
        // the daemon, and a daemon that never answers would hold this here for ever.
        guard await Self.answers(connection, within: pingPatience) else {
            await connection.close()
            throw ConnectError.couldNotConnect
        }
        return connection
    }

    /// How long a ping is given before the connection it went over is let go.
    public var pingPatience: Duration = .seconds(15)

    public func setPingPatience(_ patience: Duration) {
        pingPatience = patience
    }

    /// Whether the far end answers a ping within `patience`. One that does not is
    /// closed, which fails whatever else was waiting on it.
    public func answers(within patience: Duration) async -> Bool {
        guard let connection else { return false }
        return await Self.answers(connection, within: patience)
    }

    ///
    /// Out of patience it closes the connection rather than cancelling the ping: a call
    /// waiting on an answer does not hear cancellation, and a task group waits for every
    /// child before it returns, so a race that only cancelled waited for the ping anyway.
    private static func answers(_ connection: JSONRPCConnection, within patience: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await connection.call(DaemonAPI.Method.ping)) != nil }
            group.addTask {
                try? await Task.sleep(for: patience)
                if !Task.isCancelled { await connection.close() }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: Asking

    private func connected() throws -> JSONRPCConnection {
        guard let connection else { throw ConnectError.couldNotConnect }
        return connection
    }

    /// How long a call made inside `DaemonClient.$patience.withValue(…)` waits for its
    /// answer, for work that must not wait for ever: a reconnect's catching up, which
    /// holds the reconnect loop while it runs, so one lost reply used to leave an app
    /// that looked connected and never was again (073). Nil, the default, waits for the
    /// answer however long it takes, as a clone or an install must.
    @TaskLocal public static var patience: Duration?

    /// A call that had no answer within `patience`.
    public struct NoAnswer: Error, Sendable, CustomStringConvertible {
        public let method: String
        public var description: String { "No answer to \(method) in time." }
    }

    @discardableResult
    public func call(_ method: String, _ params: (some Encodable)? = Optional<String>.none) async throws -> JSONValue {
        let value = try params.map { try JSONValue.encoding($0) }
        guard let patience = Self.patience else { return try await unbounded(method, value) }
        return try await answered(method, within: patience) { try await self.unbounded(method, value) }
    }

    /// `work`'s answer, or `NoAnswer` once `patience` is up. A connection that then does
    /// not answer a ping either is closed, so whatever else waits on it fails too and the
    /// listener reconnects; one that does is only slow with this call.
    ///
    /// Not a task group: a call waiting on a reply does not hear cancellation, and a group
    /// waits for every child, so it would wait for the lost reply too (as `RemoteFiles`).
    private func answered(_ method: String, within patience: Duration,
                          _ work: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        let settled = ManagedAtomicFlag()
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task {
                try? await Task.sleep(for: patience)
                guard !Task.isCancelled, !settled.isSet else { return }
                _ = await self.answers(within: .seconds(4))
                if settled.set() { continuation.resume(throwing: NoAnswer(method: method)) }
            }
            Task {
                let result: Result<JSONValue, any Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                if settled.set() {
                    timer.cancel()
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func unbounded(_ method: String, _ value: JSONValue?) async throws -> JSONValue {
        do {
            return try await connected().call(method, value)
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.credentialWanted {
            guard let lender, let data = error.data,
                  let wanted = try? data.decode(DaemonAPI.CredentialWanted.self),
                  await lender(wanted) else { throw error }
            return try await connected().call(method, value)
        }
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

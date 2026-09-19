import Foundation

/// A JSON-RPC 2.0 connection over a line transport.
///
/// Serves both directions: calls out and awaits replies, and answers calls that come
/// in. Incoming requests are handled on their own task, because the one that matters
/// most — a permission question — is answered by a person and can take hours, and
/// nothing else on the connection may wait for it.
public actor JSONRPCConnection {
    public typealias RequestHandler = @Sendable (String, JSONValue?) async -> Result<JSONValue, JSONRPCError>

    private nonisolated let transport: any LineTransport
    private let handler: RequestHandler
    private var nextID = 0
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, any Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var isClosed = false

    private let notifications: AsyncStream<(method: String, params: JSONValue?)>
    private let notificationsContinuation: AsyncStream<(method: String, params: JSONValue?)>.Continuation

    /// Lines that could not be decoded. Kept rather than dropped so a runtime sending
    /// us something unexpected is a thing we can see rather than a silence.
    public private(set) var malformedLines: [String] = []

    public init(transport: any LineTransport, handler: @escaping RequestHandler = { method, _ in
        .failure(.methodNotFound(method))
    }) {
        self.transport = transport
        self.handler = handler
        var c: AsyncStream<(method: String, params: JSONValue?)>.Continuation!
        self.notifications = AsyncStream { c = $0 }
        self.notificationsContinuation = c
    }

    /// Everything the other side sent that was not a reply to us.
    public nonisolated func incomingNotifications() -> AsyncStream<(method: String, params: JSONValue?)> {
        notifications
    }

    public func start() {
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in self.transport.lines() {
                    await self.receive(line: line)
                }
                await self.finish(with: JSONRPCTransportError.closed)
            } catch {
                await self.finish(with: error)
            }
        }
    }

    private func receive(line: String) {
        let message: JSONRPCMessage
        do {
            message = try JSONRPCCodec.decode(line: line)
        } catch {
            malformedLines.append(line)
            return
        }
        switch message {
        case .success(let id, let result):
            pending.removeValue(forKey: id)?.resume(returning: result)
        case .failure(let id, let error):
            if let id { pending.removeValue(forKey: id)?.resume(throwing: error) }
        case .notification(let method, let params):
            notificationsContinuation.yield((method, params))
        case .request(let id, let method, let params):
            // Detached on purpose. An unstructured `Task` started here would inherit
            // this actor's isolation, so a handler that sends anything back down the
            // same connection while it works would be queued behind itself and the
            // whole connection would stop. That is not hypothetical: it is what a
            // runtime does when it replays a conversation while answering
            // `session/load`.
            Task.detached { [handler] in
                let outcome = await handler(method, params)
                switch outcome {
                case .success(let result): try? await self.send(.success(id: id, result: result))
                case .failure(let error): try? await self.send(.failure(id: id, error: error))
                }
            }
        }
    }

    private func finish(with error: any Error) {
        guard !isClosed else { return }
        isClosed = true
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
        notificationsContinuation.finish()
    }

    private func send(_ message: JSONRPCMessage) throws {
        guard !isClosed else { throw JSONRPCTransportError.closed }
        try transport.write(line: try JSONRPCCodec.encode(message))
    }

    /// Call the other side and wait for its answer.
    @discardableResult
    public func call(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        guard !isClosed else { throw JSONRPCTransportError.closed }
        guard readTask != nil else { throw JSONRPCTransportError.notStarted }
        nextID += 1
        let id = JSONRPCID.number(nextID)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(.request(id: id, method: method, params: params))
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    public func notify(_ method: String, _ params: JSONValue? = nil) throws {
        try send(.notification(method: method, params: params))
    }

    public func close() {
        readTask?.cancel()
        readTask = nil
        transport.close()
        finish(with: JSONRPCTransportError.closed)
    }
}

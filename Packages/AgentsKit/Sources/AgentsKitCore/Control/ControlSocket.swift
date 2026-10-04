import Foundation

/// A line transport whose first few lines are read one at a time, and whose rest goes to
/// whoever reads it next (058). The key exchange reads its lines this way, and the router
/// reads everything after. A stream has one reader, so this is that reader for both.
public final class PrefixReader: LineTransport, @unchecked Sendable {
    private let base: any LineTransport
    private let iterator: Iterator

    private final class Iterator: @unchecked Sendable {
        var inner: AsyncThrowingStream<String, any Error>.AsyncIterator
        init(_ stream: AsyncThrowingStream<String, any Error>) { inner = stream.makeAsyncIterator() }
    }

    public init(_ base: any LineTransport) {
        self.base = base
        iterator = Iterator(base.lines())
    }

    /// The next line, or nil when the other end has gone. Only before `lines()`.
    public func next() async throws -> String? {
        try await iterator.inner.next()
    }

    /// The next line within `seconds`, or nil if it did not come.
    public func next(within seconds: Double) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await self.next() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    public func write(line: String) throws { try base.write(line: line) }

    /// Pulled a line at a time as the reader asks, not drained into a buffer of its own: a
    /// reader that falls behind leaves the lines in the transport, which can then push back
    /// on the sender (#167).
    public func lines() -> AsyncThrowingStream<String, any Error> {
        let iterator = self.iterator
        return AsyncThrowingStream(unfolding: { try await iterator.inner.next() })
    }

    public func close() { base.close() }
}

extension PrefixReader: ReasonedClose {
    public func close(code: UInt16, reason: String) { base.close(code: code, reason: reason) }
}

public extension ControlAuth {
    /// Who a peer is, what it is called when the socket opens, and the key it proves.
    struct Credentials: Sendable {
        public var identity: Identity
        public var key: Data
        public var kind: String
        /// The control plane's key this peer trusts, when it already knows it.
        public var controlKey: Data?
        public var relayingFor: UUID?
        /// The epoch of the endpoints this peer holds (R16), told to the control plane.
        public var epoch: Int?
        public init(identity: Identity, key: Data, kind: String, controlKey: Data?, relayingFor: UUID? = nil,
                    epoch: Int? = nil) {
            self.identity = identity
            self.key = key
            self.kind = kind
            self.controlKey = controlKey
            self.relayingFor = relayingFor
            self.epoch = epoch
        }
    }

    /// The peer's side of the exchange over a socket that has just opened: read `hello`,
    /// answer, read `ok`. Returns the rest of the socket, for the wire, and the `ok`.
    /// Any transport will do: the apps' `URLSession` WebSocket and the hosts' NIO one.
    static func join(_ transport: any LineTransport, origin: String, as credentials: Credentials,
                     within seconds: Double = 15) async throws -> (transport: PrefixReader, hello: Hello, ok: OK) {
        let reader = PrefixReader(transport)
        guard let line = try await reader.next(within: seconds), case .hello(let hello)? = Message(line: line) else {
            reader.close()
            throw Refusal(.badMessage)
        }
        let (auth, expect) = try answer(hello, identity: credentials.identity, key: credentials.key, origin: origin,
                                        kind: credentials.kind, expecting: credentials.controlKey,
                                        for: credentials.relayingFor, epoch: credentials.epoch)
        try reader.write(line: Message.auth(auth).line)
        guard let reply = try await reader.next(within: seconds), let message = Message(line: reply) else {
            reader.close()
            throw Refusal(.badMessage)
        }
        switch message {
        case .ok(let ok):
            try check(ok, expect: expect)
            return (reader, hello, ok)
        case .refused(let reason):
            reader.close()
            throw Refusal(reason)
        default:
            reader.close()
            throw Refusal(.badMessage)
        }
    }
}

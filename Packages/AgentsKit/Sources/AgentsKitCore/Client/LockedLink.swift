#if canImport(CryptoKit)
import Foundation

/// A host's link with each request checked end to end (#3492, `specs/3399-machine-lock` D6).
/// At each new transport it opens a channel with `lock/hello`, signed with this device's lock
/// key, and takes it only when the machine's answer is signed by a key its lock names. Then
/// every request carries the channel's MAC, and an answer is taken only with the machine's.
///
/// With no lock key, or a device not in its lock yet, it is the link as before. With no
/// channel (a machine with no lock, or one away), a prompt or a start goes signed, so the
/// control plane can keep it; and a machine the lock names gives no answer that is not MAC'd.
/// The web page's is `Web/src/wire/link.ts`.
public struct LockedLink: DaemonLink {
    public typealias Source = @Sendable () async -> LockChannel.Signer?

    let inner: any DaemonLink
    /// The machine's id; "" for any machine of the lock (the window's `.mac`).
    let host: String
    let source: Source

    public init(_ inner: any DaemonLink, host: MachineRef, source: @escaping Source) {
        self.inner = inner
        self.host = host == .mac ? "" : host.rawValue
        self.source = source
    }

    public func start() async throws { try await inner.start() }
    public var startsSomething: Bool { inner.startsSomething }

    public func transport() async throws -> any LineTransport {
        let transport = try await inner.transport()
        guard let signer = await source() else { return transport }
        let required = LockChannel.names(signer.state, host: host)
        let locked = LockedTransport(inner: transport, signer: signer, host: host, required: required)
        await locked.open(within: 15)
        return locked
    }
}

/// What may be kept for a machine that is not there, and so goes signed with no channel.
let keptMethods: Set<String> = ["agents/start", "agents/prompt"]

final class LockedTransport: LineTransport, @unchecked Sendable {
    private let inner: any LineTransport
    private let signer: LockChannel.Signer
    private let host: String
    private let required: Bool
    private let lock = NSLock()
    private var channel: LockChannel.Channel?
    /// The ids of requests that went to the machine, until they are answered.
    private var asked: Set<JSONRPCID> = []
    private let helloID = JSONRPCID.string("lock-hello-" + UUID().uuidString)
    private var helloWait: CheckedContinuation<JSONRPCMessage?, Never>?
    private let stream: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private var pump: Task<Void, Never>?

    init(inner: any LineTransport, signer: LockChannel.Signer, host: String, required: Bool) {
        self.inner = inner
        self.signer = signer
        self.host = host
        self.required = required
        var c: AsyncThrowingStream<String, any Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        pump = Task.detached { [weak self, inner] in
            do {
                for try await line in inner.lines() { self?.heard(line) }
                self?.ended(nil)
            } catch {
                self?.ended(error)
            }
        }
    }

    /// `lock/hello`: the channel, when the machine answers as one its lock names in time.
    func open(within seconds: Double) async {
        guard let hello = try? LockChannel.hello(signer.key), let params = try? JSONValue.encoding(hello.params),
              let line = try? JSONRPCCodec.encode(.request(id: helloID, method: DaemonAPI.Method.lockHello, params: params)) else { return }
        let reply: JSONRPCMessage? = await withCheckedContinuation { wait in
            lock.withLock { helloWait = wait }
            do {
                try inner.write(line: line)
            } catch {
                resumeHello(nil)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.resumeHello(nil)
            }
        }
        guard case .success(_, let result)? = reply, let answer = try? result.decode(DaemonAPI.LockHelloReply.self),
              let channel = try? LockChannel.finish(hello, state: signer.state, host: host, reply: answer) else {
            WireLog.write("lock: no checked channel to \(host.isEmpty ? "this Mac" : host)")
            return
        }
        lock.withLock { self.channel = channel }
    }

    private func resumeHello(_ message: JSONRPCMessage?) {
        let wait = lock.withLock { () -> CheckedContinuation<JSONRPCMessage?, Never>? in
            defer { helloWait = nil }
            return helloWait
        }
        wait?.resume(returning: message)
    }

    func write(line: String) throws {
        guard case .request(let id, let method, let params)? = try? JSONRPCCodec.decode(line: line),
              Capability.control[method] == nil else {
            // The control plane's own methods, on the Remote's one connection, and notifications.
            try inner.write(line: line)
            return
        }
        try lock.withLock {
            asked.insert(id)
            if let channel {
                try channel.sealThen(line) { try inner.write(line: $0) }
                return
            }
            if !host.isEmpty, keptMethods.contains(method), let params,
               let text = try? LockChannel.text(params),
               let signature = try? LockChannel.sign(signer.key, to: host, method: method, params: text),
               let signed = try? LockChannel.text(signature), let idText = try? LockChannel.text(id),
               let methodText = try? LockChannel.text(method) {
                try inner.write(line: "{\"id\":\(idText),\"jsonrpc\":\"2.0\",\"method\":\(methodText),\"params\":\(text),\"lock\":\(signed)}")
                return
            }
            try inner.write(line: line)
        }
    }

    private func heard(_ line: String) {
        guard let message = try? JSONRPCCodec.decode(line: line) else {
            continuation.yield(line)
            return
        }
        if message.id == helloID, lock.withLock({ helloWait != nil }) {
            resumeHello(message)
            return
        }
        guard let id = message.id, lock.withLock({ asked.remove(id) != nil }) else {
            continuation.yield(line)
            return
        }
        switch message {
        case .success, .failure:
            continuation.yield(checked(line, message, id: id))
        default:
            continuation.yield(line)
        }
    }

    /// An answer from the machine: taken with its MAC; with none only when it is a refusal (the
    /// control plane's own, offline say), or from a machine with no channel the lock does not name.
    private func checked(_ line: String, _ message: JSONRPCMessage, id: JSONRPCID) -> String {
        let channel = lock.withLock { self.channel }
        if LockChannel.sealed(line) {
            if let channel, let body = try? channel.open(line) { return body }
            return refusal(id, "The machine's answer does not check, so it was not taken.")
        }
        if case .success = message, channel != nil || required {
            return refusal(id, "The machine's answer was not signed, so it was not taken.")
        }
        return line
    }

    private func refusal(_ id: JSONRPCID, _ words: String) -> String {
        (try? JSONRPCCodec.encode(.failure(id: id, error: JSONRPCError(code: DaemonAPI.Failure.notInLock, message: words)))) ?? ""
    }

    private func ended(_ error: (any Error)?) {
        resumeHello(nil)
        continuation.finish(throwing: error)
    }

    func lines() -> AsyncThrowingStream<String, any Error> { stream }

    func close() {
        pump?.cancel()
        inner.close()
        resumeHello(nil)
        continuation.finish()
    }
}
#endif

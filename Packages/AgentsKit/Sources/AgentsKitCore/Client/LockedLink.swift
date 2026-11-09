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
/// Once the channel is open, what the machine says unasked (`agent/changed`, a question card)
/// is taken only with its MAC too (#3541). A transport with no channel opens one again when
/// the machine refuses a request as not in its lock: the machine took its lock after the
/// transport opened (#3642), or the lock was made after it (#4134): with no lock key yet, the
/// transport is wrapped all the same, so that refusal opens one.
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
        let signer = await source()
        let locked = LockedTransport(inner: transport, signer: signer, host: host, source: source)
        if signer != nil { await locked.open(within: 15) }
        return locked
    }
}

/// What may be kept for a machine that is not there, and so goes signed with no channel.
let keptMethods: Set<String> = ["agents/start", "agents/prompt"]

final class LockedTransport: LineTransport, @unchecked Sendable {
    private let inner: any LineTransport
    private let host: String
    private let source: LockedLink.Source
    private let lock = NSLock()
    /// The lock key and lock of the last hello: a later one reads them again. None before the
    /// lock exists: the transport is the plain one until a refusal finds one (#4134).
    private var signer: LockChannel.Signer?
    private var required: Bool
    private var channel: LockChannel.Channel?
    /// A hello is on its way again, after a refusal (#3642).
    private var reopening = false
    /// The ids of requests that went to the machine, until they are answered.
    private var asked: Set<JSONRPCID> = []
    private var helloID = JSONRPCID.string("lock-hello-" + UUID().uuidString)
    /// The hello sent, so its answer makes the channel as it is read, before the next line.
    private var hello: LockChannel.Hello?
    private var helloWait: CheckedContinuation<JSONRPCMessage?, Never>?
    private let stream: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private var pump: Task<Void, Never>?

    init(inner: any LineTransport, signer: LockChannel.Signer?, host: String, source: @escaping LockedLink.Source) {
        self.inner = inner
        self.signer = signer
        self.host = host
        self.source = source
        required = signer.map { LockChannel.names($0.state, host: host) } ?? false
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
        let (key, id) = lock.withLock { (signer?.key, helloID) }
        guard let key, let hello = try? LockChannel.hello(key), let params = try? JSONValue.encoding(hello.params),
              let line = try? JSONRPCCodec.encode(.request(id: id, method: DaemonAPI.Method.lockHello, params: params)) else { return }
        let reply: JSONRPCMessage? = await withCheckedContinuation { wait in
            lock.withLock {
                helloWait = wait
                self.hello = hello
            }
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
        if reply == nil || lock.withLock({ channel }) == nil {
            WireLog.write("lock: no checked channel to \(host.isEmpty ? "this Mac" : host)")
        }
    }

    /// The machine refused a request as not in its lock, and this transport has no channel: it
    /// took its lock after the transport opened. A hello again, with the lock as it is now, so
    /// the next request goes on a channel (#3642), as the web page's next call opens one.
    private func reopen() {
        let start = lock.withLock { () -> Bool in
            guard channel == nil, helloWait == nil, !reopening else { return false }
            reopening = true
            return true
        }
        guard start else { return }
        Task { [weak self] in
            guard let self else { return }
            if let signer = await source() {
                lock.withLock {
                    self.signer = signer
                    required = LockChannel.names(signer.state, host: host)
                    helloID = .string("lock-hello-" + UUID().uuidString)
                }
                await open(within: 15)
            }
            lock.withLock { reopening = false }
        }
    }

    /// The channel from lock/hello's answer, made as the answer is read: the machine MACs every
    /// line after it, a notification too (#3541).
    private func finish(_ reply: JSONRPCMessage) {
        lock.withLock {
            guard let hello, let signer, case .success(_, let result) = reply,
                  let answer = try? result.decode(DaemonAPI.LockHelloReply.self) else { return }
            channel = try? LockChannel.finish(hello, state: signer.state, host: host, reply: answer)
        }
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
            if !host.isEmpty, keptMethods.contains(method), let signer, let params,
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
        if lock.withLock({ message.id == helloID && helloWait != nil }) {
            finish(message)
            resumeHello(message)
            return
        }
        if case .notification(let method, _) = message, Capability.control[method] == nil {
            if let line = notice(line, method) { continuation.yield(line) }
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
        if case .success = message, channel != nil || lock.withLock({ required }) {
            return refusal(id, "The machine's answer was not signed, so it was not taken.")
        }
        if channel == nil, case .failure(_, let error) = message, error.code == DaemonAPI.Failure.notInLock { reopen() }
        return line
    }

    /// What the machine says unasked: with no channel, as it came; with one, only with its MAC,
    /// so the control plane cannot show a card the machine did not raise (#3541). The control
    /// plane's own notifications, on the Remote's one connection, are not the machine's.
    private func notice(_ line: String, _ method: String) -> String? {
        guard let channel = lock.withLock({ self.channel }) else { return line }
        if LockChannel.sealed(line), let body = try? channel.open(line) { return body }
        WireLog.write("lock: \(method) from \(host.isEmpty ? "this Mac" : host) does not check, so it was not taken")
        return nil
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

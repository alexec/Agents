#if !os(Linux)
import Foundation
import Security

/// The apps' way to the control plane (058, research R7, spike S2): a `URLSession`
/// WebSocket, one text message per line, which works in the App Store sandbox with only
/// `network.client`. Hosts dial with NIO instead (`ControlDial`); the key exchange on top
/// is the same (`ControlAuth.join`).
///
/// With a pin, only a certificate whose public key hashes to it is accepted, whatever its
/// name (R6). Without one, the certificate must be publicly trusted, as for any HTTPS.
public final class WebSocketLink: NSObject, LineTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    static let pingEvery: Duration = .seconds(20)

    private let pin: String?
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var opening: CheckedContinuation<Void, any Error>?
    private var pinger: Task<Void, Never>?
    /// A ping is out and its pong has not come back.
    private var awaitingPong = false
    private let stream: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation

    private init(pin: String?) {
        self.pin = pin
        var c: AsyncThrowingStream<String, any Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    /// A WebSocket to the control plane at `url` (`https://…`), open, as lines.
    public static func connect(_ url: URL, pin: String?, timeout: TimeInterval = 10) async throws -> WebSocketLink {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = parts.scheme?.lowercased() else {
            throw Failure("\(url) is not an address to dial")
        }
        parts.scheme = switch scheme {
        case "https", "wss": "wss"
        case "http", "ws": "ws"
        default: throw Failure("\(url) is not http or https")
        }
        parts.path = "/v1/connect"
        guard let socketURL = parts.url else { throw Failure("\(url) is not an address to dial") }
        let link = WebSocketLink(pin: pin)
        try await link.open(socketURL, timeout: timeout)
        return link
    }

    private func open(_ url: URL, timeout: TimeInterval) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        lock.withLock {
            self.session = session
            self.task = task
        }
        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Void, any Error>) in
            lock.withLock { opening = waiting }
            task.resume()
        }
        receive()
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingEvery)
                self?.ping()
            }
        }
    }

    private func receive() {
        guard let task = lock.withLock({ self.task }) else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(var text)):
                // By bytes, not characters (#165): a frame arrives as a bridged string, and
                // splitting one by Character walked every grapheme of every 20 KB record,
                // the window's largest cost per agent change once its sidebar stopped
                // refiling. A JSON line ends at an ASCII newline, which is one byte.
                text.makeContiguousUTF8()
                for line in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                    self.continuation.yield(String(decoding: line, as: UTF8.self))
                }
                self.receive()
            case .success(.data(let data)):
                self.continuation.yield(String(decoding: data, as: UTF8.self))
                self.receive()
            case .success:
                self.receive()
            case .failure(let error):
                self.finish(error)
            }
        }
    }

    private func ping() {
        guard let task = lock.withLock({ self.task }) else { return }
        // The last ping still has no pong a whole interval later: the far end is gone
        // without closing (a Mac asleep or switched off, a network that changed), and the
        // socket would look open until TCP gave up minutes from now. Let it go, so the
        // app reconnects and says it is reconnecting (073).
        let unanswered = lock.withLock { () -> Bool in
            defer { awaitingPong = true }
            return awaitingPong
        }
        if unanswered {
            finish(Failure("no answer to a ping in \(Self.pingEvery)"))
            return
        }
        task.sendPing { [weak self] error in
            if let error { self?.finish(error) } else { self?.lock.withLock { self?.awaitingPong = false } }
        }
    }

    public func write(line: String) throws {
        guard let task = lock.withLock({ self.task }) else { throw Failure("the WebSocket has closed") }
        task.send(.string(line)) { [weak self] error in
            if let error { self?.finish(error) }
        }
    }

    public func lines() -> AsyncThrowingStream<String, any Error> { stream }

    public func close() {
        let (task, session) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            defer { self.task = nil; self.session = nil }
            return (self.task, self.session)
        }
        pinger?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        continuation.finish()
    }

    private func finish(_ error: (any Error)?) {
        let (waiting, task, session) = lock.withLock {
            () -> (CheckedContinuation<Void, any Error>?, URLSessionWebSocketTask?, URLSession?) in
            defer { opening = nil }
            return (opening, self.task, self.session)
        }
        pinger?.cancel()
        // A refusal (suspended, over a plan's limit, #2235): the handshake's own answer
        // names the kind, in a header, because it cannot carry a body; the line it
        // refused with is asked for again, plainly, from the address that gave it.
        if let waiting, let error, let response = task?.response as? HTTPURLResponse,
           let kind = response.value(forHTTPHeaderField: ControlRefusal.header) {
            Task {
                let line = await Self.refusalLine(session: session, socketURL: task?.originalRequest?.url, kind: kind)
                self.lock.withLock { self.task = nil; self.session = nil }
                session?.invalidateAndCancel()
                waiting.resume(throwing: ControlRefusal(line: line))
                self.continuation.finish(throwing: error)
            }
            return
        }
        lock.withLock { self.task = nil; self.session = nil }
        session?.invalidateAndCancel()
        if let waiting {
            waiting.resume(throwing: error ?? Failure("the WebSocket closed before it opened"))
        }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }

    /// The words a refusal answered with, read back from `/readyz` on the same session
    /// (so the same pin and TLS trust apply): the handshake's HTTP answer has no body a
    /// `URLSessionWebSocketTask` delivers, so this is the only way to the line itself. The
    /// header's own value (the refusal's kind) stands in for it when that GET does not
    /// answer, or answers without `Agents-Refusal` (a copy's own "ready", #3146), so a
    /// refusal is never shown as silence or as something else's words.
    private static func refusalLine(session: URLSession?, socketURL: URL?, kind: String) async -> String {
        guard let session, var parts = socketURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return kind
        }
        parts.scheme = parts.scheme == "wss" ? "https" : "http"
        parts.path = "/readyz"
        guard let url = parts.url, let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 5)),
              (response as? HTTPURLResponse)?.value(forHTTPHeaderField: ControlRefusal.header) != nil else {
            return kind
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? kind : String(text.prefix(ControlRefusal.maxLineLength))
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { opening = nil }
            return opening
        }
        waiting?.resume()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(error)
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        guard let pin else {
            // A walk's stand-in for a public root (Debug builds only): trusted beside the system's.
            if let der = TestTrustRoot.der, let root = SecCertificateCreateWithData(nil, der as CFData) {
                SecTrustSetAnchorCertificates(trust, [root] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, false)
                return SecTrustEvaluateWithError(trust, nil)
                    ? completionHandler(.useCredential, URLCredential(trust: trust))
                    : completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return completionHandler(.performDefaultHandling, nil)
        }
        if let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first, Self.pin(of: leaf) == pin {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// The pin of a certificate: base64url of the SHA-256 of its SubjectPublicKeyInfo.
    /// Security gives a P-256 key as its X9.63 point, so the SPKI is the fixed P-256
    /// header before it (S2); any other kind of key has no pin here.
    static func pin(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? String == (kSecAttrKeyTypeECSECPrimeRandom as String),
              attributes[kSecAttrKeySizeInBits] as? Int == 256,
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?, point.count == 65 else { return nil }
        return ControlCode.base64url(ControlAgreement.sha256(p256Header + point))
    }

    /// `SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING (65 bytes) }`.
    static let p256Header = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])
}
#endif

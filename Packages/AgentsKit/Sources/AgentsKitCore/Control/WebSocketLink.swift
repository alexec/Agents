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
            case .success(.string(let text)):
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    self.continuation.yield(String(line))
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
        task.sendPing { [weak self] error in
            if let error { self?.finish(error) }
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
        let waiting = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { opening = nil }
            return opening
        }
        if let waiting {
            waiting.resume(throwing: error ?? Failure("the WebSocket closed before it opened"))
        }
        pinger?.cancel()
        let session = lock.withLock { () -> URLSession? in
            defer { self.task = nil; self.session = nil }
            return self.session
        }
        session?.invalidateAndCancel()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
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
        guard let pin else { return completionHandler(.performDefaultHandling, nil) }
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

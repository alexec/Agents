#if canImport(Network) && canImport(Security)
import AgentsKitCore
import Foundation
import Network
import Security

/// The Mac end of a sign-in relay (047, research R12; Claude's, 056): a runtime on a server
/// signs in with this Mac's own sign-in, which never leaves the Mac.
///
/// The server's runtime is given a stand-in sign-in with no secret in it and pointed at a
/// gate on its own loopback (`RelayGate`), which pipes to a socket the window's ssh forwards
/// back here. Here TLS is ended with a certificate the app made for itself, and every
/// request goes on to the runtime's own service with the Mac's current token in place of
/// the stand-in's. The token comes from a `MacSignInSource`, which picks up a renewal by the
/// runtime on the Mac; a 401 asks the source to renew, once (Codex's by the same exchange
/// Codex makes, Claude's by the Mac's own Claude), and the request is asked again.
///
/// The loopback TLS port is reachable by every account on this Mac (Network.framework cannot
/// listen on a Unix socket here), so a request is answered with this Mac's token only when
/// it carries the stand-in bearer that was handed to the server with the grant — a per-relay
/// secret, not the fixed Claude string that shipped in source (security review S4).
///
/// Logs say what was asked and how it was answered: a method, a path and a status. Never a
/// header or a body.
public final class MacSignInRelay: @unchecked Sendable {
    public let relay: SignInRelay
    public let signIn: any MacSignInSource
    public let certificates: RelayCertificates
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sign-in-relay")
    private let session: URLSession
    private let log: @Sendable (String) -> Void
    public private(set) var port: UInt16 = 0
    /// The stand-in's access token: the only `Authorization` that may draw this Mac's
    /// real token. Set when the grant is made; empty means nothing is lent yet.
    private let bearerLock = NSLock()
    private var _clientBearer = ""
    public var clientBearer: String {
        bearerLock.lock(); defer { bearerLock.unlock() }
        return _clientBearer
    }

    public init(relay: SignInRelay, signIn: any MacSignInSource, certificates: RelayCertificates,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.relay = relay
        self.signIn = signIn
        self.certificates = certificates
        self.log = log
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    /// Listen on `127.0.0.1` on a free port, over TLS with the app's own certificate.
    public func start() async throws -> UInt16 {
        if let listener, port != 0, listener.state == .ready { return port }
        let identity = try certificates.identity()
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else { throw RelayCertificates.Failure.identity }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let ready: UInt16 = try await withCheckedThrowingContinuation { done in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { done.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if once.take() { done.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        port = ready
        return ready
    }

    /// Remember the stand-in bearer that was given to a server with this grant. Only a
    /// request carrying that bearer draws this Mac's sign-in (S4).
    public func expectClientBearer(_ bearer: String) {
        bearerLock.lock()
        _clientBearer = bearer
        bearerLock.unlock()
    }

    /// A fresh stand-in token for Claude: shaped like a subscription token, unique per
    /// grant, so the fixed string in source is never enough to draw this Mac's sign-in.
    public static func freshClaudeStandIn() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return "sk-ant-oat01-agents-relay-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The access token a runtime will send as `Authorization: Bearer …`: Codex's from its
    /// stand-in JSON, Claude's the stand-in string itself.
    public static func clientBearer(fromStandIn standIn: String) -> String {
        guard let data = standIn.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else { return standIn }
        return access
    }

    /// The Authorization header's bearer value, or nil when there is none.
    static func bearer(in request: HTTPRequest) -> String? {
        guard let value = request.headers.first(where: { $0.name.lowercased() == "authorization" })?.value
        else { return nil }
        let prefix = "Bearer "
        if value.hasPrefix(prefix) { return String(value.dropFirst(prefix.count)) }
        return value
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    // MARK: One connection, one request

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                Task { await self.forward(request, on: connection, renewed: false) }
            case .incomplete where !done && error == nil:
                self.receiveRequest(connection, buffer: buffer)
            default:
                connection.cancel()
            }
        }
    }

    /// Hop-by-hop headers, and the ones the relay sets itself.
    static let dropped: Set<String> = ["host", "authorization", "x-api-key", "chatgpt-account-id", "connection", "keep-alive",
                                       "proxy-connection", "transfer-encoding", "content-length", "upgrade",
                                       "te", "trailer", "accept-encoding"]

    /// The upstream URL for a request target, or nil unless the target is origin-form: a
    /// path starting with one `/`, then an optional query, in characters a URL may carry
    /// as they are. Built by parts, so the host is always `host` and nothing in the target
    /// can become a user, a port or another host; and checked once built, all the same.
    static func upstreamURL(host: String, target: String) -> URL? {
        guard target.hasPrefix("/"), !target.hasPrefix("//") else { return nil }
        let allowed = CharacterSet.urlPathAllowed.union(.urlQueryAllowed).union(CharacterSet(charactersIn: "%"))
        guard target.unicodeScalars.allSatisfy(allowed.contains), hasWellFormedEscapes(target) else { return nil }
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = String(parts[0])
        if parts.count == 2 { components.percentEncodedQuery = String(parts[1]) }
        guard let url = components.url, url.scheme == "https", url.host == host,
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        return url
    }

    /// Every `%` followed by two hex digits.
    private static func hasWellFormedEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        let hex = Set("0123456789abcdefABCDEF".utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count,
                      hex.contains(bytes[index + 1]), hex.contains(bytes[index + 2]) else { return false }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private func forward(_ request: HTTPRequest, on connection: NWConnection, renewed: Bool) async {
        // A WebSocket upgrade is refused plainly: the runtime falls back to HTTPS at once,
        // where it would otherwise retry for seconds (research R12).
        if request.headers.contains(where: { $0.name.lowercased() == "upgrade" }) {
            log("relay: \(request.method) \(request.pathOnly) -> 404 (no WebSockets)")
            send(connection, head: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true)
            return
        }
        // The token goes only to the runtime's own service. A target that is not a plain
        // path could name another host (`@evil.example/`), so it is refused before the
        // sign-in is even read. The target is not logged: it is not one the relay knows.
        guard let url = Self.upstreamURL(host: relay.upstreamHost, target: request.target) else {
            log("relay: \(request.method) -> 400 (the request target is not a path)")
            send(connection, head: "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true)
            return
        }
        // Loopback TLS is every local account's to dial. Only the stand-in handed to the
        // server with the grant may draw this Mac's token (S4).
        let expected = clientBearer
        guard !expected.isEmpty, Self.bearer(in: request) == expected else {
            log("relay: \(request.method) \(request.pathOnly) -> 403 (not the stand-in)")
            send(connection, head: "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true)
            return
        }
        guard let token = try? signIn.current() else {
            log("relay: \(request.method) \(request.pathOnly) -> 502 (no sign-in on this Mac)")
            send(connection, head: "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true)
            return
        }
        let upstream = Self.upstream(request, url: url, token: token)

        let streamer = Streamer()
        let task = session.dataTask(with: upstream)
        task.delegate = streamer
        let response = await streamer.response(for: task)
        guard let http = response as? HTTPURLResponse else {
            log("relay: \(request.method) \(request.pathOnly) -> 502")
            send(connection, head: "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true)
            task.cancel()
            return
        }
        // A token the service no longer takes: renew it once, the runtime's own way, and
        // ask again. What the runtime is sent is the answer to the second asking.
        if http.statusCode == 401, !renewed {
            task.cancel()
            log("relay: \(request.method) \(request.pathOnly) -> 401; renewing this Mac's sign-in")
            if (try? await signIn.renew(after: token)) != nil {
                await forward(request, on: connection, renewed: true)
                return
            }
            log("relay: renewing failed; this Mac's sign-in needs signing in again")
        }
        log("relay: \(request.method) \(request.pathOnly) -> \(http.statusCode)")
        var head = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\n"
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            let lower = name.lowercased()
            if ["transfer-encoding", "connection", "content-length", "content-encoding", "keep-alive"].contains(lower) { continue }
            head += "\(name): \(value)\r\n"
        }
        head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        send(connection, head: head, close: false)
        for await chunk in streamer.body {
            guard !chunk.isEmpty else { continue }
            var framed = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
            framed.append(chunk)
            framed.append(Data("\r\n".utf8))
            connection.send(content: framed, completion: .contentProcessed { _ in })
        }
        send(connection, head: "0\r\n\r\n", close: true)
    }

    /// The request as it goes on to the service: everything the runtime sent but its own
    /// sign-in (`Authorization`, `x-api-key`) and hop-by-hop headers, with this Mac's token
    /// and the headers the sign-in carries (Codex's account id) in their place, sent to a
    /// `url` that `upstreamURL` has already checked.
    static func upstream(_ request: HTTPRequest, url: URL, token: MacSignInToken) -> URLRequest {
        var upstream = URLRequest(url: url)
        upstream.httpMethod = request.method
        for header in request.headers where !dropped.contains(header.name.lowercased()) {
            upstream.addValue(header.value, forHTTPHeaderField: header.name)
        }
        upstream.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
        for (name, value) in token.headers { upstream.setValue(value, forHTTPHeaderField: name) }
        if !request.body.isEmpty { upstream.httpBody = request.body }
        return upstream
    }

    private func send(_ connection: NWConnection, head: String, close: Bool) {
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    /// One upstream task's answer: its response first, then its body as it arrives.
    final class Streamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var responseWaiter: CheckedContinuation<URLResponse?, Never>?
        private var gotResponse: URLResponse??
        let body: AsyncStream<Data>
        private let bodyContinuation: AsyncStream<Data>.Continuation

        override init() {
            (body, bodyContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        }

        func response(for task: URLSessionDataTask) async -> URLResponse? {
            await withCheckedContinuation { done in
                lock.lock()
                if let got = gotResponse { lock.unlock(); done.resume(returning: got); return }
                responseWaiter = done
                lock.unlock()
                task.resume()
            }
        }

        private func answer(_ response: URLResponse?) {
            lock.lock()
            guard gotResponse == nil else { lock.unlock(); return }
            gotResponse = .some(response)
            let waiter = responseWaiter
            responseWaiter = nil
            lock.unlock()
            waiter?.resume(returning: response)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            answer(response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            bodyContinuation.yield(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            answer(nil)
            bodyContinuation.finish()
        }
    }
}

/// A flag that is taken once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if taken { return false }; taken = true; return true }
}

/// Just enough of an HTTP/1.1 request to relay it: the request line, the headers, and a
/// body sized by `Content-Length` or sent chunked.
struct HTTPRequest: Sendable, Equatable {
    struct Header: Sendable, Equatable { var name: String; var value: String }
    var method: String
    var target: String
    var headers: [Header]
    var body: Data

    var pathOnly: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

    enum Parsed: Equatable { case complete(HTTPRequest), incomplete, invalid }

    static func parse(_ data: Data) -> Parsed {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else { return data.count > 65536 ? .invalid : .incomplete }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [Header] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append(Header(name: String(line[..<colon]),
                                  value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        let rest = data[end.upperBound...]
        func value(_ name: String) -> String? { headers.first { $0.name.lowercased() == name }?.value }
        let body: Data
        if value("transfer-encoding")?.lowercased().contains("chunked") == true {
            guard let decoded = dechunk(Data(rest)) else { return .incomplete }
            body = decoded
        } else {
            let length = Int(value("content-length") ?? "0") ?? 0
            guard rest.count >= length else { return .incomplete }
            body = Data(rest.prefix(length))
        }
        return .complete(HTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]),
                                     headers: headers, body: body))
    }

    /// A whole chunked body, or nil while it is still arriving.
    static func dechunk(_ data: Data) -> Data? {
        var out = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let line = data[index...].range(of: crlf) else { return nil }
            let sizeText = String(decoding: data[index..<line.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            let start = line.upperBound
            if size == 0 { return out }
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else { return nil }
            let stop = data.index(start, offsetBy: size)
            out.append(data[start..<stop])
            index = data.index(stop, offsetBy: 2)
        }
    }
}

// MARK: The relay's own certificates

/// A certificate authority the app makes for itself, once, and a server certificate for
/// `127.0.0.1` it signs (research R12: rustls refuses a certificate that is its own CA).
/// The keys stay in `folder`, private to this account; only the CA's public certificate is
/// ever sent to a server.
public struct RelayCertificates: Sendable {
    public var folder: URL
    public var openssl: URL

    public init(folder: URL, openssl: URL = URL(filePath: "/usr/bin/openssl")) {
        self.folder = folder
        self.openssl = openssl
    }

    public enum Failure: Error { case openssl(String), identity }

    var caCertificate: URL { folder.appendingPathComponent("ca.pem") }
    var bundle: URL { folder.appendingPathComponent("relay.p12") }
    var bundlePassword: URL { folder.appendingPathComponent("relay.p12.pass") }

    /// The CA's public certificate, made first if need be.
    public func caPEM() throws -> String {
        try ensure()
        return try String(contentsOf: caCertificate, encoding: .utf8)
    }

    /// The server certificate and its key, for TLS.
    public func identity() throws -> SecIdentity {
        try ensure()
        let password = try String(contentsOf: bundlePassword, encoding: .utf8)
        var items: CFArray?
        // In memory only: nothing goes into the person's keychain, and the import works the
        // same in a process that has no keychain of its own to put it in.
        let options: [String: Any] = [kSecImportExportPassphrase as String: password,
                                      kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(try Data(contentsOf: bundle) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { throw Failure.identity }
        return identity as! SecIdentity
    }

    /// Make the CA and the server certificate when either is missing. Two years each; the
    /// folder is 0700 and every key 0600. The curve is named, not spelled out: macOS's own
    /// LibreSSL spells it out unless told, and Security then cannot read the key. And SHA-256
    /// throughout: its default signature hash is SHA-1, which Security and rustls refuse.
    public func ensure() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: caCertificate.path), fm.fileExists(atPath: bundle.path),
           fm.fileExists(atPath: bundlePassword.path) { return }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let caKey = folder.appendingPathComponent("ca-key.pem"), key = folder.appendingPathComponent("relay-key.pem")
        let csr = folder.appendingPathComponent("relay.csr"), cert = folder.appendingPathComponent("relay-cert.pem")
        let ext = folder.appendingPathComponent("relay.ext")
        try "subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\n"
            .write(to: ext, atomically: true, encoding: .utf8)
        let password = UUID().uuidString + UUID().uuidString
        try run(["req", "-x509", "-sha256", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-days", "730",
                 "-subj", "/CN=Agents sign-in relay", "-addext", "basicConstraints=critical,CA:TRUE",
                 "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-keyout", caKey.path, "-out", caCertificate.path])
        try run(["req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve", "-nodes",
                 "-subj", "/CN=127.0.0.1", "-keyout", key.path, "-out", csr.path])
        try run(["x509", "-req", "-sha256", "-in", csr.path, "-CA", caCertificate.path, "-CAkey", caKey.path, "-CAcreateserial",
                 "-days", "730", "-extfile", ext.path, "-out", cert.path])
        try password.write(to: bundlePassword, atomically: true, encoding: .utf8)
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", bundle.path,
                 "-passout", "file:\(bundlePassword.path)"])
        for file in [caKey, key, bundle, bundlePassword] {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        for file in [csr, ext] { try? fm.removeItem(at: file) }
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = openssl
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let text = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.openssl(String(decoding: text, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "")
        }
    }
}
#endif

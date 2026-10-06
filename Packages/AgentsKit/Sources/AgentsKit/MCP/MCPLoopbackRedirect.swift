#if canImport(Network) && canImport(Security)
import Foundation
import Network

/// Where the browser comes back to after an MCP sign-in (#306): `http://127.0.0.1:PORT/callback`,
/// a loopback redirect for a native app (RFC 8252 §7.3), open for one sign-in only.
///
/// Why loopback, and why here: the daemon holds the PKCE verifier and keeps the grant, and
/// the window may be a sandboxed client of it, so the daemon catches the code itself; the
/// window only opens the page in the person's own browser, where they are already signed
/// in. The MCP spec asks for a redirect that is either loopback or https, so a custom
/// scheme (what ASWebAuthenticationSession returns to) is not one a server need accept,
/// and an https one would need a domain of the app's own.
///
/// Every account on this Mac can reach a loopback port, so only a request with this
/// sign-in's `state` is answered as the callback; and a code is worth nothing without the
/// verifier, which never leaves the daemon. Nothing a request carries is logged.
final class MCPLoopbackRedirect: @unchecked Sendable {
    /// What came back on the callback.
    struct Callback: Equatable, Sendable {
        var query: [String: String]
    }

    private let state: String
    private let queue = DispatchQueue(label: "mcp-sign-in-redirect")
    private var listener: NWListener?
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Callback?, Never>?
    private var arrived: Callback??
    /// Answers the browser once the callback is dealt with: the page it shows.
    private var pending: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(state: String) {
        self.state = state
    }

    var redirect: String { "http://127.0.0.1:\(port)/callback" }

    /// Listen on `127.0.0.1` on a free port.
    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        port = try await withCheckedThrowingContinuation { done in
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
    }

    /// The callback, or nil when it is stopped first.
    func callback() async -> Callback? {
        await withCheckedContinuation { done in
            lock.lock()
            if let arrived { lock.unlock(); done.resume(returning: arrived); return }
            waiter = done
            lock.unlock()
        }
    }

    /// Show the browser a page, and stop listening.
    func finish(title: String, body: String) {
        let html = """
        <!doctype html><meta charset="utf-8"><title>\(Self.escape(title))</title>
        <body style="font: 15px -apple-system, sans-serif; margin: 4em auto; max-width: 32em; color: #222">
        <h1 style="font-size: 20px">\(Self.escape(title))</h1><p>\(Self.escape(body))</p></body>
        """
        let connections = lock.withLock { () -> [NWConnection] in
            defer { pending = [] }
            return pending
        }
        for connection in connections {
            respond(connection, status: "200 OK", type: "text/html; charset=utf-8", body: html)
        }
        stop()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        deliver(nil)
    }

    private func deliver(_ callback: Callback?) {
        lock.lock()
        guard arrived == nil else { lock.unlock(); return }
        arrived = .some(callback)
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: callback)
    }

    // MARK: One connection, one request

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                self.answer(request, on: connection)
            case .incomplete where !done && error == nil && buffer.count < 64 * 1024:
                self.receive(connection, buffer: buffer)
            default:
                connection.cancel()
            }
        }
    }

    private func answer(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.method == "GET", request.pathOnly == "/callback",
              let parts = URLComponents(string: "http://127.0.0.1\(request.target)") else {
            respond(connection, status: "404 Not Found", type: "text/plain", body: "")
            return
        }
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] { query[item.name] = item.value ?? "" }
        guard query["state"] == state else {
            respond(connection, status: "400 Bad Request", type: "text/plain",
                    body: "This isn't the sign-in Agents is waiting for.")
            return
        }
        let first = lock.withLock { () -> Bool in
            guard arrived == nil else { return false }
            pending.append(connection)
            return true
        }
        guard first else {
            respond(connection, status: "409 Conflict", type: "text/plain", body: "This sign-in is already done.")
            return
        }
        deliver(Callback(query: query))
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(bytes)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
#endif

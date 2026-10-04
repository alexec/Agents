import AgentsKitCore
import ControlDial
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// The web remote's door (071, research R2–R3, contracts/loopback-listener.md): plain HTTP on
/// 127.0.0.1 and ::1 only, serving the built web app and its WebSocket at `/v1/connect`.
/// Its canonical origin is `http://localhost:<port>`; the key exchange on it is bound to that.
public enum Loopback {
    /// Where Agents Host's single copy serves it.
    public static let defaultPort = 8792

    public static func origin(port: Int) -> String { "http://localhost:\(port)" }
}

/// The built web app, read once at start from `Web/dist/MANIFEST` and held in memory: only
/// the files the manifest lists, and only with the bytes it records.
public struct WebFiles: Sendable {
    public struct File: Sendable {
        public var data: Data
        public var contentType: String
    }

    public let files: [String: File]

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    static let types = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "woff2": "font/woff2",
    ]

    public init(files: [String: File]) { self.files = files }

    /// Every `out` line of `folder/MANIFEST`, served at its path under `Web/dist`.
    public static func load(from folder: URL) throws -> WebFiles {
        let manifest = folder.appending(path: "MANIFEST")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else {
            throw Failure(description: "\(manifest.path) is missing")
        }
        var files: [String: File] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[0] == "out" else { continue }
            let (hash, path) = (parts[1], parts[2])
            guard path.hasPrefix("Web/dist/") else { throw Failure(description: "\(path) is not under Web/dist") }
            let relative = String(path.dropFirst("Web/dist/".count))
            guard let type = types[(relative as NSString).pathExtension.lowercased()] else {
                throw Failure(description: "\(relative) has a type the web remote never serves")
            }
            guard let data = try? Data(contentsOf: folder.appending(path: relative)),
                  ControlAgreement.sha256(data).map({ String(format: "%02x", $0) }).joined() == hash else {
                throw Failure(description: "\(relative) does not match its manifest")
            }
            files["/" + relative] = File(data: data, contentType: type)
        }
        guard files["/index.html"] != nil else { throw Failure(description: "the manifest lists no index.html") }
        return WebFiles(files: files)
    }
}

/// What the loopback listener does with each request, in the contract's order. Pure, so
/// every row of the contract is a test.
public struct LoopbackGate: Sendable {
    public let port: Int
    public let files: WebFiles

    public init(port: Int, files: WebFiles) {
        self.port = port
        self.files = files
    }

    public var origin: String { Loopback.origin(port: port) }

    /// The sandbox proxy's origin (#187, MCP Apps): the same listener at the address rather than
    /// the name, so another origin than the page's, as the spec has it for a web page. Only the
    /// proxy's two files are served there; everything else at it goes to the name, as before.
    public var proxyOrigin: String { "http://127.0.0.1:\(port)" }
    static let proxyPaths: Set<String> = ["/sandbox.html", "/sandbox.js"]

    public enum Verdict: Equatable, Sendable {
        case upgrade
        case reply(HTTPResponseStatus, path: String?, location: String?)
    }

    /// Sent on every answer, a refusal included.
    public var headers: [(String, String)] {
        [("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; "
            + "font-src 'self'; connect-src ws://localhost:\(port); base-uri 'none'; form-action 'none'; "
            + "frame-ancestors 'none'; frame-src \(proxyOrigin); object-src 'none'; worker-src 'none'; manifest-src 'none'; "
            + "require-trusted-types-for 'script'; trusted-types 'none'"),
         ("X-Content-Type-Options", "nosniff"),
         ("Referrer-Policy", "no-referrer"),
         ("Cross-Origin-Opener-Policy", "same-origin"),
         ("Cross-Origin-Resource-Policy", "same-origin"),
         ("X-Frame-Options", "DENY"),
         ("Cache-Control", "no-cache")]
    }

    public func judge(_ head: HTTPRequestHead) -> Verdict {
        let host = head.headers.first(name: "host")?.lowercased() ?? ""
        let canonical = "localhost:\(port)"
        // 1. DNS rebinding: a name that only resolves here is still refused.
        guard [canonical, "127.0.0.1:\(port)", "[::1]:\(port)"].contains(host) else {
            return .reply(.misdirectedRequest, path: nil, location: nil)
        }
        // 2. Nothing here changes anything.
        guard head.method == .GET else { return .reply(.methodNotAllowed, path: nil, location: nil) }
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let upgrading = head.headers[canonicalForm: "upgrade"].contains { $0.lowercased() == "websocket" }
        // The sandbox proxy (#187): at its own origin only, never at the page's.
        if Self.proxyPaths.contains(path) {
            guard host == "127.0.0.1:\(port)", !upgrading, files.files[path] != nil else {
                return .reply(.notFound, path: nil, location: nil)
            }
            return .reply(.ok, path: path, location: nil)
        }
        // 3. One origin, so one key: the addresses go to the name.
        if host != canonical {
            if upgrading { return .reply(.misdirectedRequest, path: nil, location: nil) }
            return .reply(.permanentRedirect, path: nil, location: "http://\(canonical)\(path)")
        }
        // 4–5. The socket, from this page only.
        if path == "/v1/connect" || upgrading {
            guard path == "/v1/connect", upgrading else { return .reply(.badRequest, path: nil, location: nil) }
            guard head.headers.first(name: "origin") == origin else { return .reply(.forbidden, path: nil, location: nil) }
            return .upgrade
        }
        // 6–7. The files the manifest lists, and nothing else.
        let file = path == "/" ? "/index.html" : path
        return files.files[file] == nil ? .reply(.notFound, path: nil, location: nil) : .reply(.ok, path: file, location: nil)
    }

    /// The answer to a request that is not an upgrade.
    public func reply(_ head: HTTPRequestHead) -> PlainReply {
        switch judge(head) {
        case .upgrade:
            // Reached only if the upgrade itself failed after the gate let it through.
            return PlainReply(.badRequest, Data(), contentType: "text/plain", headers: headers)
        case .reply(let status, let path, _) where path.map(Self.proxyPaths.contains) == true:
            let headers = proxyHeaders(head)
            if let path, let file = files.files[path] {
                return PlainReply(status, file.data, contentType: file.contentType, headers: headers)
            }
            return PlainReply(status, Data(), contentType: "text/plain; charset=utf-8", headers: headers)
        case .reply(let status, let path, let location):
            var headers = self.headers
            if let location { headers.append(("Location", location)) }
            if let path, let file = files.files[path] {
                return PlainReply(status, file.data, contentType: file.contentType, headers: headers)
            }
            return PlainReply(status, Data(), contentType: "text/plain; charset=utf-8", headers: headers)
        }
    }
}

extension LoopbackGate {
    /// The proxy's headers: the view's own policy, built here again from the domains in the
    /// address (`?csp=`, base64url JSON) by the same `AppViewPolicy` that narrowed them, so an
    /// address written by hand can allow no more than an origin each; framed by the page alone.
    func proxyHeaders(_ head: HTTPRequestHead) -> [(String, String)] {
        let policy = AppViewPolicy(csp: Self.domains(in: head.uri))
        return [("Content-Security-Policy", policy.header + "; frame-ancestors \(origin)"),
                ("X-Content-Type-Options", "nosniff"),
                ("Referrer-Policy", "no-referrer"),
                ("Cross-Origin-Resource-Policy", "same-origin"),
                ("Cache-Control", "no-store")]
    }

    /// The `csp` query's domains, or nothing: the strict default.
    static func domains(in uri: String) -> JSONValue? {
        guard let query = URLComponents(string: uri)?.queryItems?.first(where: { $0.name == "csp" })?.value,
              query.count <= 8192 else { return nil }
        var text = query.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text) else { return nil }
        return try? JSONValue.parse(data)
    }
}

/// The two binds, 127.0.0.1 and ::1, on one port.
final class LoopbackListener: @unchecked Sendable {
    private var channels: [any Channel] = []
    private(set) var port = 0

    /// Binds both loopback addresses. With port 0, the system chooses for 127.0.0.1 and ::1
    /// takes the same. Returns the port.
    func start(port wanted: Int, files: WebFiles,
               log: @escaping @Sendable (String) -> Void,
               opened: @escaping @Sendable (WebSocketLineTransport, String) -> Void) async throws -> Int {
        let box = GateBox()
        func bootstrap() -> ServerBootstrap {
            ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    guard let gate = box.gate else { return channel.close() }
                    return ControlWebSocketServer.configure(channel, tls: nil, reply: { head in
                        let reply = gate.reply(head)
                        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
                        log("web \(head.method.rawValue) \(path) \(reply.status.code)")
                        return reply
                    }, upgrade: { head in
                        gate.judge(head) == .upgrade
                    }, opened: { socket in
                        opened(socket, gate.origin)
                    })
                }
        }
        let v4 = try await bootstrap().bind(host: "127.0.0.1", port: wanted).get()
        let port = v4.localAddress?.port ?? wanted
        box.gate = LoopbackGate(port: port, files: files)
        channels = [v4]
        do {
            channels.append(try await bootstrap().bind(host: "::1", port: port).get())
        } catch let error as IOError where error.errnoCode == EADDRNOTAVAIL || error.errnoCode == EAFNOSUPPORT {
            // No IPv6 loopback on this Mac, so nothing else can answer a browser there either.
            log("web: no ::1 on this Mac (\(error)); serving 127.0.0.1 only")
        } catch {
            // Something else holds ::1 on this port, where a browser may well go for localhost.
            // Serving 127.0.0.1 alone would send the page's visitors to it, at this page's own
            // origin, with the browser's key to use (071 security review, R1).
            try? await v4.close()
            channels = []
            throw error
        }
        self.port = port
        return port
    }

    func stop() async {
        for channel in channels { try? await channel.close() }
        channels = []
    }
}

/// The gate is made once the port is known; connections only arrive after that.
private final class GateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LoopbackGate?
    var gate: LoopbackGate? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

/// The web remote's loopback listener (071, contracts/loopback-listener.md): every row of
/// the contract's tables, then the listener itself on a real copy.
@Suite("The web remote's loopback listener", .timeLimit(.minutes(2)))
struct LoopbackListenerTests {
    static let port = 8899
    static let files = WebFiles(files: [
        "/index.html": .init(data: Data("<!doctype html>".utf8), contentType: "text/html; charset=utf-8"),
        "/app.js": .init(data: Data("export{}".utf8), contentType: "text/javascript; charset=utf-8"),
    ])
    let gate = LoopbackGate(port: port, files: files)

    func head(_ uri: String, host: String? = "localhost:8899", method: HTTPMethod = .GET, origin: String? = nil,
              upgrade: Bool = false) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        if let host { headers.add(name: "Host", value: host) }
        if let origin { headers.add(name: "Origin", value: origin) }
        if upgrade {
            headers.add(name: "Upgrade", value: "websocket")
            headers.add(name: "Connection", value: "Upgrade")
        }
        return HTTPRequestHead(version: .http1_1, method: method, uri: uri, headers: headers)
    }

    func status(_ head: HTTPRequestHead) -> HTTPResponseStatus? {
        if case .reply(let status, _, _) = gate.judge(head) { return status }
        return nil
    }

    // MARK: 1. Host

    @Test func aHostThatIsNotThisListenerIsMisdirected() {
        #expect(status(head("/", host: "evil.test:8899")) == .misdirectedRequest)
        #expect(status(head("/", host: "localhost:1")) == .misdirectedRequest)
        #expect(status(head("/", host: "localhost")) == .misdirectedRequest)
        #expect(status(head("/", host: nil)) == .misdirectedRequest)
        #expect(status(head("/v1/connect", host: "evil.test:8899", origin: "http://localhost:8899", upgrade: true))
            == .misdirectedRequest)
        #expect(status(head("/", host: "LOCALHOST:8899")) == .ok)
    }

    // MARK: 2. Method

    @Test func onlyGETIsAnswered() {
        for method in [HTTPMethod.POST, .PUT, .DELETE, .HEAD, .OPTIONS] {
            #expect(status(head("/", method: method)) == .methodNotAllowed)
        }
    }

    // MARK: 3. Redirect

    @Test func theAddressesRedirectToTheName() {
        #expect(gate.judge(head("/app.js?x=1", host: "127.0.0.1:8899"))
            == .reply(.permanentRedirect, path: nil, location: "http://localhost:8899/app.js"))
        #expect(gate.judge(head("/", host: "[::1]:8899"))
            == .reply(.permanentRedirect, path: nil, location: "http://localhost:8899/"))
        // Never for an upgrade: the page that dials is on the name already.
        #expect(status(head("/v1/connect", host: "127.0.0.1:8899", origin: "http://localhost:8899", upgrade: true))
            == .misdirectedRequest)
    }

    // MARK: 4–5. The upgrade

    @Test func theUpgradeNeedsThisPagesOrigin() {
        #expect(gate.judge(head("/v1/connect", origin: "http://localhost:8899", upgrade: true)) == .upgrade)
        #expect(gate.judge(head("/v1/connect?x", origin: "http://localhost:8899", upgrade: true)) == .upgrade)
        #expect(status(head("/v1/connect", upgrade: true)) == .forbidden)
        #expect(status(head("/v1/connect", origin: "http://evil.test", upgrade: true)) == .forbidden)
        #expect(status(head("/v1/connect", origin: "http://127.0.0.1:8899", upgrade: true)) == .forbidden)
        #expect(status(head("/v1/connect", origin: "https://localhost:8899", upgrade: true)) == .forbidden)
        #expect(status(head("/v1/connect", origin: "null", upgrade: true)) == .forbidden)
    }

    @Test func connectWithoutAnUpgradeOrAnUpgradeElsewhereIsBad() {
        #expect(status(head("/v1/connect")) == .badRequest)
        #expect(status(head("/app.js", origin: "http://localhost:8899", upgrade: true)) == .badRequest)
    }

    // MARK: 6–7. Files

    @Test func theManifestsFilesAndNothingElse() {
        #expect(gate.judge(head("/")) == .reply(.ok, path: "/index.html", location: nil))
        #expect(gate.judge(head("/app.js?v=2")) == .reply(.ok, path: "/app.js", location: nil))
        for path in ["/nope", "/MANIFEST", "/../MANIFEST", "/%2e%2e/MANIFEST", "/app.js%00", "/app.js\\..\\x",
                     "//app.js", "/healthz", "/readyz", "/v1/install.sh", "/v1/servers/agentsd"] {
            #expect(status(head(path)) == .notFound, "\(path)")
        }
    }

    @Test func everyAnswerCarriesTheHeaders() {
        let heads = [head("/"), head("/nope"), head("/", method: .POST), head("/", host: "evil:1"),
                     head("/", host: "127.0.0.1:8899"), head("/v1/connect", upgrade: true), head("/v1/connect")]
        for head in heads {
            let reply = gate.reply(head)
            let names = Set(reply.headers.map { $0.0 })
            for wanted in ["Content-Security-Policy", "X-Content-Type-Options", "Referrer-Policy", "Cross-Origin-Opener-Policy",
                           "Cross-Origin-Resource-Policy", "X-Frame-Options", "Cache-Control"] {
                #expect(names.contains(wanted), "\(wanted) on \(reply.status.code)")
            }
        }
        let csp = gate.headers.first { $0.0 == "Content-Security-Policy" }?.1 ?? ""
        #expect(csp.contains("connect-src ws://localhost:8899;"))
        #expect(csp.contains("default-src 'none'"))
        #expect(csp.contains("trusted-types 'none'"))
        #expect(!csp.contains("unsafe"))
        // FR-030, clause by clause: own-origin scripts, styles, fonts and images (and blob: and
        // data: pictures), no frames either way, no plugins, no form posting, no base to move.
        for clause in ["script-src 'self';", "style-src 'self';", "font-src 'self';", "img-src 'self' blob: data:;",
                       "frame-ancestors 'none';", "frame-src 'none';", "object-src 'none';", "form-action 'none';",
                       "base-uri 'none';"] {
            #expect(csp.contains(clause), "CSP lacks \(clause)")
        }
        let value = { (name: String) in gate.headers.first { $0.0 == name }?.1 }
        #expect(value("X-Content-Type-Options") == "nosniff")
        #expect(value("Referrer-Policy") == "no-referrer")
        #expect(value("Cross-Origin-Opener-Policy") == "same-origin")
        #expect(value("Cross-Origin-Resource-Policy") == "same-origin")
        #expect(value("X-Frame-Options") == "DENY")
    }

    /// FR-032: nothing ambient. No answer sets a cookie or asks for HTTP authentication, and a
    /// request carrying either is answered exactly as one without, so a cross-site request has
    /// nothing to ride on.
    @Test func noCookieAndNoHTTPAuthenticationEitherWay() {
        for (uri, upgrade) in [("/", false), ("/app.js", false), ("/nope", false), ("/v1/connect", false), ("/v1/connect", true)] {
            var carrying = head(uri, origin: upgrade ? "http://localhost:8899" : nil, upgrade: upgrade)
            carrying.headers.add(name: "Cookie", value: "session=stolen")
            carrying.headers.add(name: "Authorization", value: "Basic c3RvbGVu")
            let plain = gate.reply(head(uri, origin: upgrade ? "http://localhost:8899" : nil, upgrade: upgrade))
            let with = gate.reply(carrying)
            #expect(plain.status == with.status && plain.body == with.body, "\(uri)")
            for reply in [plain, with] {
                let names = Set(reply.headers.map { $0.0.lowercased() })
                #expect(!names.contains("set-cookie") && !names.contains("www-authenticate"), "\(uri)")
            }
        }
    }

    // MARK: The files from the manifest

    @Test func filesLoadOnlyWhenTheyMatchTheirManifest() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = Data("<!doctype html>".utf8)
        try index.write(to: folder.appending(path: "index.html"))
        func manifest(_ lines: [String]) throws {
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appending(path: "MANIFEST"))
        }
        let hash = ControlAgreement.sha256(index).map { String(format: "%02x", $0) }.joined()
        try manifest(["agents-web 1", "src abc Web/src/main.tsx", "out \(hash) Web/dist/index.html"])
        #expect(try WebFiles.load(from: folder).files.keys.sorted() == ["/index.html"])

        try manifest(["out \(String(repeating: "0", count: 64)) Web/dist/index.html"])
        #expect(throws: WebFiles.Failure.self) { try WebFiles.load(from: folder) }

        try Data("x".utf8).write(to: folder.appending(path: "run.sh"))
        let other = ControlAgreement.sha256(Data("x".utf8)).map { String(format: "%02x", $0) }.joined()
        try manifest(["out \(hash) Web/dist/index.html", "out \(other) Web/dist/run.sh"])
        #expect(throws: WebFiles.Failure.self) { try WebFiles.load(from: folder) }
    }

    // MARK: The listener on a real copy

    static let dist = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Web/dist")

    func start(web: ControlService.Configuration.Web?) async throws -> (ControlService, Int) {
        let port = try await freePort()
        var configuration = ControlService.Configuration(
            store: MemoryStore(), privateKey: ControlAgreement.generate().privateKey,
            url: URL(string: "http://127.0.0.1:\(port)")!, bind: "127.0.0.1", port: port, name: "test")
        configuration.web = web
        let service = try ControlService(configuration)
        try await service.start()
        return (service, port)
    }

    @Test func aCopyServesTheBuiltPageOnBothLoopbackAddresses() async throws {
        let (service, _) = try await start(web: .init(folder: Self.dist, port: 0))
        defer { Task { await service.stop() } }
        let port = try #require(service.webPort)

        let (body, response) = try await Self.get("http://localhost:\(port)/")
        #expect(response.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("<script type=\"module\" src=\"/app.js\">"))
        #expect(response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("ws://localhost:\(port)") == true)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/html; charset=utf-8")

        let (_, v4) = try await Self.get("http://127.0.0.1:\(port)/app.js")
        #expect(v4.statusCode == 308)
        #expect(v4.value(forHTTPHeaderField: "Location") == "http://localhost:\(port)/app.js")
        let (_, v6) = try await Self.get("http://[::1]:\(port)/")
        #expect(v6.statusCode == 308)
    }

    @Test func itIsNotReachableOnAnotherAddressOfThisMac() async throws {
        let (service, _) = try await start(web: .init(folder: Self.dist, port: 0))
        defer { Task { await service.stop() } }
        let port = try #require(service.webPort)
        let addresses = Self.nonLoopbackIPv4()
        try #require(!addresses.isEmpty, "this machine has no other IPv4 address to try")
        for address in addresses {
            await #expect(throws: (any Error).self, "reached on \(address)") {
                _ = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connectTimeout(.seconds(2)).connect(host: address, port: port).get()
            }
        }
    }

    @Test func aBuildThatDoesNotMatchItsManifestLeavesTheListenerOff() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "web-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Self.dist, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("/* edited */".utf8).write(to: folder.appending(path: "app.js"))
        let (service, port) = try await start(web: .init(folder: folder, port: 0))
        defer { Task { await service.stop() } }
        #expect(service.webPort == nil)
        let (_, response) = try await Self.get("http://127.0.0.1:\(port)/healthz")
        #expect(response.statusCode == 200, "the TLS listener carries on")
    }

    @Test func aTakenPortLeavesTheListenerOffAndTheRestUp() async throws {
        let taken = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        defer { taken.close(promise: nil) }
        let (service, port) = try await start(web: .init(folder: Self.dist, port: taken.localAddress?.port ?? 0))
        defer { Task { await service.stop() } }
        #expect(service.webPort == nil)
        let (_, response) = try await Self.get("http://127.0.0.1:\(port)/healthz")
        #expect(response.statusCode == 200)
    }

    // MARK: Helpers

    /// A GET that stops at a redirect rather than following it.
    static func get(_ text: String) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: URL(string: text)!)
        return (data, try #require(response as? HTTPURLResponse))
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    static func nonLoopbackIPv4() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (pointer.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (pointer.pointee.ifa_flags & UInt32(IFF_UP)) != 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return found
    }
}

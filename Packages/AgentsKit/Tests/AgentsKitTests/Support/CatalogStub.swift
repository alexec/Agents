#if canImport(CryptoKit)
import Foundation
@testable import AgentsKit

/// A stand-in for skills.sh and GitHub (059, tasks T006), answering from the recorded
/// fixtures in `Fixtures/catalog/http`, which were made from a real git repository
/// (`specs/059-marketplace/walk/make-http-fixtures.py`).
///
/// Each test gets its own: the session carries an id in a header, and the class looks its
/// state up by it, so suites running side by side do not answer each other's requests.
final class CatalogStub: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case normal, down, rateLimited }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _mode: Mode = .normal
        private var _requests: [URL] = []
        private var _overrides: [String: (Int, Data)] = [:]

        var mode: Mode {
            get { lock.withLock { _mode } }
            set { lock.withLock { _mode = newValue } }
        }
        var requests: [URL] { lock.withLock { _requests } }
        func record(_ url: URL) { lock.withLock { _requests.append(url) } }
        /// Answer this path (and query) with this, instead of the fixture.
        func override(_ pathAndQuery: String, status: Int = 200, body: Data) {
            lock.withLock { _overrides[pathAndQuery] = (status, body) }
        }
        func overridden(_ key: String) -> (Int, Data)? { lock.withLock { _overrides[key] } }
    }

    static let http = SkillHashesTests.fixtures.appending(path: "http")
    struct Meta: Decodable { var owner: String; var repo: String; var commit: String; var branch: String }
    static let meta: Meta = try! JSONDecoder().decode(Meta.self, from: Data(contentsOf: http.appending(path: "meta.json")))
    static let skills = SkillHashesTests.fixtures.appending(path: "skills")

    static let endpoints = CatalogEndpoints(
        catalog: URL(string: "https://skills.test")!, web: URL(string: "https://github.test")!,
        api: URL(string: "https://api.github.test")!, raw: URL(string: "https://raw.github.test")!,
        codeload: URL(string: "https://codeload.github.test")!)

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: State] = [:]

    /// A session that reaches only this stub, and the state that stands behind it.
    static func make() -> (URLSession, State) {
        let id = UUID().uuidString
        let state = State()
        registryLock.withLock { registry[id] = state }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStub.self]
        config.httpAdditionalHeaders = ["X-Catalog-Stub": id]
        return (URLSession(configuration: config), state)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let id = request.value(forHTTPHeaderField: "X-Catalog-Stub"),
              let state = Self.registryLock.withLock({ Self.registry[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        state.record(url)
        let (status, headers, body) = Self.answer(url, state: state)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func file(_ name: String) -> Data { (try? Data(contentsOf: http.appending(path: name))) ?? Data() }

    private static func answer(_ url: URL, state: State) -> (Int, [String: String], Data) {
        let key = url.path + (url.query.map { "?\($0)" } ?? "")
        if let (status, body) = state.overridden(key) { return (status, [:], body) }
        if state.mode == .down { return (503, [:], Data("down".utf8)) }
        let host = url.host ?? ""
        let path = url.path
        let m = meta
        switch host {
        case "skills.test":
            if path == "/api/search" { return (200, [:], file("search-fixture.json")) }
            if path.hasPrefix("/api/download/\(m.owner)/\(m.repo)/") {
                let slug = url.lastPathComponent
                let data = file("download-\(slug).json")
                return data.isEmpty ? (404, [:], Data()) : (200, [:], data)
            }
        case "github.test":
            if path == "/\(m.owner)/\(m.repo).git/info/refs" { return (200, [:], file("info-refs.txt")) }
        case "api.github.test":
            if state.mode == .rateLimited {
                return (403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790000000"], file("rate-limited.json"))
            }
            if path == "/repos/\(m.owner)/\(m.repo)/git/trees/\(m.commit)" { return (200, [:], file("tree.json")) }
        case "raw.github.test":
            let prefix = "/\(m.owner)/\(m.repo)/\(m.commit)/"
            if path.hasPrefix(prefix), let data = try? Data(contentsOf: skills.deletingLastPathComponent()
                .appending(path: String(path.dropFirst(prefix.count)))) {
                return (200, [:], data)
            }
        case "codeload.github.test":
            if path == "/\(m.owner)/\(m.repo)/tar.gz/\(m.commit)" { return (200, [:], file("tarball.tar.gz")) }
        default: break
        }
        return (404, [:], Data("not found".utf8))
    }
}
#endif

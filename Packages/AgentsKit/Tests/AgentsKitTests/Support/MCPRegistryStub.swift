#if canImport(CryptoKit)
import Foundation
@testable import AgentsKit

/// Stand-in for registry.modelcontextprotocol.io (060, tasks T004). Answers from
/// `Fixtures/mcp/http`. Each test gets its own session id in a header so suites do not
/// cross-talk.
final class MCPRegistryStub: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case normal, down }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _mode: Mode = .normal
        private var _requests: [URL] = []

        var mode: Mode {
            get { lock.withLock { _mode } }
            set { lock.withLock { _mode = newValue } }
        }
        var requests: [URL] { lock.withLock { _requests } }
        func record(_ url: URL) { lock.withLock { _requests.append(url) } }
    }

    static let http = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/mcp/http")

    static let endpoints = MCPRegistryEndpoints(base: URL(string: "https://registry.mcp.test")!)

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: State] = [:]

    static func make() -> (URLSession, State) {
        let id = UUID().uuidString
        let state = State()
        registryLock.withLock { registry[id] = state }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPRegistryStub.self]
        config.httpAdditionalHeaders = ["X-MCP-Registry-Stub": id]
        return (URLSession(configuration: config), state)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url,
              let id = request.value(forHTTPHeaderField: "X-MCP-Registry-Stub"),
              let state = Self.registryLock.withLock({ Self.registry[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        state.record(url)
        let (status, body) = Self.answer(url, state: state)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func file(_ name: String) -> Data {
        (try? Data(contentsOf: http.appending(path: name))) ?? Data()
    }

    private static func answer(_ url: URL, state: State) -> (Int, Data) {
        if state.mode == .down { return (503, file("down.json")) }
        let path = url.path
        if path.hasSuffix("/servers") || path == "/v0/servers" || path == "/v0.1/servers" {
            return (200, file("search-github.json"))
        }
        if path.contains("/versions/latest") {
            let encoded = path
                .replacingOccurrences(of: "/v0/servers/", with: "")
                .replacingOccurrences(of: "/v0.1/servers/", with: "")
                .replacingOccurrences(of: "/versions/latest", with: "")
            let name = encoded.removingPercentEncoding ?? encoded
            let fileName = "detail-" + name.replacingOccurrences(of: "/", with: "__") + ".json"
            let data = file(fileName)
            return data.isEmpty ? (404, Data("{\"status\":404}".utf8)) : (200, data)
        }
        return (404, Data("{\"detail\":\"not found\"}".utf8))
    }
}
#endif

import Foundation

/// Where an MCP Registry is (060, research R1/R2/R10): the official one, GitHub's, or a
/// company's own (#687). Every one answers the same `/v0.1` API.
struct MCPRegistryEndpoints: Sendable, Equatable {
    var base: URL
    /// Sent as `Authorization: Bearer …`, for a registry that is not open.
    var token: String?

    init(base: URL, token: String? = nil) {
        self.base = base
        self.token = token
    }

    static let live = MCPRegistryEndpoints(base: URL(string: "https://registry.modelcontextprotocol.io")!)
    static let variable = "AGENTS_TEST_MCP_REGISTRY_URL"

    static func from(environment: [String: String]) -> MCPRegistryEndpoints {
        if let s = environment[variable], let url = URL(string: s) {
            return MCPRegistryEndpoints(base: url)
        }
        return .live
    }

    func searchURL(query: String) -> URL {
        var c = URLComponents(url: base.appending(path: "v0.1/servers"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "version", value: "latest"),
        ]
        return c.url!
    }

    /// `/v0.1/servers/{url-encoded-name}/versions/latest` — the slash in the name is `%2F`.
    func detailURL(name: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ".-_")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        return URL(string: "\(root)/v0.1/servers/\(encoded)/versions/latest")!
    }

    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("agents-app", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

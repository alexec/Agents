import AgentsKitCore
import Foundation

/// What a person's MCP server offers in views (#191): its tools that name a `ui://`
/// resource, who may call each, and the resources themselves (their addresses, not their
/// HTML). Made from the server's own `tools/list` and `resources/list` over the app's
/// connection, and kept on the host so a chat can tell a call has a view without
/// connecting again.
///
/// Kept at `<root>/mcp-views/<key>.json`, keyed by the server's entry (`key(for:)`), so a
/// changed entry is a new catalog. Never the entry itself, a secret, a URL or a header.
struct ServerViewCatalog: Codable, Equatable, Sendable {
    struct Tool: Codable, Equatable, Sendable {
        var name: String
        var resourceURI: String
        /// `_meta.ui.visibility`; both when the server says nothing.
        var visibility: [String]
        var readOnly: Bool

        var forModel: Bool { visibility.contains("model") }
        var forApp: Bool { visibility.contains("app") }
        /// Opening a pin calls it (#189): a view may call it, and it changes nothing.
        var feedsPins: Bool { forApp && readOnly }
    }

    struct Resource: Codable, Equatable, Sendable {
        var uri: String
        var name: String?
        var mimeType: String?
    }

    /// The server's name where it was read, for the log and the caption.
    var server: String
    var madeAt: Date
    /// Tools with a view, and the names of every tool the server has (bounded by the
    /// client's list limit), so a view's call of a tool without a view can be checked too.
    var tools: [Tool]
    var appTools: [String]
    var resources: [Resource]

    /// Kept for a day; a server's tools can change without its entry changing.
    static let freshFor: TimeInterval = 24 * 60 * 60

    func tool(_ name: String) -> Tool? { tools.first { $0.name == name } }

    /// The tool's view, read from either spelling the spec allows.
    static func resourceURI(of raw: JSONValue) -> String? {
        raw["_meta"]?["ui"]?["resourceUri"]?.stringValue ?? raw["_meta"]?["ui/resourceUri"]?.stringValue
    }

    static func make(server: String, tools: [MCPClient.Tool], resources: [JSONValue], now: Date) -> ServerViewCatalog {
        var withViews: [Tool] = []
        var appOnly: [String] = []
        for tool in tools {
            let visibility = tool.raw["_meta"]?["ui"]?["visibility"]?.arrayValue?.compactMap(\.stringValue)
            let seen = (visibility?.isEmpty ?? true) ? ["model", "app"] : visibility!
            if seen.contains("app") { appOnly.append(tool.name) }
            guard let uri = resourceURI(of: tool.raw), uri.hasPrefix("ui://") else { continue }
            withViews.append(Tool(name: tool.name, resourceURI: uri, visibility: seen,
                                  readOnly: tool.raw["annotations"]?["readOnlyHint"]?.boolValue == true))
        }
        let listed = resources.compactMap { raw -> Resource? in
            guard let uri = raw["uri"]?.stringValue, uri.hasPrefix("ui://") else { return nil }
            return Resource(uri: uri, name: raw["name"]?.stringValue ?? raw["title"]?.stringValue,
                            mimeType: raw["mimeType"]?.stringValue)
        }
        return ServerViewCatalog(server: server, madeAt: now, tools: withViews, appTools: appOnly, resources: listed)
    }

    /// The key a server's catalog is kept under: a digest of its entry as written, with
    /// any `${NAME}` still in it, so the file never says what a secret is.
    static func key(for unfilled: MCPServer) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(unfilled)) ?? Data(unfilled.name.utf8)
        return ContentDigest.sha256(data)
    }
}

/// The catalogs on disk, with the last few in memory.
struct ServerViewCatalogStore: Sendable {
    let folder: URL

    func url(_ key: String) -> URL { folder.appending(path: "\(key).json") }

    func load(_ key: String, now: Date) -> ServerViewCatalog? {
        guard let data = try? Data(contentsOf: url(key)),
              let catalog = try? StoreCoding.decoder.decode(ServerViewCatalog.self, from: data),
              now.timeIntervalSince(catalog.madeAt) < ServerViewCatalog.freshFor else { return nil }
        return catalog
    }

    func save(_ catalog: ServerViewCatalog, key: String) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try StoreCoding.encoder.encode(catalog).write(to: url(key), options: .atomic)
        } catch {
            DaemonLog.shared.write("mcp views: the catalog of \(catalog.server) could not be kept")
        }
    }
}

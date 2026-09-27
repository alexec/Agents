import Foundation

/// Which servers the app added from the registry (060, contracts/mcp-json.md). In the
/// daemon's root, so a scratch root has its own.
struct MCPCatalogSidecar: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        var registryName: String
        var version: String
        var run: String
        var addedAt: Date
    }

    var version = 1
    var servers: [String: Record] = [:]

    static func key(_ destination: DaemonAPI.SkillDestination, name: String) -> String {
        switch destination {
        case .personal: "personal/\(name)"
        case .project(let folder): "\(URL(filePath: folder).standardizedFileURL.path)/\(name)"
        }
    }

    static func load(from url: URL) -> MCPCatalogSidecar {
        guard let data = try? Data(contentsOf: url) else { return MCPCatalogSidecar() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(MCPCatalogSidecar.self, from: data)) ?? MCPCatalogSidecar()
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    mutating func upsert(destination: DaemonAPI.SkillDestination, name: String, record: Record) {
        servers[Self.key(destination, name: name)] = record
    }

    mutating func remove(destination: DaemonAPI.SkillDestination, name: String) {
        servers.removeValue(forKey: Self.key(destination, name: name))
    }

    func record(destination: DaemonAPI.SkillDestination, name: String) -> Record? {
        servers[Self.key(destination, name: name)]
    }
}

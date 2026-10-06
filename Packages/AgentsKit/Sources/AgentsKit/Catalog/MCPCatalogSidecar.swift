import Foundation
import AgentsKitCore

/// Which servers the app added, from the registry or by hand (060, #305, contracts/mcp-json.md). In the
/// daemon's root, so a scratch root has its own.
struct MCPCatalogSidecar: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        var registryName: String
        var version: String
        var run: String
        var addedAt: Date
        /// Added on the sheet by hand (#305); absent for a registry add.
        var byHand: Bool?
    }

    var version = 1
    var servers: [String: Record] = [:]

    static func key(_ destination: DaemonAPI.SkillDestination, name: String) -> String {
        switch destination {
        case .personal: "personal/\(name)"
        case .project(let folder): "\(URL(filePath: folder).standardizedFileURL.path)/\(name)"
        }
    }

    /// One that does not decode is set aside and this starts empty; one that does not
    /// read is held, so no save writes over it and the servers stay the app's (#205).
    static func load(from url: URL) -> MCPCatalogSidecar {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return StoreFile.load(MCPCatalogSidecar.self, at: url, empty: MCPCatalogSidecar(), decoder: d,
                              meaning: "servers added from the registry show as written by hand")
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try StoreFile.write(encoder.encode(self), to: url)
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

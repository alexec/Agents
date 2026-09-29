import Foundation
#if canImport(FoundationNetworking)
// URLSession lives here on Linux, where the server's agentsd is built.
import FoundationNetworking
#endif

/// Search and detail against the official MCP Registry (060, R1, R2).
struct MCPRegistry: Sendable {
    var session: URLSession
    var endpoints: MCPRegistryEndpoints

    init(session: URLSession = .shared, endpoints: MCPRegistryEndpoints = .from(environment: ProcessInfo.processInfo.environment)) {
        self.session = session
        self.endpoints = endpoints
    }

    func search(_ query: String) async throws -> [DaemonAPI.MCPCatalogResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let url = endpoints.searchURL(query: trimmed)
        let data: Data
        do {
            let (d, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DaemonAPI.MCPCatalogError.unreachable(host: url.host ?? endpoints.base.host ?? "registry")
            }
            data = d
        } catch let error as DaemonAPI.MCPCatalogError {
            throw error
        } catch {
            throw DaemonAPI.MCPCatalogError.unreachable(host: url.host ?? endpoints.base.host ?? "registry")
        }
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.servers.map { Self.result(from: $0.server) }
    }

    func detail(_ registryName: String) async throws -> RegistryServer {
        let url = endpoints.detailURL(name: registryName)
        let data: Data
        do {
            let (d, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DaemonAPI.MCPCatalogError.unreachable(host: url.host ?? endpoints.base.host ?? "registry")
            }
            data = d
        } catch let error as DaemonAPI.MCPCatalogError {
            throw error
        } catch {
            throw DaemonAPI.MCPCatalogError.unreachable(host: url.host ?? endpoints.base.host ?? "registry")
        }
        return try JSONDecoder().decode(DetailResponse.self, from: data).server
    }

    // MARK: Wire shapes from the registry

    struct SearchResponse: Decodable {
        var servers: [Item]
        struct Item: Decodable { var server: RegistryServer }
    }

    struct DetailResponse: Decodable {
        var server: RegistryServer
    }

    struct RegistryServer: Decodable, Sendable {
        var name: String
        var description: String?
        var title: String?
        var version: String?
        var repository: Repository?
        var packages: [Package]?
        var remotes: [Remote]?

        struct Repository: Decodable, Sendable {
            var url: String?
            var source: String?
        }

        struct Package: Decodable, Sendable {
            var registryType: String?
            var identifier: String?
            var version: String?
            var runtimeHint: String?
            var transport: Transport?
            var environmentVariables: [EnvVar]?
            var runtimeArguments: [Argument]?
            var packageArguments: [Argument]?

            struct Transport: Decodable, Sendable { var type: String? }
            struct EnvVar: Decodable, Sendable {
                var name: String?
                var description: String?
                var isRequired: Bool?
                var isSecret: Bool?
                var defaultValue: String?
            }
            struct Argument: Decodable, Sendable {
                var type: String?
                var name: String?
                var value: String?
                var description: String?
                var variables: [String: Variable]?
                struct Variable: Decodable, Sendable {
                    var format: String?
                    var isSecret: Bool?
                    var description: String?
                }
            }
        }

        struct Remote: Decodable, Sendable {
            var type: String?
            var url: String?
            var headers: [Header]?
            struct Header: Decodable, Sendable {
                var name: String?
                var description: String?
                var isRequired: Bool?
                var isSecret: Bool?
                var value: String?
            }
        }
    }

    static func result(from server: RegistryServer) -> DaemonAPI.MCPCatalogResult {
        let publisher = MCPPublisher.display(registryName: server.name)
        let runs = MCPEntryBuilder.availableRuns(server, onMac: MCPEntryBuilder.MacTools.detect())
        return DaemonAPI.MCPCatalogResult(
            id: server.name,
            title: server.title ?? MCPPublisher.shortName(registryName: server.name),
            description: server.description ?? "",
            version: server.version ?? "",
            publisher: publisher,
            known: publisher.known,
            runs: runs.available,
            remoteHost: runs.foreignRemoteHost)
    }
}

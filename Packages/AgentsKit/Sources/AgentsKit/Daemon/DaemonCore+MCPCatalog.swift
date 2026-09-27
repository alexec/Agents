#if canImport(CryptoKit)
import Foundation

/// Searching the MCP Registry and adding servers (060, contracts/mcp-methods.md).
extension DaemonCore {
    func useForMCPRegistry(session: URLSession, endpoints: MCPRegistryEndpoints) {
        mcpRegistrySession = session
        mcpRegistryEndpoints = endpoints
    }

    var mcpRegistry: MCPRegistry {
        MCPRegistry(session: mcpRegistrySession, endpoints: mcpRegistryEndpoints)
    }

    var mcpInstaller: MCPInstaller {
        MCPInstaller(sidecar: locations.root.appending(path: "catalog-mcp.json"))
    }

    func mcpSearchResults(_ query: String) async -> DaemonAPI.MCPSearchAnswer {
        do {
            let results = try await mcpRegistry.search(query)
            DaemonLog.shared.write("mcp: search \"\(query)\" → \(results.count)")
            return .init(results: results)
        } catch let error as DaemonAPI.MCPCatalogError {
            DaemonLog.shared.write("mcp: search \"\(query)\" failed: \(error)")
            return .init(results: [], error: error)
        } catch {
            return .init(results: [], error: .failed(String(describing: error)))
        }
    }

    func mcpPreview(_ request: DaemonAPI.MCPPreviewRequest) async -> DaemonAPI.MCPPreviewAnswer {
        if case .personal = request.destination, locations.personalHome == nil {
            return .init(error: .noPersonalHome)
        }
        do {
            let detail = try await mcpRegistry.detail(request.result.id)
            let runs = MCPEntryBuilder.availableRuns(detail, onMac: .detect())
            guard let chosen = request.run ?? runs.available.first else {
                throw DaemonAPI.MCPCatalogError.noRunnableWay
            }
            let secrets: SecretsEnv = {
                guard let home = locations.personalHome else { return SecretsEnv(lines: []) }
                return SecretsEnv.load(from: SecretsEnv.url(home: home))
            }()
            let built = try MCPEntryBuilder.build(detail, run: chosen, secretsAlreadySet: secrets.isSet)
            let state = try mcpInstaller.destinationState(nameHere: built.nameHere,
                                                          registryName: detail.name,
                                                          destination: request.destination,
                                                          personalHome: locations.personalHome)
            var problems: [DaemonAPI.MCPPreviewProblem] = []
            if case .unmanaged = state { problems.append(.nameTakenUnmanaged) }
            let previewID = UUID()
            let preview = DaemonAPI.MCPPreview(
                previewID: previewID, result: request.result, nameHere: built.nameHere,
                chosenRun: built.chosenRun, commandOrURL: built.commandOrURL, host: built.hostLabel,
                entry: built.entry.asJSONObject(), variables: built.variables, reach: [:],
                destinationState: state, problems: problems)
            let staged = MCPInstaller.Staged(preview: preview, entry: built.entry, transport: built.transport,
                                             registryName: detail.name,
                                             version: detail.version ?? request.result.version)
            await mcpPreviewStore.put(staged)
            DaemonLog.shared.write("mcp: preview \(detail.name) as \(built.nameHere) via \(chosen.rawValue)")
            return .init(preview: preview)
        } catch let error as DaemonAPI.MCPCatalogError {
            DaemonLog.shared.write("mcp: preview \(request.result.id) failed: \(error)")
            return .init(error: error)
        } catch {
            return .init(error: .failed(String(describing: error)))
        }
    }

    func mcpAdd(_ request: DaemonAPI.MCPAddRequest) async throws -> DaemonAPI.MCPAddAnswer {
        guard let staged = await mcpPreviewStore.take(request.previewID) else {
            throw Self.mcpRefusal(.previewExpired)
        }
        do {
            let server = try mcpInstaller.add(staged, destination: request.destination,
                                              personalHome: locations.personalHome,
                                              secrets: request.secrets, plain: request.plain,
                                              replace: request.replace)
            DaemonLog.shared.write("mcp: add \(server.name) from \(server.registryName) @ \(server.version)")
            return .init(server: server)
        } catch let error as DaemonAPI.MCPCatalogError {
            DaemonLog.shared.write("mcp: add refused: \(error)")
            throw Self.mcpRefusal(error)
        }
    }

    static func mcpRefusal(_ error: DaemonAPI.MCPCatalogError) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.mcpCatalogRefused, message: MCPCatalogWords.sentence(error),
                     data: try? JSONValue.encoding(error))
    }
}

public enum MCPCatalogWords {
    public static func sentence(_ error: DaemonAPI.MCPCatalogError) -> String {
        switch error {
        case .unreachable(let host): "Can't reach \(host)."
        case .noPersonalHome: "This copy of the app has no personal ~/.agents."
        case .unmanaged(let path): "A server you wrote is already at \(path), so it was left alone."
        case .mcpUnreadable(let path): "\(path) could not be read, so it was not written."
        case .missingSecret(let name): "\(name) is required."
        case .staleDigest: "That server has changed. Open it again."
        case .secretStillInUse(let name): "\(name) is still named by another server."
        case .previewExpired: "That preview has expired. Open the server again."
        case .noRunnableWay: "There is no way to run this server on this Mac."
        case .replaceMismatch: "The server there has changed. Open it again."
        case .notAProject(let path): "\(path) is not a project on this Mac."
        case .failed(let why): "It could not be added: \(why)."
        }
    }
}
#endif

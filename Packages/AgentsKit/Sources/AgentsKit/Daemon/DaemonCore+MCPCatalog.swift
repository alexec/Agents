#if canImport(CryptoKit)
import Foundation

/// Searching the MCP Registry and adding servers (060, contracts/mcp-methods.md).
extension DaemonCore {

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
        try requireMCPProject(request.destination)
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

    func mcpList(_ request: DaemonAPI.MCPListRequest) throws -> DaemonAPI.MCPListAnswer {
        try requireMCPProject(request.destination)
        let approvals = mcpApprovalStore.load()
        let listed = MCPProjectListing.list(destination: request.destination,
                                            personalHome: locations.personalHome,
                                            sidecar: MCPCatalogSidecar.load(from: mcpInstaller.sidecarURL),
                                            approvals: approvals)
        let kind = Self.mcpDestinationKind(request.destination)
        DaemonLog.shared.write("mcp: list \(kind) → \(listed.servers.count)")
        // Only a project's servers are approved; the person's own are not asked about.
        var approvalsProblem: String?
        if case .project = request.destination, approvals.unreadable {
            approvalsProblem = ApprovalFile.note(mcpApprovalStore.file)
        }
        return .init(servers: listed.servers, problem: listed.problem, approvalsProblem: approvalsProblem)
    }

    func mcpApprove(_ request: DaemonAPI.MCPApproveRequest) throws -> DaemonAPI.MCPListAnswer {
        guard case .project(let path) = request.destination else {
            throw Self.mcpRefusal(.failed("Only a project's server waits for approval."))
        }
        try requireMCPProject(request.destination)
        let folder = URL(filePath: path)
        let url = MCPJSONFile.projectURL(folder: folder)
        let entry: OrderedJSON
        do {
            guard let found = try MCPJSONFile.entry(named: request.name, at: url) else {
                throw Self.mcpRefusal(.staleDigest)
            }
            entry = found
        } catch let error as JSONRPCError {
            throw error
        } catch {
            throw Self.mcpRefusal(.mcpUnreadable(path: url.path))
        }
        var records = mcpApprovalStore.load()
        do {
            try records.approve(folder: folder, name: request.name, digest: request.digest, entry: entry)
            try mcpApprovalStore.save(records, replacing: true)
        } catch let error as DaemonAPI.MCPCatalogError {
            throw Self.mcpRefusal(error)
        }
        DaemonLog.shared.write("mcp: approve \(request.name) in project")
        return try mcpList(.init(destination: request.destination))
    }

    func mcpSetSecret(_ request: DaemonAPI.MCPSetSecretRequest) throws -> DaemonAPI.MCPSetSecretAnswer {
        do {
            try mcpInstaller.setSecret(name: request.name, value: request.value, personalHome: locations.personalHome)
        } catch let error as DaemonAPI.MCPCatalogError {
            DaemonLog.shared.write("mcp: set-secret refused \(request.name)")
            throw Self.mcpRefusal(error)
        } catch {
            DaemonLog.shared.write("mcp: set-secret refused \(request.name)")
            throw Self.mcpRefusal(.failed("secrets.env could not be written."))
        }
        DaemonLog.shared.write("mcp: set-secret \(request.name)")
        return .init(set: true)
    }

    func mcpRemove(_ request: DaemonAPI.MCPRemoveRequest) throws -> DaemonAPI.MCPRemoveAnswer {
        try requireMCPProject(request.destination)
        let extra = allProjects(includeArchived: true).map { MCPJSONFile.projectURL(folder: $0.folder) }
        let forget = request.forgetSecret?.isEmpty == false ? request.forgetSecret : nil
        do {
            try mcpInstaller.remove(request.name, destination: request.destination,
                                    personalHome: locations.personalHome, forgetSecret: forget, alsoScan: extra)
        } catch let error as DaemonAPI.MCPCatalogError {
            DaemonLog.shared.write("mcp: remove refused \(request.name)")
            throw Self.mcpRefusal(error)
        } catch {
            DaemonLog.shared.write("mcp: remove refused \(request.name)")
            throw Self.mcpRefusal(.failed("mcp.json could not be written."))
        }
        DaemonLog.shared.write("mcp: remove \(request.name)")
        return .init(ok: true)
    }

    /// A project destination has to be a project on this Mac. Personal is always fine.
    func requireMCPProject(_ destination: DaemonAPI.SkillDestination) throws {
        guard case .project(let path) = destination else { return }
        let folder = URL(filePath: path)
        var isDirectory: ObjCBool = false
        let known = Self.isProjectFolder(folder, records: projectRecords(),
                                         agentFolders: Set(agents.values.map(\.projectFolder)))
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue, known else {
            throw Self.mcpRefusal(.notAProject(path: path))
        }
    }

    private static func mcpDestinationKind(_ destination: DaemonAPI.SkillDestination) -> String {
        switch destination {
        case .personal: "personal"
        case .project: "project"
        }
    }

    static func mcpRefusal(_ error: DaemonAPI.MCPCatalogError) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.mcpCatalogRefused, message: MCPCatalogWords.sentence(error),
                     data: try? JSONValue.encoding(error))
    }
}
#endif

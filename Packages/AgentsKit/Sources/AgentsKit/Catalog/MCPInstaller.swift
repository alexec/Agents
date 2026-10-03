import Foundation

/// Add / replace a registry server into personal or project `mcp.json` (060, R5, R7).
struct MCPInstaller: Sendable {
    let sidecarURL: URL
    let approvalsURL: URL

    init(sidecar: URL, approvals: URL? = nil) {
        self.sidecarURL = sidecar
        self.approvalsURL = approvals ?? sidecar.deletingLastPathComponent().appending(path: "mcp-approvals.json")
    }

    struct Staged: Sendable {
        var preview: DaemonAPI.MCPPreview
        var entry: OrderedJSON
        var transport: MCPServer.Transport
        var registryName: String
        var version: String
    }

    func destinationState(nameHere: String, registryName: String,
                          destination: DaemonAPI.SkillDestination,
                          personalHome: URL?) throws -> DaemonAPI.MCPDestinationState {
        let url = try mcpURL(destination, personalHome: personalHome)
        let side = MCPCatalogSidecar.load(from: sidecarURL)
        if let existing = try MCPJSONFile.entry(named: nameHere, at: url) {
            _ = existing
            if let record = side.record(destination: destination, name: nameHere) {
                return record.registryName == registryName ? .managedSame : .managedOther(registryName: record.registryName)
            }
            return .unmanaged(path: url.path)
        }
        if let record = side.record(destination: destination, name: nameHere) {
            return record.registryName == registryName ? .managedSame : .managedOther(registryName: record.registryName)
        }
        return .free
    }

    func add(_ staged: Staged, destination: DaemonAPI.SkillDestination, personalHome: URL?,
             secrets: [String: String], plain: [String: String], replace: Bool) throws -> DaemonAPI.ManagedMCPServer {
        guard let home = personalHome else { throw DaemonAPI.MCPCatalogError.noPersonalHome }
        let url = try mcpURL(destination, personalHome: home)
        let state = try destinationState(nameHere: staged.preview.nameHere, registryName: staged.registryName,
                                         destination: destination, personalHome: home)
        switch state {
        case .unmanaged(let path): throw DaemonAPI.MCPCatalogError.unmanaged(path: path)
        case .managedSame, .managedOther:
            guard replace else { throw DaemonAPI.MCPCatalogError.replaceMismatch }
        case .free: break
        case .unavailable(let e): throw e
        }

        // Required secrets must be provided or already set.
        var env = SecretsEnv.load(from: SecretsEnv.url(home: home))
        for variable in staged.preview.variables where variable.kind == .secret && variable.required {
            if let value = secrets[variable.name], !value.isEmpty {
                env.set(variable.name, value: value)
            } else if env.value(of: variable.name) == nil {
                throw DaemonAPI.MCPCatalogError.missingSecret(name: variable.name)
            }
        }
        for (name, value) in secrets where !value.isEmpty {
            env.set(name, value: value)
        }
        try env.save(to: SecretsEnv.url(home: home))

        // Apply plain overrides onto env when present.
        var entry = staged.entry
        if !plain.isEmpty {
            var envObj = entry["env"] ?? .object([])
            for (k, v) in plain { envObj.set(k, .string(v)) }
            entry.set("env", envObj)
        }

        do {
            try MCPJSONFile.upsert(name: staged.preview.nameHere, entry: entry, at: url)
        } catch is MCPJSONFile.Problem {
            throw DaemonAPI.MCPCatalogError.mcpUnreadable(path: url.path)
        }

        var side = MCPCatalogSidecar.load(from: sidecarURL)
        let addedAt = Date()
        side.upsert(destination: destination, name: staged.preview.nameHere,
                    record: .init(registryName: staged.registryName, version: staged.version,
                                  run: staged.preview.chosenRun.rawValue, addedAt: addedAt))
        try side.save(to: sidecarURL)

        // A project server added from the sheet is approved as it is written (R6).
        if case .project(let path) = destination {
            var records = MCPApprovalStore(file: approvalsURL).load()
            records.recordAdded(folder: URL(filePath: path), name: staged.preview.nameHere, entry: entry)
            try MCPApprovalStore(file: approvalsURL).save(records, replacing: true)
        }

        return DaemonAPI.ManagedMCPServer(name: staged.preview.nameHere, registryName: staged.registryName,
                                          version: staged.version, run: staged.preview.chosenRun,
                                          addedAt: addedAt, destination: destination)
    }

    /// Write one name into the person's `secrets.env`. The value is not logged.
    func setSecret(name: String, value: String, personalHome: URL?) throws {
        guard let home = personalHome else { throw DaemonAPI.MCPCatalogError.noPersonalHome }
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            throw DaemonAPI.MCPCatalogError.failed("A secret's name is letters, digits and underscores.")
        }
        guard !value.isEmpty else { throw DaemonAPI.MCPCatalogError.failed("A secret needs a value.") }
        var env = SecretsEnv.load(from: SecretsEnv.url(home: home))
        env.set(name, value: value)
        try env.save(to: SecretsEnv.url(home: home))
    }

    /// Take a server the app added out of `mcp.json`. A hand-written entry is refused.
    /// `forgetSecret` is removed only when no other server, personal or project, still names it.
    func remove(_ name: String, destination: DaemonAPI.SkillDestination, personalHome: URL?,
                forgetSecret: String?, alsoScan: [URL] = []) throws {
        guard let home = personalHome else { throw DaemonAPI.MCPCatalogError.noPersonalHome }
        let url = try mcpURL(destination, personalHome: home)
        var side = MCPCatalogSidecar.load(from: sidecarURL)
        guard side.record(destination: destination, name: name) != nil else {
            throw DaemonAPI.MCPCatalogError.unmanaged(path: url.path)
        }
        if let secret = forgetSecret, !secret.isEmpty,
           secretIsReferenced(secret, excluding: name, destination: destination, personalHome: home, alsoScan: alsoScan) {
            throw DaemonAPI.MCPCatalogError.secretStillInUse(name: secret)
        }
        do {
            try MCPJSONFile.remove(name: name, at: url)
        } catch is MCPJSONFile.Problem {
            throw DaemonAPI.MCPCatalogError.mcpUnreadable(path: url.path)
        }
        side.remove(destination: destination, name: name)
        try side.save(to: sidecarURL)
        if case .project(let path) = destination {
            var records = MCPApprovalStore(file: approvalsURL).load()
            records.drop(folder: URL(filePath: path), name: name)
            try MCPApprovalStore(file: approvalsURL).save(records, replacing: true)
        }
        if let secret = forgetSecret, !secret.isEmpty {
            var env = SecretsEnv.load(from: SecretsEnv.url(home: home))
            env.remove(secret)
            try env.save(to: SecretsEnv.url(home: home))
        }
    }

    /// True when some server other than the one being removed still contains `${secret}`.
    private func secretIsReferenced(_ secret: String, excluding name: String,
                                    destination: DaemonAPI.SkillDestination, personalHome: URL,
                                    alsoScan: [URL]) -> Bool {
        let destinationURL = (try? mcpURL(destination, personalHome: personalHome)) ?? personalHome
        var urls = alsoScan
        if let personal = try? mcpURL(.personal, personalHome: personalHome) { urls.append(personal) }
        urls.append(destinationURL)
        let dropping = destinationURL.standardizedFileURL.path
        var seen = Set<String>()
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            guard case .success(let servers) = PersonalDotAgents.servers(at: url) else { continue }
            for server in servers {
                if path == dropping && server.name == name { continue }
                if SecretsEnv.referencedNames(in: server).contains(secret) { return true }
            }
        }
        return false
    }

    func mcpURL(_ destination: DaemonAPI.SkillDestination, personalHome: URL?) throws -> URL {
        switch destination {
        case .personal:
            guard let home = personalHome else { throw DaemonAPI.MCPCatalogError.noPersonalHome }
            return MCPJSONFile.personalURL(home: home)
        case .project(let folder):
            return MCPJSONFile.projectURL(folder: URL(filePath: folder))
        }
    }
}

/// Short-lived MCP previews, keyed by id (060).
actor MCPPreviewStore {
    private var items: [UUID: MCPInstaller.Staged] = [:]
    private var expiry: [UUID: Date] = [:]

    func put(_ staged: MCPInstaller.Staged) {
        items[staged.preview.previewID] = staged
        expiry[staged.preview.previewID] = Date().addingTimeInterval(30 * 60)
    }

    func get(_ id: UUID) -> MCPInstaller.Staged? {
        guard let exp = expiry[id], exp > Date() else {
            items.removeValue(forKey: id); expiry.removeValue(forKey: id); return nil
        }
        return items[id]
    }

    func take(_ id: UUID) -> MCPInstaller.Staged? {
        defer { items.removeValue(forKey: id); expiry.removeValue(forKey: id) }
        return get(id)
    }
}

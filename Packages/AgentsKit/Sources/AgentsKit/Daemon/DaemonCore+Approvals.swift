import AgentsKitCore
import Foundation

/// Everything in a project waiting for the person's approval, as one list (#773): the
/// guarded files and workflows (#502, #569), the project's MCP servers (060) and plugins
/// (S2), and the sessions asking to be archived (#584). It rides on the project's summary,
/// so every client hears it move with `project/changed`, and each client's Needs You draws
/// it as it is rather than gathering five kinds of state itself.
///
/// The summary is made on every streamed token, so what reads files is kept: the guarded
/// files and workflows already are, the MCP servers and plugins in `approvalKitCache`, and
/// the sessions asking come from the project's tally.
extension DaemonCore {
    /// The project's waiting items, or nil when nothing waits. `guarded` is the project's
    /// `guardedChanges`, when the caller has them.
    func approvals(in folder: URL, guarded: [GuardedChange]?) -> [Approval]? {
        var items = (guarded ?? []).map { approval(for: $0, in: folder) }
        items += approvalKit(in: folder)
        items += archiveApprovals(in: folder)
        return items.isEmpty ? nil : items
    }

    /// A guarded file's change, or a workflow's (#569), as an approval. Request changes
    /// only where an agent made it and is still there to be told (Alex, #773: not for a pull).
    func approval(for change: GuardedChange, in folder: URL) -> Approval {
        var actions: [Approval.Action] = [.approve, .deny]
        if change.askedIn != nil { actions.append(.requestChanges) }
        if let id = GuardedChange.workflowID(inPath: change.path) {
            let isNew = workflowStore.load().state(folder: folder, workflowID: id)?.approvedDigest == nil
            return Approval(kind: .workflow, key: id, title: workflow(id, in: folder)?.name ?? id,
                            digest: change.digest, line: Self.changeLine(change, isNew: isNew),
                            since: change.since == .distantPast ? nil : change.since,
                            actions: actions, agentID: change.askedIn)
        }
        return Approval(kind: .file, key: change.path, title: change.path, digest: change.digest,
                        line: Self.changeLine(change, isNew: false), since: change.since,
                        actions: actions, agentID: change.askedIn)
    }

    /// Who changed it, in the row's grey line.
    static func changeLine(_ change: GuardedChange, isNew: Bool) -> String {
        let by = change.changedBy.isEmpty ? nil : GuardedChange.names(change.changedBy)
        if change.digest == nil {
            return by.map { "Removed by \($0)" } ?? (change.byGit ? "Removed by the last pull" : "Removed outside the app")
        }
        if isNew { return by.map { "New, made by \($0)" } ?? (change.byGit ? "New with the last pull" : "New") }
        return by.map { "Changed by \($0)" } ?? (change.byGit ? "Changed with the last pull" : "Changed since you approved it")
    }

    /// The project's MCP servers and plugins waiting, and not denied as they are.
    func approvalKit(in folder: URL) -> [Approval] {
        if let kept = approvalKitCache[folder] { return kept }
        let made = mcpApprovals(in: folder) + pluginApprovals(in: folder)
        // Only a watched project hears its files move, so only its list is kept.
        if projectWatches[folder] != nil { approvalKitCache[folder] = made }
        return made
    }

    /// Forget the MCP servers and plugins listed for `folder`, and tell every client when
    /// that moved what waits.
    func approvalKitMoved(in folder: URL) {
        approvalKitCache[folder] = nil
        projectChanged(forAgentIn: folder)
    }

    private func mcpApprovals(in folder: URL) -> [Approval] {
        guard let root = try? MCPJSONFile.loadOrEmpty(at: MCPJSONFile.projectURL(folder: folder)),
              let pairs = root["mcpServers"]?.objectPairs, !pairs.isEmpty else { return [] }
        let records = mcpApprovalStore.load()
        return pairs.compactMap { name, entry -> Approval? in
            guard case .waiting(let digest, let isNew) = records.status(folder: folder, name: name, entry: entry),
                  records.denied?[MCPApprovals.key(folder: folder, name: name)] != digest else { return nil }
            return Approval(kind: .mcpServer, key: name, title: name, digest: digest,
                            line: isNew ? "New MCP server" : "Changed since you approved it", actions: [.approve, .deny])
        }
    }

    private func pluginApprovals(in folder: URL) -> [Approval] {
        let plugins = DotAgents.pluginFolders(for: folder)
        guard !plugins.isEmpty else { return [] }
        let records = pluginApprovalStore.load()
        return plugins.compactMap { plugin -> Approval? in
            guard let waiting = pluginAwaitingApproval(plugin, records: records),
                  records.denied?[Self.pluginKey(plugin)] != waiting.digest else { return nil }
            let carries = DotAgents.pluginCarries(plugin)
            var line = waiting.isNew ? "New plugin" : "Changed since you approved it"
            if !carries.isEmpty { line += ", with " + GuardedChange.names(carries) }
            return Approval(kind: .plugin, key: plugin.lastPathComponent, title: plugin.lastPathComponent,
                            digest: waiting.digest, line: line, actions: [.approve, .deny])
        }
    }

    /// The sessions here asking to be archived, oldest ask first.
    private func archiveApprovals(in folder: URL) -> [Approval] {
        guard let asking = agents.tallies[folder]?.asking, !asking.isEmpty else { return [] }
        return asking.compactMap { agents[$0] }
            .sorted { ($0.archiveRequest?.requestedAt ?? .distantPast) < ($1.archiveRequest?.requestedAt ?? .distantPast) }
            .map { agent in
                Approval(kind: .archive, key: agent.id.uuidString, title: agent.title ?? "Untitled", digest: nil,
                         line: "Asks to be archived", since: agent.archiveRequest?.requestedAt,
                         actions: [.approve, .deny], agentID: agent.id)
            }
    }

    // MARK: Reading

    /// What is being approved, before the choice: a file's lines against the approved
    /// copy, an MCP server's entry, a plugin's files.
    public func readApproval(_ request: ApprovalReadRequest) throws -> GuardedChangeReading {
        let folder = Project.standardize(request.folder)
        switch request.kind {
        case .workflow:
            return try readGuardedChange(.init(folder: folder, path: GuardedChange.workflowPath(request.key)))
        case .file:
            return try readGuardedChange(.init(folder: folder, path: request.key))
        case .mcpServer:
            let url = MCPJSONFile.projectURL(folder: folder)
            guard let entry = try? MCPJSONFile.entry(named: request.key, at: url) else {
                throw Self.notWaiting("\(request.key) is not in this project's .agents/mcp.json.")
            }
            return GuardedChangeReading(path: "\(MCPApprovals.relativeFile) ▸ \(request.key)",
                                        digest: MCPApprovals.digest(of: entry), approved: nil,
                                        current: entry.stringified())
        case .plugin:
            let plugin = try pluginFolder(request.key, in: folder)
            return GuardedChangeReading(path: "\(DotAgents.folder)/\(DotAgents.plugins)/\(request.key)",
                                        digest: DotAgents.pluginDigest(plugin), approved: nil,
                                        current: Self.pluginListing(plugin))
        case .archive:
            throw Self.notWaiting("An archive request has nothing to read: open the session.")
        }
    }

    /// A plugin's files, one a line, and its manifest: what a person approving it looks at.
    /// Bounded, as the diff is: a plugin carrying `node_modules` is not listed whole.
    static func pluginListing(_ plugin: URL) -> String {
        let root = plugin.resolvingSymlinksInPath()
        var lines: [String] = []
        let carries = DotAgents.pluginCarries(plugin)
        if !carries.isEmpty { lines.append("Brings \(GuardedChange.names(carries)).") }
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        var files: [String] = []
        while let next = enumerator?.nextObject() as? String, files.count < 200 {
            if !DotAgents.ignoredInDigest.contains((next as NSString).lastPathComponent) { files.append(next) }
        }
        lines.append("")
        lines += files.sorted()
        for manifest in [".claude-plugin/plugin.json", "plugin.json"] {
            guard let data = try? Data(contentsOf: root.appending(path: manifest)), data.count < 32_000 else { continue }
            lines += ["", "\(manifest):", String(decoding: data, as: UTF8.self)]
            break
        }
        return lines.joined(separator: "\n")
    }

    private func pluginFolder(_ name: String, in folder: URL) throws -> URL {
        guard let plugin = DotAgents.pluginFolders(for: folder).first(where: { $0.lastPathComponent == name }) else {
            throw Self.notWaiting("There is no plugin called \(name) in this project.")
        }
        return plugin
    }

    static func notWaiting(_ message: String) -> JSONRPCError {
        JSONRPCError(code: JSONRPCError.invalidParams, message: message)
    }

    // MARK: The person's

    /// Approve, Deny or Request changes, by the road each kind already has; then the
    /// project as it stands.
    public func answerApproval(_ answer: ApprovalAnswer) async throws -> DaemonAPI.ProjectSummary {
        let folder = Project.standardize(answer.folder)
        if answer.action == .requestChanges {
            try await requestChanges(answer, in: folder)
        } else {
            try await settle(answer, in: folder)
        }
        projectChanged(forAgentIn: folder)
        guard let summary = projectSummary(for: folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject, message: "\(folder.path) is not a project.")
        }
        return summary
    }

    private func settle(_ answer: ApprovalAnswer, in folder: URL) async throws {
        let approve = answer.action == .approve
        func digest() throws -> String {
            guard let digest = answer.digest else { throw Self.notWaiting("Say which version you were shown.") }
            return digest
        }
        switch answer.kind {
        case .workflow:
            let request = DaemonAPI.WorkflowApproveRequest(folder: folder, workflowID: answer.key, digest: try digest())
            _ = approve ? try approveWorkflow(request) : try denyWorkflow(request)
        case .file:
            let request = DaemonAPI.GuardedChangeRequest(folder: folder, path: answer.key, digest: answer.digest)
            _ = approve ? try keepGuardedChange(request) : try undoGuardedChange(request)
        case .mcpServer:
            if approve {
                #if canImport(CryptoKit)
                _ = try await mcpApprove(.init(destination: .project(folder: folder.path), name: answer.key, digest: try digest()))
                #else
                // The MCP catalogue, which approves a server, is Mac-only (#799).
                throw Self.mcpRefusal(.failed("Approve this server from a Mac."))
                #endif
            } else {
                try denyMCPServer(answer.key, digest: try digest(), in: folder)
                approvalKitMoved(in: folder)
            }
        case .plugin:
            let plugin = try pluginFolder(answer.key, in: folder)
            if approve {
                _ = try approvePlugin(.init(plugin: plugin, digest: try digest()))
            } else {
                try denyPlugin(plugin, digest: try digest(), in: folder)
                approvalKitMoved(in: folder)
            }
        case .archive:
            guard let id = UUID(uuidString: answer.key), agents[id]?.asksToArchive == true else {
                throw Self.notWaiting("That session is not asking to be archived any more.")
            }
            if approve { try await archive(id) } else { clearArchiveRequest(id) }
        }
    }

    /// Deny: the server stays off, as it was while it waited, and is not asked about again
    /// until its entry changes.
    func denyMCPServer(_ name: String, digest: String, in folder: URL) throws {
        let url = MCPJSONFile.projectURL(folder: folder)
        guard let entry = try? MCPJSONFile.entry(named: name, at: url), MCPApprovals.digest(of: entry) == digest else {
            throw Self.mcpRefusal(.staleDigest)
        }
        var records = mcpApprovalStore.load()
        records.denied = (records.denied ?? [:]).merging([MCPApprovals.key(folder: folder, name: name): digest]) { $1 }
        do {
            try mcpApprovalStore.save(records, replacing: true)
        } catch {
            throw Self.mcpRefusal(.failed("The denial could not be kept."))
        }
        DaemonLog.shared.write("mcp: deny \(name) in project")
    }

    /// Deny: the plugin stays out of every session, as it was while it waited, and is not
    /// asked about again until its folder changes.
    func denyPlugin(_ plugin: URL, digest: String, in folder: URL) throws {
        guard DotAgents.pluginDigest(plugin) == digest else {
            throw JSONRPCError(code: DaemonAPI.Failure.notChanged,
                               message: "\(plugin.lastPathComponent) changed after you looked at it, so it was not denied. Look again.")
        }
        var records = pluginApprovalStore.load()
        records.denied = (records.denied ?? [:]).merging([Self.pluginKey(plugin): digest]) { $1 }
        try keep("the plugin denial") { try pluginApprovalStore.save(records, replacing: true) }
        DaemonLog.shared.write("plugins: \(plugin.lastPathComponent) in \(folder.path) denied")
    }

    /// Request changes: the note goes to the agent that made the change, as the person's
    /// own message, and the change goes on waiting; the agent's next version asks again.
    private func requestChanges(_ answer: ApprovalAnswer, in folder: URL) async throws {
        let note = answer.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !note.isEmpty else { throw Self.notWaiting("Say what to change.") }
        let summary = projectSummary(for: folder)
        guard let item = summary?.approvals?.first(where: { $0.kind == answer.kind && $0.key == answer.key }),
              item.actions.contains(.requestChanges), let agentID = item.agentID else {
            throw Self.notWaiting("No agent made this change, so there is nobody to ask. Approve or deny it.")
        }
        let what = item.kind == .workflow ? GuardedChange.workflowPath(item.key) : item.key
        let text = "Before approving your change to \(what), I'd like changes:\n\n\(note)\n\n"
            + "It stays waiting for approval; your next version of it asks again."
        try await requireFolder(agentID)
        clearArchiveRequest(agentID)
        dropAfterTurnAsk(agentID)
        try await prompt(.init(agentID: agentID, text: text, from: .person))
        DaemonLog.shared.write("approvals: changes requested on \(item.kind.rawValue) in \(folder.path)")
    }
}

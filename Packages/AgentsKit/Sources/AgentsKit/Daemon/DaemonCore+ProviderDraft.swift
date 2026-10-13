import AgentsKitCore
import Foundation

/// The agent that writes a provider's tool map or commands (#858, research R1–R3).
///
/// The control plane starts it here, on the host on its own machine, with `purpose:
/// providerDraft`. It runs in a folder of its own under this host's root, with none of its
/// runtime's tools and only the app's writer tools, which this daemon relays to the control
/// plane on channel 0. It is in no list a client sees. When its draft ends it is archived,
/// and it is deleted after a week.
extension DaemonCore {
    /// Where every writer's folder is.
    var providerDraftsFolder: URL { locations.root.appendingPathComponent("provider-drafts", isDirectory: true) }

    /// How long an ended writer is kept, archived, before it is deleted (FR-009).
    static let writerKeptFor: TimeInterval = 7 * 24 * 3600

    /// Whether `folder` is a writer's: such a folder is never a project.
    func isProviderDraftFolder(_ folder: URL) -> Bool {
        let root = Project.standardize(providerDraftsFolder).path
        return Project.standardize(folder).path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// A writer's start, made safe: its own new folder, and nothing of a project's.
    func writerStart(_ request: DaemonAPI.StartRequest, _ purpose: AgentPurpose) throws -> DaemonAPI.StartRequest {
        guard ToolPolicyCatalog.writerMeta(for: request.runtimeID) != nil else {
            let name = RuntimeCatalog.runtime(id: request.runtimeID)?.name ?? request.runtimeID
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "\(name) can’t write a provider’s map here: its own tools can’t be turned off for one session.")
        }
        guard let id = purpose.providerDraft else { return request }
        let folder = providerDraftsFolder.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw JSONRPCError(code: JSONRPCError.internalError,
                               message: "Couldn’t make a folder for the writing agent: \(error.localizedDescription)")
        }
        var safe = DaemonAPI.StartRequest(runtimeID: request.runtimeID, cwd: folder, prompt: request.prompt,
                                          startOptions: request.startOptions, requestID: request.requestID,
                                          sandbox: request.sandbox, purpose: purpose)
        safe.attachments = []
        return safe
    }

    /// A writer's servers: the app's, granted the writer's tools, and no other (FR-010).
    func writerServers(runtimeID: String, token: String, capabilities: ACP.MCPCapabilities?) async throws -> [MCPServer] {
        guard capabilities?.http == true else {
            throw JSONRPCError(code: JSONRPCError.internalError,
                               message: Self.noHTTPRefusal(RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID))
        }
        return [try await appServer(token: token, movesItself: false, writer: true)]
    }

    /// A writer's `_meta`: the writer policy and the sandbox, without the project's plugins.
    func writerSessionMeta(runtimeID: String, sandbox: SandboxChoice) -> JSONValue? {
        Self.merging(ToolPolicyCatalog.writerMeta(for: runtimeID), LaunchSandbox.meta(runtimeID: runtimeID, choice: sandbox))
    }

    /// One of the writer's tools, relayed to the control plane with the caller's id, which
    /// the control plane checks against its draft's agent (FR-011).
    func providerDraftTool(_ request: DaemonAPI.ProviderDraftToolRequest) async throws -> String {
        guard let agentID = appTokens[request.token], let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That conversation is not open any more, so nothing was done.")
        }
        guard let draft = agent.purpose?.providerDraft else {
            throw JSONRPCError(code: DaemonAPI.Failure.notPermitted, message: "This tool is for the agent writing that provider's map.")
        }
        guard let askControl else {
            throw JSONRPCError(code: DaemonAPI.Failure.notSupported, message: "This host isn’t on a control plane any more.")
        }
        let call = DaemonAPI.HostProviderDraftCall(agentID: agentID, draft: draft, tool: request.tool, arguments: request.arguments)
        let answer = try await askControl(DaemonAPI.Method.hostProviderDraft, try JSONValue.encoding(call))
        return answer["note"]?.stringValue ?? "Done."
    }

    /// A writer's turn ended: the control plane is told, so a draft whose agent stopped
    /// without sending one ends too. Its folder goes; the agent is archived.
    func writerEnded(_ agentID: UUID, reason: EndedReason?) {
        guard let agent = agents[agentID], let draft = agent.purpose?.providerDraft else { return }
        let words = reason?.summary
        Task { [self] in
            if let askControl {
                let call = DaemonAPI.HostProviderDraftCall(
                    agentID: agentID, draft: draft, tool: "turn_ended",
                    arguments: words.map { ["reason": .string($0)] })
                _ = try? await askControl(DaemonAPI.Method.hostProviderDraft, try JSONValue.encoding(call))
            }
            try? FileManager.default.removeItem(at: agent.cwd)
            if agents[agentID]?.state != .archived { try? await archive(agentID, by: .itself) }
        }
    }

    /// After a restart: a writer the last daemon held has no draft any more, so it is
    /// archived, not picked up; one archived over a week ago is deleted.
    func settleWriters() async {
        for agent in agents.values where agent.purpose != nil {
            if agent.state != .archived {
                try? FileManager.default.removeItem(at: agent.cwd)
                try? await archive(agent.id, by: .itself)
            } else if let at = agent.archivedAt, now().timeIntervalSince(at) > Self.writerKeptFor {
                try? await delete(agent.id, because: .age)
            }
        }
    }
}

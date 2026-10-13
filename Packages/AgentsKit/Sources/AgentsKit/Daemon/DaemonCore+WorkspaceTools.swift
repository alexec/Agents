import AgentsKitCore
import Foundation

extension DaemonCore {
    /// How this host asks its control plane something on channel 0 (#691 US6). Set once the
    /// uplink exists; nil off a control plane.
    public func deliverControlAsks(by ask: @escaping @Sendable (String, JSONValue) async throws -> JSONValue) {
        askControl = ask
    }

    /// An agent's workspace tool (US6): relayed to the control plane, which answers it as a
    /// client's request. Making and deleting ask the person first, on the question card, and
    /// do nothing without a yes (FR-051).
    func workspaceTool(_ request: DaemonAPI.WorkspaceToolRequest) async throws -> String {
        guard let agentID = appTokens[request.token], let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That conversation is not open any more, so nothing was done.")
        }
        guard let askControl else {
            throw JSONRPCError(code: DaemonAPI.Failure.notSupported,
                               message: "This host isn’t on a control plane, so it has no workspaces.")
        }
        let runtime = RuntimeCatalog.runtime(id: agent.runtimeID)?.name ?? agent.runtimeID
        let who = agent.title.map { "\(runtime) (\($0))" } ?? runtime
        @Sendable func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            try await askControl(DaemonAPI.Method.hostWorkspaces,
                                 try JSONValue.encoding(DaemonAPI.HostWorkspaceCall(agent: who, method: method, params: params)))
        }
        func named(_ value: String?, _ what: String) throws -> String {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Nothing was done: say which \(what).")
            }
            return value
        }

        switch request.action {
        case .list:
            let listed = try await call(DaemonAPI.Method.workspacesForAgent, [:]).decode(DaemonAPI.AgentWorkspaces.self)
            return Self.workspacesNote(listed)
        case .start:
            let host = try named(request.host, "host")
            let row = try await call(DaemonAPI.Method.hostsStart, ["host": .string(host)])
            if row["state"]?.stringValue == "online" { return "\(host) is running already." }
            return """
                Starting \(host). It is up when it connects: wait for the server.online event \
                (with wait_for_event) before you start anything there.
                """
        case .stop:
            let host = try named(request.host, "host")
            var params: [String: JSONValue] = ["host": .string(host)]
            if request.confirmRunning == true { params["confirmRunning"] = true }
            _ = try await call(DaemonAPI.Method.hostsStop, .object(params))
            return "Stopping \(host)."
        case .make:
            let given = try named(request.provider, "provider")
            let name = try named(request.name, "name for the new workspace")
            // Checked before the card: the person is never asked about what can't be done (#855).
            let listed = try await call(DaemonAPI.Method.workspacesForAgent, [:]).decode(DaemonAPI.AgentWorkspaces.self)
            guard let found = Self.provider(given, in: listed) else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Nothing was made: \(Self.noProvider(given, in: listed))")
            }
            guard found.canMake else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Nothing was made: \(found.name) can’t make workspaces.")
            }
            if found.workspaces.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw JSONRPCError(code: JSONRPCError.invalidParams,
                                   message: "Nothing was made: \(found.name) has a workspace called \(name) already.")
            }
            let provider = found.name
            let choices = (request.options?.objectValue ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value.stringValue ?? "\($0.value)")" }.joined(separator: ", ")
            let question = "Make a new workspace, \(name), at \(provider)\(choices.isEmpty ? "" : " (\(choices))")?"
            guard try await personSaysYes(request.token, title: "\(who) wants to make a workspace", question: question,
                                          yes: "Make it") else {
                return "Nothing was made: the person said no, or didn’t answer."
            }
            var params: [String: JSONValue] = ["id": .string(found.id.rawValue), "name": .string(name)]
            if let options = request.options { params["options"] = options }
            let made = try await call(DaemonAPI.Method.providersCreate, .object(params)).decode(DaemonAPI.ProviderCreated.self)
            return made.joining
                ? "Made \(made.workspace.name). It joins as the host \(made.workspace.name) on its first boot: wait for server.online."
                : "Made \(made.workspace.name). It can’t install Agents on its first boot, so the person adds it from Settings ▸ Control plane ▸ Providers with Add as Host…."
        case .delete:
            let given = try named(request.host, "host")
            let listed = try await call(DaemonAPI.Method.workspacesForAgent, [:]).decode(DaemonAPI.AgentWorkspaces.self)
            let linked = listed.providers.lazy.compactMap { provider in
                provider.workspaces.first { $0.host?.caseInsensitiveCompare(given) == .orderedSame }.map { (provider, $0) }
            }.first
            guard let (provider, workspace) = linked, let host = workspace.host else {
                throw JSONRPCError(code: DaemonAPI.Failure.noSuchHost,
                                   message: "Nothing was deleted: no workspace runs a host called \(given). list_workspaces names the ones that do.")
            }
            guard provider.canDelete else {
                throw JSONRPCError(code: JSONRPCError.invalidParams,
                                   message: "Nothing was deleted: \(host) runs on \(provider.name), which can’t delete workspaces.")
            }
            guard try await personSaysYes(request.token, title: "\(who) wants to delete a workspace",
                                          question: "Delete the workspace \(host) runs on, with everything on its disk, and remove the host \(host) with its agents?",
                                          yes: "Delete it") else {
                return "Nothing was deleted: the person said no, or didn’t answer."
            }
            _ = try await call(DaemonAPI.Method.hostsDeleteWorkspace, ["host": .string(host)])
            return "Deleted the workspace \(host) ran on, and removed the host."
        }
    }

    /// The provider an agent named, by id or by name.
    static func provider(_ given: String, in listed: DaemonAPI.AgentWorkspaces) -> DaemonAPI.AgentWorkspaces.Provider? {
        listed.providers.first { $0.id.rawValue == given }
            ?? listed.providers.first { $0.name.caseInsensitiveCompare(given) == .orderedSame }
    }

    static func noProvider(_ given: String, in listed: DaemonAPI.AgentWorkspaces) -> String {
        listed.providers.isEmpty
            ? "this control plane has no workspace providers. The person adds them in Settings ▸ Control plane ▸ Providers."
            : "no provider is called \(given). There are \(listed.providers.map(\.name).joined(separator: ", "))."
    }

    /// One yes-or-no question on the agent's card; true only for the yes.
    private func personSaysYes(_ token: String, title: String, question: String, yes: String) async throws -> Bool {
        let note = try await askForm(DaemonAPI.AskFormRequest(token: token, title: title, questions: [
            .init(id: "go", prompt: question, options: [.init(id: "yes", label: yes), .init(id: "no", label: "Don’t")]),
        ]))
        return note.contains(": \(yes)")
    }

    /// `list_workspaces`, for an agent to read: each provider, its workspaces and their hosts,
    /// and what a new one takes.
    static func workspacesNote(_ listed: DaemonAPI.AgentWorkspaces) -> String {
        guard !listed.providers.isEmpty else {
            return "This control plane has no workspace providers. The person adds them in Settings ▸ Control plane ▸ Providers."
        }
        var lines: [String] = []
        for provider in listed.providers {
            var can = [String]()
            if provider.canMake { can.append("can make workspaces (make_workspace)") }
            if provider.canDelete { can.append("can delete them") }
            lines.append("\(provider.name) (provider \(provider.id.rawValue))\(can.isEmpty ? "" : ": " + can.joined(separator: ", "))")
            if provider.workspaces.isEmpty { lines.append("  no workspaces") }
            for workspace in provider.workspaces {
                let host = workspace.host.map { " — host \($0), \(workspace.hostState ?? "unknown")" } ?? " — not a host"
                lines.append("  - \(workspace.name): \(workspace.state)\(host)\(workspace.cost.map { ", \($0)" } ?? "")")
            }
            if provider.canMake, let options = provider.options,
               let data = try? JSONEncoder().encode(options), let text = String(data: data, encoding: .utf8) {
                lines.append("  New workspace options (JSON Schema): \(text)")
            }
        }
        lines.append("Start or stop one by its host's name. Making and deleting ask the person first.")
        return lines.joined(separator: "\n")
    }
}

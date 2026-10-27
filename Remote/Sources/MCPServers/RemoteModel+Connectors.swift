import AgentsKitCore
import Foundation

/// The person's connections (#1335) and a folder's Connectors set-up (#1336), on the host
/// that has the folder, as the window's AppModel+Connectors.
extension RemoteModel {
    func connectorSetup(_ folder: FolderKey, reading: DaemonAPI.ConnectorSetupReading = .cached) async
        -> Result<DaemonAPI.ConnectorSetup, RemoteConnectorProblem> {
        await connectorCall(folder.host) {
            try await $0.call(DaemonAPI.Method.connectorsSetup,
                              DaemonAPI.ConnectorSetupRequest(folder: folder.folder.path, reading: reading),
                              returning: DaemonAPI.ConnectorSetup.self)
        }
    }

    func skipConnectorSlot(_ folder: FolderKey, _ slot: DaemonAPI.ConnectorSlotKind, skipped: Bool) async
        -> Result<DaemonAPI.ConnectorSetup, RemoteConnectorProblem> {
        await connectorCall(folder.host) {
            try await $0.call(DaemonAPI.Method.connectorsSetupSkip,
                              DaemonAPI.ConnectorSkipRequest(folder: folder.folder.path, slot: slot, skipped: skipped),
                              returning: DaemonAPI.ConnectorSetup.self)
        }
    }

    func connections(on host: MachineRef = .mac) async -> Result<[DaemonAPI.Connection], RemoteConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsList, DaemonAPI.Empty(),
                              returning: DaemonAPI.ConnectionsList.self).connections
        }
    }

    func startSignIn(_ provider: DaemonAPI.ConnectionProvider, on host: MachineRef) async
        -> Result<DaemonAPI.ConnectionSignIn, RemoteConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignIn, DaemonAPI.ConnectionProviderRequest(provider: provider),
                              returning: DaemonAPI.ConnectionSignIn.self)
        }
    }

    func waitForSignIn(_ flow: UUID, on host: MachineRef) async -> Result<DaemonAPI.ConnectionSignIn, RemoteConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInWait, DaemonAPI.ConnectionSignInFlowRequest(flowID: flow),
                              returning: DaemonAPI.ConnectionSignIn.self)
        }
    }

    /// Gives the host the code and the state that the hand-back page gave back (Linear).
    func completeSignIn(_ request: DaemonAPI.ConnectionSignInCompleteRequest, on host: MachineRef) async
        -> Result<DaemonAPI.ConnectionSignIn, RemoteConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInComplete, request, returning: DaemonAPI.ConnectionSignIn.self)
        }
    }

    /// A personal access token (GitLab, #1630): the connection it made, or why it made none.
    func signInWithToken(_ provider: DaemonAPI.ConnectionProvider, url: String?, token: String, on host: MachineRef) async
        -> Result<DaemonAPI.Connection, RemoteConnectorProblem> {
        let answer = await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInToken,
                              DaemonAPI.ConnectionTokenRequest(provider: provider, url: url, token: token),
                              returning: DaemonAPI.ConnectionTokenAnswer.self)
        }
        switch answer {
        case .success(let a):
            if let connection = a.connection { return .success(connection) }
            return .failure(RemoteConnectorProblem(words: a.error ?? "GitLab did not take the token."))
        case .failure(let problem): return .failure(problem)
        }
    }

    /// One IMAP mailbox and its app password (Email, #1780): the connection it made, or why it
    /// made none. The host signs in once to check it, and keeps the password.
    func signInWithEmail(server: String, user: String, password: String, on host: MachineRef) async
        -> Result<DaemonAPI.Connection, RemoteConnectorProblem> {
        let answer = await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInEmail,
                              DaemonAPI.ConnectionEmailRequest(server: server, user: user, password: password),
                              returning: DaemonAPI.ConnectionTokenAnswer.self)
        }
        switch answer {
        case .success(let a):
            if let connection = a.connection { return .success(connection) }
            return .failure(RemoteConnectorProblem(words: a.error ?? ConnectorSetupWords.Email.failed))
        case .failure(let problem): return .failure(problem)
        }
    }

    func cancelSignIn(_ flow: UUID, on host: MachineRef) async {
        _ = await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInCancel, DaemonAPI.ConnectionSignInFlowRequest(flowID: flow),
                              returning: DaemonAPI.ConnectionSignIn.self)
        }
    }

    /// Nil when it went; else why not.
    func disconnect(_ provider: DaemonAPI.ConnectionProvider, on host: MachineRef = .mac) async -> String? {
        switch await connectorCall(host, {
            try await $0.call(DaemonAPI.Method.connectionsDisconnect, DaemonAPI.ConnectionProviderRequest(provider: provider),
                              returning: DaemonAPI.ConnectionDisconnectAnswer.self)
        }) {
        case .success(let a): return a.error
        case .failure(let problem): return problem.words
        }
    }

    /// Takes one connector out of its mcp.json (#2154), the person's own or a folder's, then
    /// reads the servers again. Its secrets stay. Nil when it went, else why not.
    func removeConnector(_ name: String, folder: FolderKey?) async -> RemoteConnectorProblem? {
        let destination: DaemonAPI.SkillDestination = folder.map { .folder(folder: $0.folder.path) } ?? .personal
        let answer = await connectorCall(folder?.host ?? .mac) {
            try await $0.call(DaemonAPI.Method.mcpRemove,
                              DaemonAPI.MCPRemoveRequest(destination: destination, name: name, forgetSecret: nil),
                              returning: DaemonAPI.MCPRemoveAnswer.self)
        }
        if case .failure(let problem) = answer { return problem }
        await checkMCPHealth(folder: folder)
        return nil
    }

    private func connectorCall<T: Sendable>(_ host: MachineRef, _ body: (DaemonClient) async throws -> T) async
        -> Result<T, RemoteConnectorProblem> {
        guard let target = hostClient(host) else {
            return .failure(RemoteConnectorProblem(words: "The Mac that has this folder can't be reached."))
        }
        do {
            return .success(try await body(target))
        } catch let rpc as JSONRPCError {
            return .failure(RemoteConnectorProblem(words: rpc.message))
        } catch {
            return .failure(RemoteConnectorProblem(words: error.localizedDescription))
        }
    }
}

struct RemoteConnectorProblem: Error, Equatable {
    var words: String
}

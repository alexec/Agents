import AgentsKitCore
import Foundation

/// The person's connections (#1335) and a folder's Connectors set-up (#1336), on the host
/// that has the folder. The answer or the error in words.
extension AppModel {
    func connectorSetup(_ folder: FolderKey, reading: DaemonAPI.ConnectorSetupReading = .cached) async
        -> Result<DaemonAPI.ConnectorSetup, ConnectorProblem> {
        await connectorCall(folder.host) {
            try await $0.call(DaemonAPI.Method.connectorsSetup,
                              DaemonAPI.ConnectorSetupRequest(folder: folder.folder.path, reading: reading),
                              returning: DaemonAPI.ConnectorSetup.self)
        }
    }

    func skipConnectorSlot(_ folder: FolderKey, _ slot: DaemonAPI.ConnectorSlotKind, skipped: Bool) async
        -> Result<DaemonAPI.ConnectorSetup, ConnectorProblem> {
        await connectorCall(folder.host) {
            try await $0.call(DaemonAPI.Method.connectorsSetupSkip,
                              DaemonAPI.ConnectorSkipRequest(folder: folder.folder.path, slot: slot, skipped: skipped),
                              returning: DaemonAPI.ConnectorSetup.self)
        }
    }

    func codespaces(_ folder: FolderKey, action: DaemonAPI.ConnectorCodespacesRequest.Action,
                    id: String? = nil, name: String? = nil) async
        -> Result<DaemonAPI.ConnectorCodespaces, ConnectorProblem> {
        await connectorCall(folder.host) {
            try await $0.call(DaemonAPI.Method.connectorsCodespaces,
                              DaemonAPI.ConnectorCodespacesRequest(folder: folder.folder.path, action: action, id: id, name: name),
                              returning: DaemonAPI.ConnectorCodespaces.self)
        }
    }

    func connections(on host: MachineRef = .mac) async -> Result<[DaemonAPI.Connection], ConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsList, DaemonAPI.Empty(),
                              returning: DaemonAPI.ConnectionsList.self).connections
        }
    }

    func startSignIn(_ provider: DaemonAPI.ConnectionProvider, on host: MachineRef) async
        -> Result<DaemonAPI.ConnectionSignIn, ConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignIn, DaemonAPI.ConnectionProviderRequest(provider: provider),
                              returning: DaemonAPI.ConnectionSignIn.self)
        }
    }

    /// One long poll: the sign-in once it ended, or still waiting after 25 seconds.
    func waitForSignIn(_ flow: UUID, on host: MachineRef) async -> Result<DaemonAPI.ConnectionSignIn, ConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInWait, DaemonAPI.ConnectionSignInFlowRequest(flowID: flow),
                              returning: DaemonAPI.ConnectionSignIn.self)
        }
    }

    /// Gives the host the code and the state that the hand-back page gave back (Linear).
    func completeSignIn(_ request: DaemonAPI.ConnectionSignInCompleteRequest, on host: MachineRef) async
        -> Result<DaemonAPI.ConnectionSignIn, ConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInComplete, request, returning: DaemonAPI.ConnectionSignIn.self)
        }
    }

    /// A personal access token (GitLab, #1630): the connection it made, or why it made none.
    func signInWithToken(_ provider: DaemonAPI.ConnectionProvider, url: String?, token: String, on host: MachineRef) async
        -> Result<DaemonAPI.Connection, ConnectorProblem> {
        let answer = await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInToken,
                              DaemonAPI.ConnectionTokenRequest(provider: provider, url: url, token: token),
                              returning: DaemonAPI.ConnectionTokenAnswer.self)
        }
        switch answer {
        case .success(let a):
            if let connection = a.connection { return .success(connection) }
            return .failure(ConnectorProblem(words: a.error ?? "GitLab did not take the token."))
        case .failure(let problem): return .failure(problem)
        }
    }

    /// One IMAP mailbox and its app password (Email, #1780): the connection it made, or why it
    /// made none. The host signs in once to check it, and keeps the password.
    func signInWithEmail(server: String, user: String, password: String, on host: MachineRef) async
        -> Result<DaemonAPI.Connection, ConnectorProblem> {
        let answer = await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInEmail,
                              DaemonAPI.ConnectionEmailRequest(server: server, user: user, password: password),
                              returning: DaemonAPI.ConnectionTokenAnswer.self)
        }
        switch answer {
        case .success(let a):
            if let connection = a.connection { return .success(connection) }
            return .failure(ConnectorProblem(words: a.error ?? ConnectorSetupWords.Email.failed))
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
        let answer = await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsDisconnect, DaemonAPI.ConnectionProviderRequest(provider: provider),
                              returning: DaemonAPI.ConnectionDisconnectAnswer.self)
        }
        switch answer {
        case .success(let a): return a.error
        case .failure(let problem): return problem.words
        }
    }

    private func connectorCall<T: Sendable>(_ host: MachineRef, _ body: (DaemonClient) async throws -> T) async
        -> Result<T, ConnectorProblem> {
        do {
            return .success(try await body(client(for: host)))
        } catch let rpc as JSONRPCError {
            return .failure(ConnectorProblem(words: rpc.message))
        } catch {
            return .failure(ConnectorProblem(words: error.localizedDescription))
        }
    }
}

struct ConnectorProblem: Error, Equatable {
    var words: String
}

import AgentsKitCore
import Foundation
import UIKit

/// The person's connections (#1335) and a project's Connectors set-up (#1336), on the host
/// that has the project, as the window's AppModel+Connectors.
extension RemoteModel {
    func connectorSetup(_ project: ProjectKey, reading: DaemonAPI.ConnectorSetupReading = .cached) async
        -> Result<DaemonAPI.ConnectorSetup, RemoteConnectorProblem> {
        await connectorCall(project.host) {
            try await $0.call(DaemonAPI.Method.connectorsSetup,
                              DaemonAPI.ConnectorSetupRequest(folder: project.folder.path, reading: reading),
                              returning: DaemonAPI.ConnectorSetup.self)
        }
    }

    func skipConnectorSlot(_ project: ProjectKey, _ slot: DaemonAPI.ConnectorSlotKind, skipped: Bool) async
        -> Result<DaemonAPI.ConnectorSetup, RemoteConnectorProblem> {
        await connectorCall(project.host) {
            try await $0.call(DaemonAPI.Method.connectorsSetupSkip,
                              DaemonAPI.ConnectorSkipRequest(folder: project.folder.path, slot: slot, skipped: skipped),
                              returning: DaemonAPI.ConnectorSetup.self)
        }
    }

    func connections(on host: HostID = .mac) async -> Result<[DaemonAPI.Connection], RemoteConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsList, DaemonAPI.Empty(),
                              returning: DaemonAPI.ConnectionsList.self).connections
        }
    }

    func startSignIn(_ provider: DaemonAPI.ConnectionProvider, on host: HostID) async
        -> Result<DaemonAPI.ConnectionSignIn, RemoteConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignIn, DaemonAPI.ConnectionProviderRequest(provider: provider),
                              returning: DaemonAPI.ConnectionSignIn.self)
        }
    }

    func waitForSignIn(_ flow: UUID, on host: HostID) async -> Result<DaemonAPI.ConnectionSignIn, RemoteConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInWait, DaemonAPI.ConnectionSignInFlowRequest(flowID: flow),
                              returning: DaemonAPI.ConnectionSignIn.self)
        }
    }

    /// Gives the host the code and the state that the hand-back page gave back (Linear).
    func completeSignIn(_ request: DaemonAPI.ConnectionSignInCompleteRequest, on host: HostID) async
        -> Result<DaemonAPI.ConnectionSignIn, RemoteConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInComplete, request, returning: DaemonAPI.ConnectionSignIn.self)
        }
    }

    /// A personal access token (GitLab, #1630): the connection it made, or why it made none.
    func signInWithToken(_ provider: DaemonAPI.ConnectionProvider, url: String?, token: String, on host: HostID) async
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
    func signInWithEmail(server: String, user: String, password: String, on host: HostID) async
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

    func cancelSignIn(_ flow: UUID, on host: HostID) async {
        _ = await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInCancel, DaemonAPI.ConnectionSignInFlowRequest(flowID: flow),
                              returning: DaemonAPI.ConnectionSignIn.self)
        }
    }

    /// Nil when it went; else why not.
    func disconnect(_ provider: DaemonAPI.ConnectionProvider, on host: HostID = .mac) async -> String? {
        switch await connectorCall(host, {
            try await $0.call(DaemonAPI.Method.connectionsDisconnect, DaemonAPI.ConnectionProviderRequest(provider: provider),
                              returning: DaemonAPI.ConnectionDisconnectAnswer.self)
        }) {
        case .success(let a): return a.error
        case .failure(let problem): return problem.words
        }
    }

    /// Takes one connector out of its mcp.json (#2154), the person's own or a project's, then
    /// reads the servers again. Its secrets stay. Nil when it went, else why not.
    func removeConnector(_ name: String, project: ProjectKey?) async -> RemoteConnectorProblem? {
        let destination: DaemonAPI.SkillDestination = project.map { .project(folder: $0.folder.path) } ?? .personal
        let answer = await connectorCall(project?.host ?? .mac) {
            try await $0.call(DaemonAPI.Method.mcpRemove,
                              DaemonAPI.MCPRemoveRequest(destination: destination, name: name, forgetSecret: nil),
                              returning: DaemonAPI.MCPRemoveAnswer.self)
        }
        if case .failure(let problem) = answer { return problem }
        await checkMCPHealth(project: project)
        return nil
    }

    private func connectorCall<T: Sendable>(_ host: HostID, _ body: (DaemonClient) async throws -> T) async
        -> Result<T, RemoteConnectorProblem> {
        guard let target = hostClient(host) else {
            return .failure(RemoteConnectorProblem(words: "The Mac that has this project can't be reached."))
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

/// Notify me (#2034): the project's servers' events that tell the person, and a notice opened.
extension RemoteModel {
    func notifyList(_ project: ProjectKey) async -> Result<DaemonAPI.NotifyList, RemoteConnectorProblem> {
        await connectorCall(project.host) {
            try await $0.call(DaemonAPI.Method.notifyList, DaemonAPI.NotifyListRequest(folder: project.folder.path),
                              returning: DaemonAPI.NotifyList.self)
        }
    }

    func notifySet(_ project: ProjectKey, server: String, event: String, on: Bool) async
        -> Result<DaemonAPI.NotifyList, RemoteConnectorProblem> {
        await connectorCall(project.host) {
            try await $0.call(DaemonAPI.Method.notifySet,
                              DaemonAPI.NotifySetRequest(folder: project.folder.path, server: server, event: event, on: on),
                              returning: DaemonAPI.NotifyList.self)
        }
    }

    /// A notice's banner opened: the item's page, from the notice the model holds, and the
    /// notice withdrawn everywhere.
    func openNotice(token: String) {
        let id = String(token.dropFirst("notice:".count))
        if let url = work.needs[.notice(id)]?.url.flatMap(URL.init(string:)) {
            UIApplication.shared.open(url)
        }
        Task {
            _ = await connectorCall(.mac) {
                try await $0.call(DaemonAPI.Method.noticeOpen, DaemonAPI.NoticeOpenRequest(id: id), returning: DaemonAPI.Empty.self)
            }
        }
    }
}

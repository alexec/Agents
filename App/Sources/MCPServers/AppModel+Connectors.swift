import AgentsKitCore
import Foundation
import Observation

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
        await connectionsList(on: host).map(\.connections)
    }

    /// The connections and the providers the host connects (#3824).
    func connectionsList(on host: MachineRef = .mac) async -> Result<DaemonAPI.ConnectionsList, ConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsList, DaemonAPI.Empty(),
                              returning: DaemonAPI.ConnectionsList.self)
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

    /// A personal access token (GitLab, #1630; GitHub, #3945; Jira, #3304, with the account's email on Jira
    /// Cloud): the connection it made, or why it made none.
    func signInWithToken(_ provider: DaemonAPI.ConnectionProvider, url: String?, user: String? = nil, token: String,
                         on host: MachineRef) async -> Result<DaemonAPI.Connection, ConnectorProblem> {
        let answer = await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsSignInToken,
                              DaemonAPI.ConnectionTokenRequest(provider: provider, url: url, user: user, token: token),
                              returning: DaemonAPI.ConnectionTokenAnswer.self)
        }
        switch answer {
        case .success(let a):
            if let connection = a.connection { return .success(connection) }
            return .failure(ConnectorProblem(words: a.error ?? "\(ConnectorSetupWords.name(provider)) did not take the token."))
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

/// The connections that ended on each host (#3407), and the projects whose forge uses one:
/// what turns a Connectors row red, as a connector that does not answer does. The host tells
/// no client when a provider refuses a renewal, so the sidebar reads them when the window
/// connects, every few minutes, and whenever Connectors reads them.
@MainActor
@Observable
final class EndedConnections {
    private(set) var byHost: [MachineRef: [DaemonAPI.Connection]] = [:]
    /// A project's Connectors folder, and the ended connection its slots use.
    private(set) var inFolders: [FolderKey: DaemonAPI.Connection] = [:]

    func on(_ host: MachineRef) -> [DaemonAPI.Connection] { byHost[host] ?? [] }

    func set(_ connections: [DaemonAPI.Connection], on host: MachineRef, now: Date = Date()) {
        let ended = ConnectorSetupWords.ended(connections, now: now)
        if byHost[host] != ended { byHost[host] = ended }
    }

    func set(_ connection: DaemonAPI.Connection?, in folder: FolderKey) {
        if inFolders[folder] != connection { inFolders[folder] = connection }
    }

    /// Only the folders the sidebar draws a project's Connectors row for.
    func keep(_ folders: Set<FolderKey>) {
        let gone = inFolders.keys.filter { !folders.contains($0) }
        for key in gone { inFolders[key] = nil }
    }
}

extension AppModel {
    /// Reads each host's connections, and, on a host where one ended, the stored set-up of each
    /// project's Connectors folder there: a slot stops working when its connection ends. A
    /// stored set-up is the host's last reading, so this asks no provider.
    func refreshEndedConnections(folders: [DaemonAPI.FolderSummary]) async {
        let hosts = Set(folders.map(\.host)).union([.mac])
            .filter { !hostUnreachable($0) && host($0, has: Capability.connections1) }
        for host in hosts {
            if case .success(let list) = await connections(on: host) { endedConnections.set(list, on: host) }
        }
        for folder in folders {
            guard !endedConnections.on(folder.host).isEmpty, self.host(folder.host, has: Capability.connectorsSetup1),
                  case .success(let setup) = await connectorSetup(folder.key, reading: .stored) else {
                endedConnections.set(nil, in: folder.key)
                continue
            }
            endedConnections.set(setup.connection.flatMap { ConnectorSetupWords.hasEnded($0) ? $0 : nil }, in: folder.key)
        }
        endedConnections.keep(Set(folders.map(\.key)))
    }
}

// MARK: The person's agents' bot (#3858)

extension AppModel {
    func agentsBot(on host: MachineRef = .mac) async -> Result<DaemonAPI.ConnectionBot, ConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsBot, DaemonAPI.Empty(), returning: DaemonAPI.ConnectionBot.self)
        }
    }

    func startAgentsBot(public isPublic: Bool, on host: MachineRef) async -> Result<DaemonAPI.ConnectionBotStart, ConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsBotStart, DaemonAPI.ConnectionBotStartRequest(public: isPublic),
                              returning: DaemonAPI.ConnectionBotStart.self)
        }
    }

    /// Gives the host the code GitHub sent back; the host takes the bot's key and keeps it.
    func completeAgentsBot(_ request: DaemonAPI.ConnectionBotCompleteRequest, on host: MachineRef) async
        -> Result<DaemonAPI.ConnectionBot, ConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsBotComplete, request, returning: DaemonAPI.ConnectionBot.self)
        }
    }

    func removeAgentsBot(on host: MachineRef) async -> Result<DaemonAPI.ConnectionBot, ConnectorProblem> {
        await connectorCall(host) {
            try await $0.call(DaemonAPI.Method.connectionsBotRemove, DaemonAPI.Empty(), returning: DaemonAPI.ConnectionBot.self)
        }
    }
}

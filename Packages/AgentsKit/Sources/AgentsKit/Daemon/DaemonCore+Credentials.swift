import AgentsKitCore
import Foundation

/// Which connection a request came in on, for the whole of the work it causes (043).
public enum RequestConnection {
    @TaskLocal public static var current: UUID?
}

/// What a runtime about to be started is lent, set around `SessionLauncher.launch` (043).
///
/// Empty for everything but a server's runtime that a window lent a credential for. When
/// set, every Claude credential variable the login environment had is taken out first, so
/// the one from Settings is the one used (D1).
public enum LentEnvironment {
    @TaskLocal public static var value: [String: String] = [:]

    public static func applied(to environment: [String: String]) -> [String: String] {
        guard !value.isEmpty else { return environment }
        var result = environment
        for name in CredentialKind.allVariables { result[name] = nil }
        result.merge(value) { _, lent in lent }
        return result
    }
}

/// A server's own Claude sign-in, as `claude login` or the person's profile left it.
enum ServerSignIn {
    /// `$HOME`, as the server's shell has it.
    static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }

    static func exists(runtimeID: String) -> Bool {
        guard runtimeID == "claude" else { return true }
        if FileManager.default.fileExists(atPath: "\(home)/.claude/.credentials.json") {
            return true
        }
        let env = LoginShellPath.environment()
        return CredentialKind.allVariables.contains { !(env[$0] ?? "").isEmpty }
    }
}

extension DaemonCore {
    /// The runtimes a window can lend for (043). Only Claude (D3).
    static let lendableRuntimes: Set<String> = ["claude"]

    func offerCredentials(_ offer: DaemonAPI.CredentialsOffer, connection: UUID?) {
        guard let connection, !exitsWhenIdle else { return }
        credentialOffers[connection] = offer
        if offer.ownSignInOnly { lentCredentials[connection] = nil }
    }

    func lendCredential(_ lend: DaemonAPI.CredentialsLend, connection: UUID?) throws {
        guard !exitsWhenIdle else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAServer,
                               message: "This Mac's own agents use this Mac's sign-in; nothing is lent to them.")
        }
        guard let connection, let offer = credentialOffers[connection], !offer.ownSignInOnly,
              offer.runtimes.contains(lend.runtime) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notOffered,
                               message: "This connection did not offer a credential for \(lend.runtime).")
        }
        guard let secret = Secret(lend.secret), secret.kind == lend.kind else {
            throw JSONRPCError(code: DaemonAPI.Failure.notOffered, message: "That is not a \(lend.runtime) credential.")
        }
        lentCredentials[connection, default: [:]][lend.runtime] = secret
    }

    /// For tests: a server with or without a sign-in of its own.
    func setHasOwnSignIn(_ check: @escaping @Sendable (String) -> Bool) {
        hasOwnSignIn = check
    }

    func forgetCredentials(_ connection: UUID) {
        credentialOffers[connection] = nil
        lentCredentials[connection] = nil
    }

    /// The environment to start `runtimeID` with, for the request under way (043, R6).
    ///
    /// Throws `credentialWanted`, having started nothing, when the connection offered a
    /// credential it has not lent yet, or when nothing was lent and the server has no
    /// sign-in of its own. The window lends and asks again with the same `sendID`.
    func launchEnvironment(for runtimeID: String) throws -> [String: String] {
        guard !exitsWhenIdle, Self.lendableRuntimes.contains(runtimeID) else { return [:] }
        let connection = RequestConnection.current
        let offer = connection.flatMap { credentialOffers[$0] }
        if offer?.ownSignInOnly == true { return [:] }
        if let connection, let secret = lentCredentials[connection]?[runtimeID] {
            return [secret.kind.environmentVariable: secret.reveal()]
        }
        if let offer, offer.runtimes.contains(runtimeID) {
            throw Self.wanted(runtimeID, offered: true)
        }
        // Nobody asked (a workflow firing), or the asker has nothing to lend: any window
        // that is connected and lent one, and otherwise the server's own sign-in.
        if connection == nil, let secret = lentCredentials.values.lazy.compactMap({ $0[runtimeID] }).first {
            return [secret.kind.environmentVariable: secret.reveal()]
        }
        guard hasOwnSignIn(runtimeID) else { throw Self.wanted(runtimeID, offered: false) }
        return [:]
    }

    /// A turn that failed because the provider refused the sign-in (043, R7). What the
    /// adapter says, as recorded in walk/spike.md: `-32603` with
    /// `data.errorKind == "authentication_failed"`, for a subscription token and an API key
    /// alike. Only on a server; the Mac's own sign-in is 037's business.
    func credentialRefusal(agentID: UUID, error: any Error) -> DaemonAPI.CredentialRefused? {
        guard !exitsWhenIdle, let agent = agents[agentID], Self.lendableRuntimes.contains(agent.runtimeID),
              let error = error as? JSONRPCError, Self.isAuthenticationFailure(error) else { return nil }
        let lent = lentCredentials.values.contains { $0[agent.runtimeID] != nil }
        return DaemonAPI.CredentialRefused(agentID: agentID, runtime: agent.runtimeID, lent: lent)
    }

    static func isAuthenticationFailure(_ error: JSONRPCError) -> Bool {
        if case .object(let data)? = error.data, data["errorKind"] == .string("authentication_failed") { return true }
        return error.message.contains("Failed to authenticate")
    }

    static func wanted(_ runtimeID: String, offered: Bool) -> JSONRPCError {
        let name = RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID
        return JSONRPCError(code: DaemonAPI.Failure.credentialWanted,
                            message: "\(name) on this server needs a token.",
                            data: (try? JSONValue.encoding(DaemonAPI.CredentialWanted(runtime: runtimeID, offered: offered))) ?? nil)
    }
}

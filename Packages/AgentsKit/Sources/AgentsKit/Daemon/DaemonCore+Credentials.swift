import AgentsKitCore
import Foundation

/// Which connection a request came in on, for the whole of the work it causes (043).
public enum RequestConnection {
    @TaskLocal public static var current: UUID?
}

/// What a runtime about to be started is lent, set around `SessionLauncher.launch` (043).
///
/// Empty for everything but a server's runtime that a window lent a credential for, or
/// Gemini on this Mac (046). When set, every variable that runtime might read a credential
/// from is taken out of the login environment first, so the one from Settings is the one
/// used (D1).
public enum LentEnvironment {
    @TaskLocal public static var value: [String: String] = [:]

    public static func applied(to environment: [String: String]) -> [String: String] {
        guard !value.isEmpty else { return environment }
        var result = environment
        let lentKinds = CredentialKind.allCases.filter { value.keys.contains($0.environmentVariable) }
        for name in lentKinds.flatMap(\.clearedVariables) { result[name] = nil }
        result.merge(value) { _, lent in lent }
        return result
    }
}

/// A server's own sign-in for a runtime a window can lend to: Claude's as `claude login` or
/// the person's profile left it (043), Gemini's key in the profile (046).
enum ServerSignIn {
    /// `$HOME`, as the server's shell has it.
    static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }

    static func exists(runtimeID: String) -> Bool {
        let variables = CredentialKind.variables(for: runtimeID)
        guard !variables.isEmpty else { return true }
        // Claude's own login leaves a file as well as, or instead of, a variable.
        if runtimeID == RuntimeCatalog.claude.id,
           FileManager.default.fileExists(atPath: "\(home)/.claude/.credentials.json") {
            return true
        }
        let env = LoginShellPath.environment()
        return variables.contains { !(env[$0] ?? "").isEmpty }
    }
}

extension DaemonCore {
    /// The runtimes a window can lend for: every one with a kind of credential Settings
    /// takes (043 Claude, 046 Gemini).
    static let lendableRuntimes: Set<String> = Set(CredentialKind.allCases.map(\.runtimeID))

    func offerCredentials(_ offer: DaemonAPI.CredentialsOffer, connection: UUID?) {
        // On this Mac an offer is the window saying what it still holds: a key taken out
        // of Settings stops being lent to agents started from now on.
        if exitsWhenIdle {
            for runtime in macLent.keys where !offer.runtimes.contains(runtime) { macLent[runtime] = nil }
            return
        }
        guard let connection else { return }
        credentialOffers[connection] = offer
        if offer.ownSignInOnly { lentCredentials[connection] = nil }
    }

    func lendCredential(_ lend: DaemonAPI.CredentialsLend, connection: UUID?) throws {
        // This Mac's own agents are lent only what has no other way in (046, D3).
        if exitsWhenIdle, let secret = Secret(lend.secret), secret.kind == lend.kind,
           secret.kind.isLentOnTheMac, secret.kind.runtimeID == lend.runtime {
            macLent[lend.runtime] = secret
            return
        }
        guard !exitsWhenIdle else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAServer,
                               message: "This Mac's own agents use this Mac's sign-in; nothing is lent to them.")
        }
        guard let connection, let offer = credentialOffers[connection], !offer.ownSignInOnly,
              offer.runtimes.contains(lend.runtime) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notOffered,
                               message: "This connection did not offer a credential for \(lend.runtime).")
        }
        guard let secret = Secret(lend.secret), secret.kind == lend.kind, secret.kind.runtimeID == lend.runtime else {
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
        if exitsWhenIdle { return try macLaunchEnvironment(for: runtimeID) }
        guard Self.lendableRuntimes.contains(runtimeID) else { return [:] }
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

    /// On this Mac (046, D3): the key a window lent, for a runtime that takes one here;
    /// else the person's own, if their environment has one; else ask the window, which
    /// lends it from Settings and sends the start again, or says where to add one.
    func macLaunchEnvironment(for runtimeID: String) throws -> [String: String] {
        let kinds = CredentialKind.kinds(for: runtimeID).filter(\.isLentOnTheMac)
        guard !kinds.isEmpty else { return [:] }
        if let secret = macLent[runtimeID] {
            return [secret.kind.environmentVariable: secret.reveal()]
        }
        let own = LoginShellPath.environment()
        if CredentialKind.variables(for: runtimeID).contains(where: { !(own[$0] ?? "").isEmpty }) { return [:] }
        let name = RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID
        throw JSONRPCError(code: DaemonAPI.Failure.credentialWanted,
                           message: "\(name) needs an API key. Add one in Settings ▸ Agents.",
                           data: (try? JSONValue.encoding(DaemonAPI.CredentialWanted(runtime: runtimeID, offered: false))) ?? nil)
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
        // Google's words for a Gemini key it does not know (046, contracts/credentials.md).
        return error.message.contains("Failed to authenticate") || error.message.contains("API key not valid")
            || error.message.contains("API_KEY_INVALID")
    }

    static func wanted(_ runtimeID: String, offered: Bool) -> JSONRPCError {
        let name = RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID
        return JSONRPCError(code: DaemonAPI.Failure.credentialWanted,
                            message: "\(name) on this server needs a \(CredentialKind.noun(for: runtimeID)).",
                            data: (try? JSONValue.encoding(DaemonAPI.CredentialWanted(runtime: runtimeID, offered: offered))) ?? nil)
    }
}

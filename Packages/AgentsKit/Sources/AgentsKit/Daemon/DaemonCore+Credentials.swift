import AgentsKitCore
import Foundation

/// Which connection a request came in on, for the whole of the work it causes (043).
public enum RequestConnection {
    @TaskLocal public static var current: UUID?
    /// What that connection is allowed to do. Defaults to control for in-process callers
    /// (tests, recover). A device must not auto-approve a workflow it rewrote (S6).
    @TaskLocal public static var role: ConnectionRole = .control
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
        // A relayed sign-in (047, 056) always names the CA it trusts; any other sign-in the
        // login environment holds for that runtime goes, so the relay's is the one used.
        let relays = ToolPolicyCatalog.builtIn.compactMap(\.relay).filter { value.keys.contains($0.certificateVariable) }
        for name in relays.flatMap(\.clearedVariables) { result[name] = nil }
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
        let relay = ToolPolicyCatalog.policy(for: runtimeID).relay
        let variables = Set(CredentialKind.variables(for: runtimeID) + (relay?.ownSignInVariables ?? []))
        guard !variables.isEmpty || relay?.ownSignInFile != nil else { return true }
        // Claude's own login leaves a file as well as, or instead of, a variable (056: the
        // policy says where).
        if let file = relay?.ownSignInFile, FileManager.default.fileExists(atPath: "\(home)/\(file)") {
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
        relayOffers[connection] = nil
    }

    // MARK: A sign-in relayed from the Mac (047)

    /// A window relays a runtime's sign-in from its Mac: open a gate for it on loopback
    /// (once per forwarded socket) and keep the offer for as long as the connection lasts.
    /// Only on a server; the Mac's own agents use the Mac's sign-in directly.
    func offerRelay(_ offer: DaemonAPI.RelayOffer, connection: UUID?) throws {
        guard !exitsWhenIdle else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAServer,
                               message: "This Mac's own agents use this Mac's sign-in; nothing is relayed to them.")
        }
        guard let connection else { return }
        if relayGates[offer.socketPath] == nil {
            relayGates[offer.socketPath] = try RelayGate(target: offer.socketPath)
        }
        relayOffers[connection, default: [:]][offer.runtime] = offer
        DaemonLog.shared.write("relay offered for \(offer.runtime) on port \(relayGates[offer.socketPath]?.port ?? 0)")
    }

    /// The offer relaying `runtimeID`'s sign-in: the asking connection's, else any other's.
    func relayOffer(for runtimeID: String) -> DaemonAPI.RelayOffer? {
        RequestConnection.current.flatMap { relayOffers[$0]?[runtimeID] }
            ?? relayOffers.values.lazy.compactMap { $0[runtimeID] }.first
    }

    /// The environment a runtime starts with when its sign-in is relayed, and the certificate
    /// to trust for it: for Codex a home of the app's own holding the stand-in and a config
    /// pointing its sign-in traffic at the gate; for Claude (056) variables only. Nil when no
    /// relay is offered for it.
    func relayEnvironment(for runtimeID: String) -> [String: String]? {
        guard let offer = relayOffer(for: runtimeID), let gate = relayGates[offer.socketPath],
              let relay = ToolPolicyCatalog.policy(for: runtimeID).relay else { return nil }
        let certificate = locations.root.appendingPathComponent("runtimes/\(runtimeID)-relay-ca.pem")
        do {
            try FileManager.default.createDirectory(at: certificate.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try offer.caCertificate.write(to: certificate, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certificate.path)
            switch relay.pointing {
            case .home(let homeVariable, let configFile, let signInFile, _):
                let home = locations.root.appendingPathComponent("runtimes/\(runtimeID)-relay-home", isDirectory: true)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try (relay.config(gatePort: gate.port) ?? "")
                    .write(to: home.appendingPathComponent(configFile), atomically: true, encoding: .utf8)
                try offer.standIn.write(to: home.appendingPathComponent(signInFile), atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                      ofItemAtPath: home.appendingPathComponent(signInFile).path)
                return [homeVariable: home.path, relay.certificateVariable: certificate.path]
            case .environment:
                var environment = relay.environment(gatePort: gate.port, standIn: offer.standIn)
                environment[relay.certificateVariable] = certificate.path
                return environment
            }
        } catch {
            DaemonLog.shared.write("could not write \(runtimeID)'s relay files: \(error)")
            return nil
        }
    }

    /// The environment to start `runtimeID` with, for the request under way (043, R6).
    ///
    /// Throws `credentialWanted`, having started nothing, when the connection offered a
    /// credential it has not lent yet, or when nothing was lent and the server has no
    /// sign-in of its own. The window lends and asks again with the same `sendID`.
    func launchEnvironment(for runtimeID: String) throws -> [String: String] {
        if exitsWhenIdle { return try macLaunchEnvironment(for: runtimeID) }
        // A sign-in relayed from the Mac comes first on a server (047): the person's own
        // plan, with nothing of theirs on the server. "Own sign-in only" still means own.
        if !(RequestConnection.current.flatMap { credentialOffers[$0] }?.ownSignInOnly ?? false),
           let relayed = relayEnvironment(for: runtimeID) {
            return relayed
        }
        // A runtime whose sign-in only the Mac relays (056: Claude; 047: Codex), with no relay
        // offered: the server's own sign-in, or say why the Mac's could not be used.
        if ToolPolicyCatalog.policy(for: runtimeID).relay != nil, !Self.lendableRuntimes.contains(runtimeID) {
            if RequestConnection.current.flatMap({ credentialOffers[$0] })?.ownSignInOnly == true { return [:] }
            if hasOwnSignIn(runtimeID) { return [:] }
            throw Self.signInWanted(runtimeID, reason: notRelayedReason(for: runtimeID))
        }
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
                           message: "\(name) needs an API key. Add one in Settings ▸ Agent Runtimes.",
                           data: (try? JSONValue.encoding(DaemonAPI.CredentialWanted(runtime: runtimeID, offered: false))) ?? nil)
    }

    /// A turn that failed because the provider refused the sign-in (043, R7). What the
    /// adapter says, as recorded in walk/spike.md: `-32603` with
    /// `data.errorKind == "authentication_failed"`, for a subscription token and an API key
    /// alike. Only on a server; the Mac's own sign-in is 037's business.
    func credentialRefusal(agentID: UUID, error: any Error) -> DaemonAPI.CredentialRefused? {
        guard !exitsWhenIdle, let agent = agents[agentID], let error = error as? JSONRPCError,
              Self.isAuthenticationFailure(error) else { return nil }
        // This Mac's own sign-in, relayed and refused even after the relay re-read it (056).
        if ToolPolicyCatalog.policy(for: agent.runtimeID).relay != nil, relayOffer(for: agent.runtimeID) != nil {
            return DaemonAPI.CredentialRefused(agentID: agentID, runtime: agent.runtimeID, lent: false, relayed: true)
        }
        guard Self.lendableRuntimes.contains(agent.runtimeID) else { return nil }
        let lent = lentCredentials.values.contains { $0[agent.runtimeID] != nil }
        return DaemonAPI.CredentialRefused(agentID: agentID, runtime: agent.runtimeID, lent: lent)
    }

    static func isAuthenticationFailure(_ error: JSONRPCError) -> Bool {
        if case .object(let data)? = error.data, data["errorKind"] == .string("authentication_failed") { return true }
        // Google's words for a Gemini key it does not know (046, contracts/credentials.md).
        return error.message.contains("Failed to authenticate") || error.message.contains("API key not valid")
            || error.message.contains("API_KEY_INVALID")
            // OpenCode's, for a provider key the provider refused (049 research R6).
            || error.message.contains("API key is invalid")
    }

    /// The provider a runtime says it is not signed in to, when it names one: OpenCode
    /// refuses a model of a provider nobody signed in to with `-32602` "model not found"
    /// and `data.providerId` (049 research R6), and `-32000` may carry the same field.
    static func unsignedProvider(_ error: JSONRPCError) -> String? {
        guard case .object(let data)? = error.data, let provider = data["providerId"]?.stringValue,
              error.isAuthRequired || (error.code == -32602 && error.message.contains("model not found")) else { return nil }
        return provider
    }

    /// Why the window could not relay `runtimeID`'s sign-in: what the asking connection
    /// said, else any window's, else not signed in.
    func notRelayedReason(for runtimeID: String) -> DaemonAPI.SignInWanted.Reason {
        RequestConnection.current.flatMap { credentialOffers[$0]?.notRelayed?[runtimeID] }
            ?? credentialOffers.values.lazy.compactMap { $0.notRelayed?[runtimeID] }.first
            ?? .notSignedIn
    }

    static func signInWanted(_ runtimeID: String, reason: DaemonAPI.SignInWanted.Reason) -> JSONRPCError {
        let name = RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID
        let message = switch reason {
        case .notSignedIn: "\(name) on this Mac isn’t signed in with a \(name) account."
        case .unreadable: "Agents couldn’t read \(name)’s sign-in on this Mac."
        }
        return JSONRPCError(code: DaemonAPI.Failure.signInWanted, message: message,
                            data: (try? JSONValue.encoding(DaemonAPI.SignInWanted(runtime: runtimeID, reason: reason))) ?? nil)
    }

    static func wanted(_ runtimeID: String, offered: Bool) -> JSONRPCError {
        let name = RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID
        return JSONRPCError(code: DaemonAPI.Failure.credentialWanted,
                            message: "\(name) on this server needs a \(CredentialKind.noun(for: runtimeID)).",
                            data: (try? JSONValue.encoding(DaemonAPI.CredentialWanted(runtime: runtimeID, offered: offered))) ?? nil)
    }
}

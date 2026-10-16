import AgentsKitCore
import Foundation

/// A Linux host's git, using the git access a Mac lends it through the control plane
/// (#1122). The host's agents and the daemon's own git are given `agentsd git-credential`
/// as git's credential helper, only while the host has no helper of its own: then nothing
/// git might `store` the lent credential with is ever told it. The helper asks this daemon
/// on its socket, which asks the control plane; the answer goes to git on a pipe and is
/// kept nowhere.
public enum GitLending {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var helper: String?

    /// Lend through `agentsd` at `executable`, reaching its daemon at `socket`.
    public static func enable(executable: URL, socket: URL) {
        let command = "!" + quoted(executable.path) + " git-credential " + quoted(socket.path)
        lock.withLock { helper = command }
    }

    public static func disable() { lock.withLock { helper = nil } }

    /// The helper git is given, or nil where nothing is lent.
    public static var command: String? { lock.withLock { helper } }

    /// `environment` with the helper laid over git's config (`GIT_CONFIG_COUNT`): the list
    /// of helpers emptied, then this one, after any `GIT_CONFIG_*` already there.
    public static func applied(to environment: [String: String]) -> [String: String] {
        guard let command else { return environment }
        var environment = environment
        let first = Int(environment["GIT_CONFIG_COUNT"] ?? "") ?? 0
        environment["GIT_CONFIG_KEY_\(first)"] = "credential.helper"
        environment["GIT_CONFIG_VALUE_\(first)"] = ""
        environment["GIT_CONFIG_KEY_\(first + 1)"] = "credential.helper"
        environment["GIT_CONFIG_VALUE_\(first + 1)"] = command
        environment["GIT_CONFIG_COUNT"] = String(first + 2)
        return environment
    }

    /// Whether the host's git has a credential helper of its own (system or global).
    public static func hostHasOwnHelper() async -> Bool {
        guard let git = GitProcess.executable() else { return false }
        let process = GitProcess(executable: git, arguments: ["config", "--get-all", "credential.helper"],
                                 in: FileManager.default.temporaryDirectory)
        guard let outcome = try? await process.run() else { return false }
        return outcome.succeeded && !outcome.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Mac's side: what its own git would use for `request`, read by `git credential fill`
    /// with nothing that can ask. Its keychain helper, `gh auth git-credential` and the like.
    public static func fill(_ request: DaemonAPI.GitCredentialRequest) async throws -> DaemonAPI.GitCredential {
        let process = try GitProcess(["credential", "fill"], in: FileManager.default.temporaryDirectory,
                                     environment: ["GCM_INTERACTIVE": "never", "GIT_ASKPASS": "", "SSH_ASKPASS": ""],
                                     input: Data(request.gitAttributes.utf8))
        process.deadline = .seconds(20)
        let outcome = try await process.run()
        guard outcome.succeeded, let credential = DaemonAPI.GitCredential(gitAttributes: outcome.output) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notPermitted, message: "This Mac has no git access to \(request.host).")
        }
        return credential
    }

    /// `'…'` for a shell, as git runs a helper that starts with `!`.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `agentsd git-credential <socket> <get|store|erase>`: git's credential helper. Only
    /// `get` does anything. What went wrong goes to stderr, which git shows; the exit is
    /// always 0, so git carries on to say it could not read a username.
    public static func runHelper(_ arguments: [String]) async -> Int32 {
        guard arguments.count >= 2, arguments[1] == "get" else { return 0 }
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        guard let request = DaemonAPI.GitCredentialRequest(gitAttributes: input) else { return 0 }
        let client = DaemonClient(link: PathSocketLink(path: arguments[0]))
        do {
            try await client.connect(startIfNeeded: false, timeout: .seconds(5))
            let credential = try await client.call(DaemonAPI.Method.gitCredential, request, returning: DaemonAPI.GitCredential.self)
            FileHandle.standardOutput.write(Data(credential.gitAttributes.utf8))
        } catch let error as JSONRPCError {
            FileHandle.standardError.write(Data("agentsd: \(error.message)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("agentsd: this host's agentsd is not answering.\n".utf8))
        }
        return 0
    }

    /// The daemon's socket by its path, as the helper is told it.
    struct PathSocketLink: DaemonLink {
        let path: String
        func transport() async throws -> any LineTransport { FDTransport(socket: try connectUnixSocket(path: path)) }
        func start() async throws { throw DaemonClient.ConnectError.couldNotConnect }
    }
}

import Foundation
import AgentsKitCore
import Synchronization

/// The environment a runtime, an agent's terminal or an MCP server is started with: only
/// what is named here out of the daemon's own (#727), not all of it.
///
/// Every variable a runtime is given reaches every tool it runs, so a cloud key or token in
/// the daemon's environment used to reach every agent. Now a variable goes through only when
/// it is one every program needs (below), one the runtime reads its own sign-in or settings
/// from (`RuntimeLaunch.passedVariables`, `CredentialKind`, the relay's own sign-in), or
/// one the person has said to pass through in `<root>/runtime-environment.json`.
///
/// Found on 2026-09-23, and still true: a daemon launched from inside a Claude Code
/// session — `open` passes the caller's environment through — carried that session's
/// `CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_MESSAGING_SOCKET` and the rest
/// into every runtime it spawned, and every resume failed once that session had gone. None
/// of them is on the list.
public enum RuntimeEnvironment {
    /// What any program expects to find: who and where it is, its language and terminal,
    /// the way out through a proxy and the CAs to trust there, the ssh agent for git, and
    /// where the usual toolchains live. A name ending in `*` is a prefix.
    public static let allowed: [String] = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TZ",
        "LANG", "LANGUAGE", "LC_*", "TERM", "COLORTERM", "XDG_*", "__CF_USER_TEXT_ENCODING",
        "EDITOR", "VISUAL", "PAGER",
        "SSH_AUTH_SOCK",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "no_proxy", "all_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
        "DEVELOPER_DIR", "JAVA_HOME", "GOPATH", "GOROOT", "CARGO_HOME", "RUSTUP_HOME", "PYENV_ROOT", "NVM_DIR",
        // The app's own: a scratch root, a test's switches. None is a secret.
        "AGENTS_*",
    ]

    /// Whether `name` is one of `patterns`, a pattern ending in `*` matching by prefix.
    public static func matches(_ name: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            pattern.hasSuffix("*") ? name.hasPrefix(pattern.dropLast()) : name == pattern
        }
    }

    /// The folder of the MCP servers Agents ships (#700), such as `github-mcp`: agentsd's
    /// own, Contents/Helpers in Agents Host and ~/.agents-server/bin on a Linux host. agentsd
    /// sets it as it starts; nil anywhere else, where it changes nothing.
    public static var shippedServersFolder: URL? {
        get { shippedServers.withLock { $0 } }
        set { shippedServers.withLock { $0 = newValue } }
    }

    private static let shippedServers = Mutex<URL?>(nil)

    /// What an MCP server the daemon starts runs with: a runtime's environment, with the
    /// shipped servers' folder first on PATH, so `.agents/mcp.json` names one by its bare
    /// name (`"command": "github-mcp"`) and the same entry, and its approval, holds on a Mac
    /// and on a Linux host. Ours come first, so a stale copy elsewhere on PATH never answers
    /// for them.
    public static func forMCPServers(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        withShippedServers(forRuntimes(environment), first: true)
    }

    /// `environment` with the shipped servers' folder on PATH: first, or last, where it
    /// shadows nothing the person has (a runtime's own, which starts the servers that are
    /// not hosted).
    public static func withShippedServers(_ environment: [String: String], first: Bool,
                                          folder: URL? = shippedServersFolder) -> [String: String] {
        guard let folder = folder?.path else { return environment }
        let rest = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0 != folder }
        var out = environment
        out["PATH"] = (first ? [folder] + rest : rest + [folder]).joined(separator: ":")
        return out
    }

    /// `environment` cut down to `allowed`, plus whatever `passing` names.
    public static func forRuntimes(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                                   passing: [String] = []) -> [String: String] {
        let patterns = allowed + passing
        return environment.filter { name, _ in matches(name, patterns) }
    }

    /// The same for one runtime: also what it reads its own sign-in and settings from.
    public static func forRuntime(_ runtimeID: String,
                                  _ environment: [String: String] = ProcessInfo.processInfo.environment,
                                  passing: [String] = []) -> [String: String] {
        forRuntimes(environment, passing: passed(by: runtimeID) + passing)
    }

    /// What a runtime reads beyond `allowed`.
    public static func passed(by runtimeID: String) -> [String] {
        RuntimeLaunchCatalog.launch(for: runtimeID).passedVariables
            + CredentialKind.variables(for: runtimeID)
            + (ToolPolicyCatalog.policy(for: runtimeID).relay?.ownSignInVariables ?? [])
    }
}

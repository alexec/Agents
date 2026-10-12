import Foundation
import Synchronization

/// The environment a runtime is started with: the daemon's own, minus anything that
/// would make the runtime believe it is somebody else's child.
///
/// Found on 2026-09-23. A daemon launched from inside a Claude Code session — `open`
/// passes the caller's environment through — carried that session's `CLAUDECODE`,
/// `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_MESSAGING_SOCKET` and the rest into every
/// runtime it spawned. While the session that owned the socket was alive nothing showed;
/// the morning after it had gone, every resume failed with "Could not resolve
/// authentication method" and the daemon recorded three agents as `processDied`. A
/// runtime the daemon starts is the daemon's, and must not inherit another agent's
/// idea of who its parent is.
public enum RuntimeEnvironment {
    /// Variables a Claude Code session sets for its children, and that no runtime of
    /// ours should see. Matched by prefix: the set grows with every release and none
    /// of it is ours.
    public static let parentSessionPrefixes = ["CLAUDECODE", "CLAUDE_"]

    public static func forRuntimes(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        environment.filter { key, _ in
            !parentSessionPrefixes.contains { key.hasPrefix($0) }
        }
    }

    /// The folder of the MCP servers Agents ships (#700), such as `ci-watcher`: agentsd's
    /// own, Contents/Helpers in Agents Host and ~/.agents-server/bin on a Linux host. agentsd
    /// sets it as it starts; nil anywhere else, where it changes nothing.
    public static var shippedServersFolder: URL? {
        get { shippedServers.withLock { $0 } }
        set { shippedServers.withLock { $0 = newValue } }
    }

    private static let shippedServers = Mutex<URL?>(nil)

    /// What an MCP server the daemon starts runs with: a runtime's environment, with the
    /// shipped servers' folder first on PATH, so `.agents/mcp.json` names one by its bare
    /// name (`"command": "ci-watcher"`) and the same entry, and its approval, holds on a Mac
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
}

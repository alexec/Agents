import Foundation

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
}

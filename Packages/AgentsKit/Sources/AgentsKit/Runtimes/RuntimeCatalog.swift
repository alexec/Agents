import Foundation

/// The runtimes this app knows how to start.
///
/// A recipe rather than a binary: Copilot and Grok are themselves, and Claude is an
/// npm package run through the user's Node, because `claude` has no ACP flag at all.
public enum RuntimeCatalog {
    public static let claude = Runtime(
        id: "claude",
        name: "Claude",
        executable: "npx",
        arguments: ["-y", "@agentclientprotocol/claude-agent-acp"])

    public static let grok = Runtime(
        id: "grok",
        name: "Grok",
        executable: "grok",
        arguments: ["agent", "stdio"])

    public static let copilot = Runtime(
        id: "copilot",
        name: "Copilot",
        executable: "copilot",
        arguments: ["--acp"])

    public static let builtIn: [Runtime] = [claude, grok, copilot]

    public static func runtime(id: String) -> Runtime? {
        builtIn.first { $0.id == id }
    }
}

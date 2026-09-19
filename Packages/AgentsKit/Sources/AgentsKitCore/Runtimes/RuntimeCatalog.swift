import Foundation

/// The runtimes this app knows how to start.
///
/// A recipe rather than a binary: Copilot, Grok and Cursor are themselves, and Claude is
/// an npm package run through the user's Node, because `claude` has no ACP flag at all.
///
/// Cursor is the reason a recipe holds a name as well as a command. Its own documentation
/// and its own sign-in text both call it `agent`, and `agent` on this Mac is Grok. What we
/// start is `cursor-agent`, and `acp` is a real subcommand that `cursor-agent --help` does
/// not list.
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

    public static let cursor = Runtime(
        id: "cursor",
        name: "Cursor",
        executable: "cursor-agent",
        arguments: ["acp"])

    public static let builtIn: [Runtime] = [claude, grok, copilot, cursor]

    public static func runtime(id: String) -> Runtime? {
        builtIn.first { $0.id == id }
    }
}

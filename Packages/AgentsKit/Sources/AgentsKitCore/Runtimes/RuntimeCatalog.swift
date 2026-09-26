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
///
/// Each also says how the app can install it when it is missing, and where the vendor's
/// own instructions are (048). The scripts are the vendors' own one-liners: Grok's lands
/// in `~/.grok/bin`, Cursor's and Copilot's in `~/.local/bin`, all of which
/// `LoginShellPath.fallbacks` already searches. Copilot's script rather than
/// `npm install -g`, because it needs no Node of the person's and no write access to
/// npm's global folder.
public enum RuntimeCatalog {
    public static let claude = Runtime(
        id: "claude",
        name: "Claude",
        executable: "npx",
        arguments: ["-y", "@agentclientprotocol/claude-agent-acp"],
        install: .toolset(runtimeID: "claude"),
        installPage: URL(string: "https://code.claude.com/docs/en/setup")!)

    public static let grok = Runtime(
        id: "grok",
        name: "Grok",
        executable: "grok",
        arguments: ["agent", "stdio"],
        install: .script(url: URL(string: "https://x.ai/cli/install.sh")!),
        installPage: URL(string: "https://x.ai/cli")!)

    public static let copilot = Runtime(
        id: "copilot",
        name: "Copilot",
        executable: "copilot",
        arguments: ["--acp"],
        install: .script(url: URL(string: "https://gh.io/copilot-install")!),
        installPage: URL(string: "https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli")!)

    public static let cursor = Runtime(
        id: "cursor",
        name: "Cursor",
        executable: "cursor-agent",
        arguments: ["acp"],
        install: .script(url: URL(string: "https://cursor.com/install")!),
        installPage: URL(string: "https://cursor.com/docs/cli/installation")!)

    public static let builtIn: [Runtime] = [claude, grok, copilot, cursor]

    public static func runtime(id: String) -> Runtime? {
        builtIn.first { $0.id == id }
    }
}

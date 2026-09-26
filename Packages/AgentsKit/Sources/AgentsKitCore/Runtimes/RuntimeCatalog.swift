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
///
/// Codex (047) is only ever the app's own toolset, never the person's `npx` as Claude
/// may be: its adapter pulls in `@openai/codex` by a caret range, so what `npx` fetched
/// would drift from the pinned lock, and the 330 MB fetch would happen silently inside a
/// first turn instead of on the set-up page. `codex-acp` is the shim's name in that
/// toolset, and nothing of that name on the PATH is ever run.
///
/// Gemini (046) is the one that is only ever the app's own copy: a pinned Gemini CLI on
/// a pinned Node, installed from the set-up page like Claude's toolset, and never a
/// `gemini` found on the PATH, because its ACP surface moves between releases. It speaks
/// ACP itself with `--acp`. The version is `App/Resources/toolsets/gemini/manifest.json`'s
/// (0.61.0 when this was written), and a test holds the two together.
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

    public static let codex = Runtime(
        id: "codex",
        name: "Codex",
        executable: "codex-acp",
        arguments: [],
        install: .toolset(runtimeID: "codex"),
        installPage: URL(string: "https://github.com/agentclientprotocol/codex-acp")!,
        usesAppCopyOnly: true)

    public static let gemini = Runtime(
        id: "gemini",
        name: "Gemini",
        executable: "gemini",
        // `--skip-trust`: Gemini starts no stdio MCP server in a folder it does not trust,
        // and the app's own tools are one. Trusted for this session only; nothing is
        // written to Gemini's `trustedFolders.json` (Alex, 2026-09-25; research R13).
        arguments: ["--acp", "--skip-trust"],
        install: .toolset(runtimeID: "gemini"),
        installPage: URL(string: "https://github.com/google-gemini/gemini-cli")!,
        usesAppCopyOnly: true)

    /// Google's Antigravity ACP server (049), not the `agy` CLI: the CLI has no ACP mode
    /// (google-antigravity/antigravity-cli#31), and Google publishes this server for ACP
    /// clients. A signed binary per platform, downloaded from Google by the set-up page and
    /// never shipped with the app; what it needs at launch is in `RuntimeLaunchCatalog`.
    public static let antigravity = Runtime(
        id: "antigravity",
        name: "Antigravity",
        executable: "agy_acp_server",
        arguments: [],
        install: .toolset(runtimeID: "antigravity"),
        installPage: URL(string: "https://antigravity.google/docs/ide/extensions")!,
        usesAppCopyOnly: true)

    public static let builtIn: [Runtime] = [claude, grok, copilot, cursor, codex, gemini, antigravity]

    public static func runtime(id: String) -> Runtime? {
        builtIn.first { $0.id == id }
    }
}

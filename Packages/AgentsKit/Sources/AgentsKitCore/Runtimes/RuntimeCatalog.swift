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
///
/// OpenCode (049) has Cursor's trap twice over. Two programs are called `opencode`: SST's,
/// now `anomalyco/opencode`, which speaks ACP as `opencode acp`, and the archived Go agent
/// of the same name (continued as Charm's Crush), still on Macs from its Homebrew tap, with no
/// `acp` at all. The vendor's installer also lands in `~/.opencode/bin`, which the login
/// shell never searches. So `opencode` is never looked up: only the app's own copy, the
/// pinned release program for this Mac from GitHub, is run, by its full path.
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
        // `--permission-mode default` forces Grok to ask despite a saved always-approve
        // mode in the person's own config (061). Process-scoped; the overlay cannot set it.
        arguments: ["--permission-mode", "default", "agent", "stdio"],
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

    /// OpenCode (049): SST's open-source agent, one program per platform from its GitHub
    /// releases, signed in to any of its providers or none (its Zen models are free). The
    /// app's settings for it are passed at launch; see `ToolPolicyCatalog.opencode`.
    public static let opencode = Runtime(
        id: "opencode",
        name: "OpenCode",
        executable: "opencode",
        arguments: ["acp"],
        install: .toolset(runtimeID: "opencode"),
        installPage: URL(string: "https://opencode.ai/docs/")!,
        usesAppCopyOnly: true)

    /// `builtIn[0]` is the default runtime, so a new one is appended.
    public static var builtIn: [Runtime] { [claude, grok, copilot, cursor, codex, gemini, antigravity, opencode] + extra }

    /// Runtimes a host adds for itself at start-up, before anything reads the catalog: the
    /// demo runtime of a review control plane (058, T092). Empty everywhere else.
    nonisolated(unsafe) public static var extra: [Runtime] = []

    /// The runtimes that pick their own conversation back up when started again in a
    /// different folder, which is what moving an agent into a worktree mid-work asks of
    /// them (053). Measured, not assumed, by `RuntimeMoveLiveTests` through each ACP
    /// adapter (research R3, 2026-09-26): Claude, Copilot, Cursor and Codex did; Grok
    /// answers "Path not found", because it files sessions by folder. Gemini and
    /// Antigravity are left out until measured. OpenCode loads its conversation in a new
    /// folder but keeps working in the old one (049, research R9), so it is left out too. A runtime not here is never offered the
    /// move tools, and cannot be moved, so nobody loses a conversation to a move.
    public static let carriesConversationAcrossFolders: Set<String> = ["claude", "copilot", "cursor", "codex"]

    /// Whether an agent on this runtime can be moved to another folder (053).
    public static func canMoveFolders(runtimeID: String) -> Bool {
        carriesConversationAcrossFolders.contains(runtimeID)
    }

    /// Why it cannot, in the words the page and the daemon use.
    public static func whyCannotMoveFolders(runtimeID: String) -> String {
        let name = runtime(id: runtimeID)?.name ?? runtimeID
        return "\(name) can't carry its conversation into another folder, so this agent stays where it is. Start a new one in a worktree instead."
    }

    public static func runtime(id: String) -> Runtime? {
        builtIn.first { $0.id == id }
    }
}

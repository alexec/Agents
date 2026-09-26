import Foundation

// The policies, one per runtime this app knows how to start.
//
// Total over `RuntimeCatalog.builtIn`, and a unit test says so. A runtime without an
// entry here is a bug rather than a runtime that keeps everything: the failure of a
// missing policy is silent — an agent quietly wider than every other agent — so the only
// safe place for it to show up is a red test.
//
// Every value below was measured on 2026-09-19 against the versions installed on this
// Mac. See `specs/015-runtime-tool-scoping/research.md` for what was sent and what came
// back, and `contracts/runtime-launch.md` for the exact wire shapes these turn into.
public enum ToolPolicyCatalog {
    /// The policy for a runtime, or words alone for one we have never scoped.
    ///
    /// An unknown runtime is scoped by words rather than silently by nothing: it carries
    /// no residue we can name, so it gets no residue line, but the briefing still tells
    /// it what this app owns. The check script is what turns it into a real entry.
    public static func policy(for runtimeID: String) -> ToolPolicy {
        builtIn.first { $0.runtimeID == runtimeID } ?? ToolPolicy(runtimeID: runtimeID, lever: .words)
    }

    /// Claude: a denial list, appended to the adapter's own.
    ///
    /// The adapter reads `_meta.claudeCode.options` into its user-provided options and
    /// merges `disallowedTools` with what it already denies, so this takes tools away
    /// without replacing the preset — which is why a deny list and not the `tools`
    /// allowlist beside it: an allowlist takes precedence over the preset, and a work
    /// tool added upstream next month would silently never arrive (Research R2).
    ///
    /// The two connectors are named whole rather than tool by tool. A document store and
    /// a drive are artefact stores either way round, the read half of one is only useful
    /// for writing to it, and eighty tool names in this file would be stale within the
    /// month (Research R3). The person's other connectors — Crustdata, Dice,
    /// ZipRecruiter — search the world and duplicate nothing of ours, so FR-010 leaves
    /// them alone.
    public static let claude = ToolPolicy(
        runtimeID: RuntimeCatalog.claude.id,
        removed: [
            RemovedTool(name: "Workflow", category: .standingArrangements),
            RemovedTool(name: "CronCreate", category: .standingArrangements),
            RemovedTool(name: "CronList", category: .standingArrangements),
            RemovedTool(name: "CronDelete", category: .standingArrangements),
            RemovedTool(name: "ScheduleWakeup", category: .standingArrangements),
            RemovedTool(name: "Monitor", category: .standingArrangements),
            RemovedTool(name: "RemoteTrigger", category: .standingArrangements),
            RemovedTool(name: "PushNotification", category: .escalation),
            RemovedTool(name: "Agent", category: .agents),
            RemovedTool(name: "ListAgents", category: .agents),
            RemovedTool(name: "SendMessage", category: .agents),
            RemovedTool(name: "TaskOutput", category: .agents),
            RemovedTool(name: "TaskStop", category: .agents),
            RemovedTool(name: "ReportFindings", category: .artefacts),
            RemovedTool(name: "DesignSync", category: .artefacts),
            RemovedTool(name: "mcp__claude_ai_Claude_Docs", category: .artefacts),
            RemovedTool(name: "mcp__claude_ai_Google_Drive", category: .artefacts),
            // Claude Code's own worktree tools move the session somewhere the app cannot
            // see: its Changes, its resume and its cleanup would all stay behind (053).
            RemovedTool(name: "EnterWorktree", category: .workingFolder),
            RemovedTool(name: "ExitWorktree", category: .workingFolder),
        ],
        kept: [
            KeptTool(name: "AskUserQuestion",
                     because: "It is the escalation path: the adapter raises it as a form elicitation, which the daemon holds and the phone can answer."),
        ],
        lever: .sessionMetaDenyList(path: ["claudeCode", "options", "disallowedTools"]),
        escalationTool: "AskUserQuestion")

    /// Grok: an allow list, as a profile, plus a config overlay on disk.
    ///
    /// The one runtime where we must say what to keep rather than what to remove, which
    /// is a cost worth naming: a work tool Grok adds next month will not reach an agent
    /// until this list grows, and the check script is how that gets noticed. It is the
    /// only lever that works — the documented `--disallowed-tools` flag does nothing over
    /// `agent stdio` (Research R6).
    ///
    /// `workflow` and `monitor` survive it, and that is not an oversight. Grok's own
    /// documentation says stock profiles inject their enabled optional tools *before*
    /// applying the allowlist, and nothing documented lets a client declare a profile
    /// curated. So they are residue, covered by words.
    public static let grok = ToolPolicy(
        runtimeID: RuntimeCatalog.grok.id,
        removed: [
            RemovedTool(name: "scheduler_create", category: .standingArrangements),
            RemovedTool(name: "scheduler_delete", category: .standingArrangements),
            RemovedTool(name: "scheduler_list", category: .standingArrangements),
            RemovedTool(name: "send_feedback", category: .escalation),
            RemovedTool(name: "spawn_subagent", category: .agents),
            RemovedTool(name: "kill_command_or_subagent", category: .agents),
            RemovedTool(name: "get_command_or_subagent_output", category: .agents),
        ],
        kept: [
            KeptTool(name: "ask_user_question",
                     because: "It is the escalation path: the daemon holds what it raises, and the phone can answer it."),
        ],
        residue: [
            ResidualTool(name: "workflow", category: .standingArrangements),
            ResidualTool(name: "monitor", category: .standingArrangements),
        ],
        lever: .sessionMetaAllowList(
            path: ["agentProfile", "tools"],
            keep: ["read_file", "list_dir", "grep", "search_replace", "write",
                   "run_terminal_command", "todo_write", "ask_user_question",
                   "web_search", "web_fetch", "open_page", "open_page_with_find"],
            extra: ["name": .string("agents-app"),
                    "description": .string("An agent hosted by the Agents app.")]),
        // Feature switches Grok reads only from a config file. `GROK_CONFIG` with the
        // same TOML inline was measured and ignored, so it has to be a path (R6), and
        // the path has to be ours: `~/.grok/config.toml` is the person's (FR-011).
        environmentFiles: [
            EnvironmentFile(
                name: "grok-overlay.toml",
                contents: """
                    # Written by the Agents app. Do not edit: rebuilt on every launch.
                    [features]
                    image_gen = false
                    video_gen = false

                    """,
                variable: "GROK_CONFIG_PATH"),
        ])
    // No `escalationTool`, and that is the measured answer rather than an omission.
    // `ask_user_question` is in the allowlist above and stays there, but it cannot reach
    // a client over `agent stdio`: Grok's own documentation files it under blocking TUI
    // cards, beside the permission prompt and the cancel-turn panel, and the ACP page
    // lists every update kind, extension method and agent-to-client notification without
    // one that carries a question. There is no channel, so there is no name worth telling
    // an agent — naming it only sent Grok hunting through the MCP catalogue for it.
    // Research R13.

    /// Copilot: three flags at launch.
    ///
    /// One of them does most of the work. `software-factory` is the person's own MCP
    /// server and a second implementation of this app's entire remit — escalations,
    /// artefacts, suggested prompts, agents and a task queue — so disabling the server
    /// removes a rival in all five categories at once. It keeps running; this app simply
    /// does not attach it to the agents it starts.
    ///
    /// `search_code_subagent` is residue because its real id is unknown. The model lists
    /// it as `functions.search_code_subagent`, and the flag rejected all nine spellings
    /// tried — `search_code_subagent`, `code_search_subagent`, `subagent`, `search_code`,
    /// `code_search`, `search_agent`, `search_codebase`, `codebase_search`,
    /// `semantic_search` — so nobody needs to re-run that experiment (Research R5). The
    /// general subagent tool, `task`, does exclude, so the way of spawning work is shut.
    public static let copilot = ToolPolicy(
        runtimeID: RuntimeCatalog.copilot.id,
        removed: [
            RemovedTool(name: "task", category: .agents),
            RemovedTool(name: "list_agents", category: .agents),
            RemovedTool(name: "read_agent", category: .agents),
            RemovedTool(name: "write_agent", category: .agents),
            RemovedTool(name: "session_store_sql", category: .artefacts),
        ],
        kept: [
            KeptTool(name: "its own question flow",
                     because: "It is the escalation path: what it raises becomes an elicitation the daemon holds."),
        ],
        residue: [
            ResidualTool(name: "search_code_subagent", category: .agents),
        ],
        lever: .launchArguments(flag: "--excluded-tools", repeatsFlag: false,
                                extra: ["--disable-mcp-server", "software-factory",
                                        "--disable-builtin-mcps"]))

    /// Cursor: there is no lever.
    ///
    /// Its permission vocabulary is `Shell`, `Read`, `Write`, `Delete` and `Mcp` — there
    /// is no rule kind that names a built-in tool, so `Task`, `CreateGoal` and
    /// `UpdateGoal` cannot be denied, let alone hidden. `CURSOR_CONFIG_DIR` would let the
    /// app supply a whole config directory, but that directory also holds the
    /// credentials, so pointing Cursor at ours would sign the person out of theirs
    /// (Research R7).
    ///
    /// So everything conflicting is residue, and the briefing is the whole of the
    /// defence. This is the runtime the residue line was written for.
    public static let cursor = ToolPolicy(
        runtimeID: RuntimeCatalog.cursor.id,
        residue: [
            ResidualTool(name: "Task", category: .agents),
            ResidualTool(name: "CreateGoal", category: .standingArrangements),
            ResidualTool(name: "UpdateGoal", category: .standingArrangements),
        ],
        lever: .words)

    /// Codex: feature switches in `CODEX_CONFIG` (047, research R5).
    ///
    /// Codex's tools come from features in its config rather than a fixed list, and its
    /// ACP adapter merges the JSON object in `CODEX_CONFIG` into every session's config for
    /// that process. So the lever is an environment variable, and nothing in `~/.codex` is
    /// touched: `CODEX_HOME` would move `auth.json` too and sign the person out, which is
    /// Cursor's reason for having no lever at all.
    ///
    /// Measured on 0.156.1 with a real ChatGPT turn (research R5): the switches do take tools
    /// away (turning the shell features off empties the shell tools), so `sleep_tool` takes
    /// `clock.sleep`, and `goals`, `memories`, `apps` and `in_app_local_automation` take
    /// Codex's own long-running goals, memory store, ChatGPT connectors and automations.
    /// The `collaboration.*` tools do not go: `multi_agent` and `multi_agent_v2` off leave
    /// all six listed, because the model's own catalog entry names its sub-agent tools. So
    /// they are residue, and the briefing names them, as Cursor's `Task` is named.
    /// `default_mode_request_user_input` is the opposite of the rest: it lets Codex's
    /// question tool, which the adapter raises as a form elicitation, ask outside plan mode.
    ///
    /// ChatGPT is offered before an API key when signing in (D1).
    public static let codex = ToolPolicy(
        runtimeID: RuntimeCatalog.codex.id,
        removed: [
            RemovedTool(name: "sleep", category: .standingArrangements),
            RemovedTool(name: "goals", category: .standingArrangements),
            RemovedTool(name: "automations", category: .standingArrangements),
            RemovedTool(name: "memories", category: .artefacts),
            RemovedTool(name: "apps", category: .artefacts),
        ],
        kept: [
            KeptTool(name: "request_user_input",
                     because: "It is the escalation path: the adapter raises it as a form elicitation, which the daemon holds and the phone can answer."),
        ],
        residue: [
            ResidualTool(name: "spawn_agent", category: .agents),
            ResidualTool(name: "send_message", category: .agents),
            ResidualTool(name: "followup_task", category: .agents),
            ResidualTool(name: "interrupt_agent", category: .agents),
            ResidualTool(name: "list_agents", category: .agents),
            ResidualTool(name: "wait_agent", category: .agents),
        ],
        lever: .environmentJSON(variable: "CODEX_CONFIG", value: .object([
            "features": .object([
                "sleep_tool": .bool(false),
                "goals": .bool(false),
                "in_app_local_automation": .bool(false),
                "memories": .bool(false),
                "apps": .bool(false),
                "multi_agent": .bool(false),
                "default_mode_request_user_input": .bool(true),
            ]),
        ])),
        escalationTool: "request_user_input",
        preferredAuthMethods: ["chat-gpt", "chat-gpt-device-code", "api-key"],
        // A server never offers ChatGPT: its sign-in is the Mac's, and never lent (FR-020).
        serverEnvironment: ["NO_BROWSER": "1"],
        // A lent key alone is not a sign-in (the adapter answers -32000), and the api-key
        // sign-in writes the key into Codex's home unless that home's config keeps sign-ins
        // in memory. Measured on agents-bare, research T008.
        lentKeyHome: LentKeyHome(whenLent: "CODEX_API_KEY", variable: "CODEX_HOME", folder: "codex-home",
                                 configFile: "config.toml",
                                 config: "cli_auth_credentials_store = \"ephemeral\"\n",
                                 environment: ["DEFAULT_AUTH_REQUEST": #"{"methodId":"api-key"}"#]),
        // The Mac's ChatGPT sign-in, relayed (research R12). Codex insists on HTTPS for it,
        // keeps only the origin for its model calls, and trusts CODEX_CA_CERTIFICATE.
        relay: SignInRelay(homeVariable: "CODEX_HOME", certificateVariable: "CODEX_CA_CERTIFICATE",
                           configFile: "config.toml", signInFile: "auth.json",
                           configTemplate: "chatgpt_base_url = \"https://127.0.0.1:{port}/backend-api/\"\n",
                           macSignIn: ".codex/auth.json", upstreamHost: "chatgpt.com"))

    /// Gemini: deny rules in a policy file, handed over with `--policy` (046).
    ///
    /// Measured against Gemini CLI 0.61.0 on 2026-09-25 (`specs/046-gemini-cli/research.md`
    /// R5). Two kinds of rival. `invoke_agent` starts Gemini's own subagents
    /// (`codebase_investigator`, `cli_help`, `generalist`); the six `tracker_*` tools keep a
    /// task queue of Gemini's own. `write_todos` stays, as Claude's to-do tool stays: a
    /// list inside the turn, not a standing arrangement.
    ///
    /// The file adds to the person's own policies rather than replacing them, which is why
    /// it and not `GEMINI_CLI_SYSTEM_SETTINGS_PATH`: system settings override the person's
    /// key by key, so their own `tools.exclude` and MCP servers would quietly go. Priority
    /// is 999, the top of the band Gemini allows (0–999), so a person's own `allow` for the
    /// same tool does not win inside the app's agents. A deny rule with no `argsPattern`
    /// takes the tool out of the model's list, not only refuses it: measured on a real
    /// turn, `invoke_agent` is listed without the file and gone with it (R13). So nothing
    /// here is residue.
    public static let gemini: ToolPolicy = {
        let removed = [
            RemovedTool(name: "invoke_agent", category: .agents),
            RemovedTool(name: "tracker_create_task", category: .standingArrangements),
            RemovedTool(name: "tracker_update_task", category: .standingArrangements),
            RemovedTool(name: "tracker_get_task", category: .standingArrangements),
            RemovedTool(name: "tracker_list_tasks", category: .standingArrangements),
            RemovedTool(name: "tracker_add_dependency", category: .standingArrangements),
            RemovedTool(name: "tracker_visualize", category: .standingArrangements),
        ]
        return ToolPolicy(
            runtimeID: RuntimeCatalog.gemini.id,
            removed: removed,
            lever: .file,
            environmentFiles: [
                EnvironmentFile(name: "gemini-policy.toml", contents: geminiPolicy(removing: removed),
                                argument: "--policy"),
            ],
            readsFilesItself: true,
            authMethodBeforeContinuing: "gemini-api-key")
    }()
    // No `escalationTool`, measured rather than omitted: in ACP mode Gemini takes its own
    // `ask_user` out of its tool list (`if (!interactive || isAcpMode)
    // extraExcludes.push(ASK_USER_TOOL_NAME)`), and its ACP code has no elicitation. A
    // question ends the turn and arrives as needs_answer, exactly as Grok's does. R6.

    /// Gemini's policy file: one deny rule per category, whose refusal says what to use.
    static func geminiPolicy(removing removed: [RemovedTool]) -> String {
        var text = "# Written by the Agents app. Do not edit: rebuilt on every launch.\n"
        for category in RemitCategory.allCases {
            let names = removed.filter { $0.category == category }.map(\.name)
            guard !names.isEmpty else { continue }
            text += "\n[[rule]]\n"
            text += "toolName = [\(names.map(tomlString).joined(separator: ", "))]\n"
            text += "decision = \"deny\"\n"
            text += "priority = 999\n"
            text += "denyMessage = \(tomlString(category.instead))\n"
        }
        return text
    }

    private static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Antigravity: a deny list in `_meta.agy.disabledTools` on `session/new`, and again on
    /// `session/load` and `session/resume`, which is exactly the lever the server documents
    /// for an ACP client ("Clients pass the filter under `_meta.agy`"). Measured against
    /// `agy_acp_server` 1.2.1 on 2026-09-25 (049 research R7).
    ///
    /// Its built-in tools are `list_directory`, `search_directory`, `find_file`,
    /// `view_file`, `create_file`, `edit_file`, `run_command`, `ask_question`,
    /// `start_subagent`, `generate_image`, `search_web`, `read_url_content` and `finish`.
    /// Only `start_subagent` duplicates the app. `ask_question` is the escalation tool: the
    /// server raises it as `session/request_permission` whose options are the answers, and
    /// allows it without a "Run ask_question?" prompt of its own.
    ///
    /// The `/plan` command writes "an implementation plan artifact" into the server's own
    /// folder under `GEMINI_HOME`. It is a command the person types, not a tool the model
    /// can call, so it is neither removed nor residue.
    ///
    /// A Google account, personal first, is the only way in (049 D3); the key methods the
    /// server also offers are hidden (`RuntimeLaunchCatalog.hiddenAuthMethods`).
    public static let antigravity = ToolPolicy(
        runtimeID: RuntimeCatalog.antigravity.id,
        removed: [
            RemovedTool(name: "start_subagent", category: .agents),
        ],
        kept: [
            KeptTool(name: "ask_question",
                     because: "It is the escalation path: the server raises it as a permission request whose options are the answers, which the daemon holds and the phone can answer."),
        ],
        lever: .sessionMetaDenyList(path: ["agy", "disabledTools"]),
        escalationTool: "ask_question",
        preferredAuthMethods: ["oauth-personal", "oauth-business"])

    /// In the same order as `RuntimeCatalog.builtIn`, so the two read side by side.
    public static let builtIn: [ToolPolicy] = [claude, grok, copilot, cursor, codex, gemini, antigravity]
}

import Foundation

// The four policies, one per runtime this app knows how to start.
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

    /// In the same order as `RuntimeCatalog.builtIn`, so the two read side by side.
    public static let builtIn: [ToolPolicy] = [claude, grok, copilot, cursor]
}

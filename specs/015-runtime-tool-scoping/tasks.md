---
description: "Task list for Our Tools, Not Theirs"
---

# Tasks: Our Tools, Not Theirs

**Input**: Design documents from `/specs/015-runtime-tool-scoping/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Included. Two of this feature's claims cannot be seen by looking at the app — that the mapping from runtime to policy is total, and that a tool is actually gone from a real runtime rather than merely asked about politely — and the second one is a claim about somebody else's software, which this repo holds with opt-in Live suites (`GrokServedToolsTests`, `SuggestedPromptLiveTests`). [contracts/tool-check.md](./contracts/tool-check.md) names every assertion.

**Organization**: Grouped by user story, in the priority order the spec sets. Each phase leaves the app working.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US5)

## Path Conventions

- `Packages/AgentsKit/Sources/AgentsKitCore/` — everything both platforms hold. No `Process`, no PTY.
- `Packages/AgentsKit/Sources/AgentsKit/` — the Mac's half: the daemon, the ACP and MCP serving, the stores.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration,Live}/` — Swift Testing.
- `scripts/` — the re-checks that ask a real runtime a real question.
- Nothing in `App/Sources/` or `Remote/Sources/`. An agent's tools are not something either view draws.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: The files everything else is written into.

- [ ] T001 Create `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/ToolPolicy.swift` with only a file-level doc comment in the house voice: what a policy is (which of a runtime's own tools an agent started by this app may keep), why it is a table and not a set of conditionals (the README's rule that no code asks which runtime it is talking to), and that everything in it was measured rather than read — pointing at `specs/015-runtime-tool-scoping/research.md`
- [ ] T002 [P] Create `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/ToolPolicyCatalog.swift` with a file-level doc comment saying it is total over `RuntimeCatalog.builtIn` and that a runtime without an entry is a bug rather than a runtime that keeps everything
- [ ] T003 [P] Create the empty test suites `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ToolPolicyTests.swift` (`@Suite("What an agent is allowed to keep")`) and `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ResidualToolTests.swift` (`@Suite("A tool we could not take away")`), each importing `Testing`, `@testable import AgentsKit` and `@testable import AgentsKitCore`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The vocabulary, the four policies, and the three shapes they turn into. Every user story reads these.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### The vocabulary

- [ ] T004 Add `public enum RemitCategory: String, Codable, Hashable, Sendable, CaseIterable` to `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/ToolPolicy.swift` with exactly five cases — `standingArrangements`, `escalation`, `agents`, `artefacts`, `suggestions` — and a doc comment saying every removal names exactly one, which is what makes the table arguable rather than a list of names somebody disliked
- [ ] T005 Add `public var instead: String` to `RemitCategory` in the same file: an exhaustive switch, no `default`, giving the sentence an agent is told when it reaches for that category — `standingArrangements` → "Use `manage_workflows` for anything that has to happen on its own."; `escalation` → "Ask me with your question or form tool; it reaches me wherever I am."; `agents` → "This app starts and stops agents; ask me rather than starting one."; `artefacts` → "Put it in the conversation or in a file in this project."; `suggestions` → "Use `suggest_next_prompts` at the end of the turn." Name the app tools through `AppTool`, never as string literals, following `Briefing`
- [ ] T006 [P] Add `public struct RemovedTool: Codable, Hashable, Sendable` (`name: String`, `category: RemitCategory`), `public struct KeptTool` (`name: String`, `because: String`) and `public struct ResidualTool` (`name: String`, `category: RemitCategory`) to `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/ToolPolicy.swift`. `ResidualTool` takes its `instead` sentence from its category rather than storing one, so the briefing line and the refusal cannot disagree. Comment `KeptTool.because` as existing to stop a later reader tidying the escalation tool into `removed`
- [ ] T007 Add `public struct EnvironmentFile: Codable, Hashable, Sendable` (`name: String`, `contents: String`, `variable: String`) to the same file, with a comment that nothing reads it back — it is an argument that happens to need a path (Research R11)

### The lever

- [ ] T008 Add `public enum Lever: Hashable, Sendable` to `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/ToolPolicy.swift` with exactly four cases — `sessionMetaDenyList(path: [String])`, `sessionMetaAllowList(path: [String], keep: [String], extra: [String: JSONValue])`, `launchArguments(flag: String, repeatsFlag: Bool, extra: [String])`, `words` — and a doc comment saying these are four ways of asking, not four runtimes, and that an allowlist carries its own `keep` because "everything except these" and "only these" are different claims (plan, Constitution Check)
- [ ] T009 Add `public struct ToolPolicy: Hashable, Sendable` to the same file with `runtimeID: String`, `removed: [RemovedTool]`, `kept: [KeptTool]`, `residue: [ResidualTool]`, `lever: Lever`, `environmentFiles: [EnvironmentFile]`, all defaulted to empty except `runtimeID` and `lever`
- [ ] T010 Add `public var sessionMeta: JSONValue?` to `ToolPolicy` in the same file: `nil` for `.launchArguments` and `.words`; for `.sessionMetaDenyList(path)` an object nesting `removed.map(\.name)` at `path`; for `.sessionMetaAllowList(path, keep, extra)` an object nesting `keep` at `path` with `extra` merged into the object one level above the final key. Build it by folding the path from the inside out, and comment the two shapes against [contracts/runtime-launch.md](./contracts/runtime-launch.md)
- [ ] T011 Add `public var launchArguments: [String]` to `ToolPolicy` in the same file: empty unless the lever is `.launchArguments(flag, repeatsFlag, extra)`, in which case `extra` followed by the removed names after `flag` — the flag repeated per name when `repeatsFlag`, otherwise once with every name after it
- [ ] T012 Add `public func residual(matching name: String) -> ResidualTool?` to `ToolPolicy` in the same file, matching on the end of the name and never whole, with the comment `AppService` already carries about prefixes: a runtime is free to prefix a tool's name and none of them changes what follows it

### The four policies

- [ ] T013 Add `public enum ToolPolicyCatalog` to `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/ToolPolicyCatalog.swift` with `public static func policy(for runtimeID: String) -> ToolPolicy` returning `builtIn.first { $0.runtimeID == runtimeID } ?? ToolPolicy(runtimeID: runtimeID, lever: .words)`, and a comment saying an unknown runtime is scoped by words alone rather than silently by nothing
- [ ] T014 Add `claude` to `ToolPolicyCatalog` with `lever: .sessionMetaDenyList(path: ["claudeCode", "options", "disallowedTools"])` and the seventeen removals from [data-model.md](./data-model.md): `Workflow`, `CronCreate`, `CronList`, `CronDelete`, `ScheduleWakeup`, `Monitor`, `RemoteTrigger` as `.standingArrangements`; `PushNotification` as `.escalation`; `Agent`, `ListAgents`, `SendMessage`, `TaskOutput`, `TaskStop` as `.agents`; `ReportFindings`, `DesignSync`, `mcp__claude_ai_Claude_Docs`, `mcp__claude_ai_Google_Drive` as `.artefacts`. Add `kept: [KeptTool(name: "AskUserQuestion", because: "It is the escalation path: the adapter raises it as a form elicitation, which the daemon holds and the phone can answer.")]` and no residue
- [ ] T015 [P] Add `grok` to `ToolPolicyCatalog` with `lever: .sessionMetaAllowList(path: ["agentProfile", "tools"], keep: ["read_file", "list_dir", "grep", "search_replace", "write", "run_terminal_command", "todo_write", "ask_user_question", "web_search", "web_fetch", "open_page", "open_page_with_find"], extra: ["name": "agents-app", "description": "An agent hosted by the Agents app."])`, the seven removals (`scheduler_create`, `scheduler_delete`, `scheduler_list` as `.standingArrangements`; `send_feedback` as `.escalation`; `spawn_subagent`, `kill_command_or_subagent`, `get_command_or_subagent_output` as `.agents`), `kept` naming `ask_user_question` as the escalation path, and `residue: [ResidualTool(name: "workflow", category: .standingArrangements), ResidualTool(name: "monitor", category: .standingArrangements)]` with a comment pointing at Research R6: the allowlist does not strip a stock profile's injected optional tools
- [ ] T016 [P] Add the `EnvironmentFile` for Grok to its policy in `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/ToolPolicyCatalog.swift`: `name: "grok-overlay.toml"`, `variable: "GROK_CONFIG_PATH"`, `contents` being the TOML in [contracts/runtime-launch.md](./contracts/runtime-launch.md) — a "written by the Agents app, rebuilt on every launch" header comment, then `[features] image_gen = false` and `video_gen = false`. Comment that inline `GROK_CONFIG` was measured and ignored (Research R6)
- [ ] T017 [P] Add `copilot` to `ToolPolicyCatalog` with `lever: .launchArguments(flag: "--excluded-tools", repeatsFlag: false, extra: ["--disable-mcp-server", "software-factory", "--disable-builtin-mcps"])`, removals `task`, `list_agents`, `read_agent`, `write_agent` as `.agents` and `session_store_sql` as `.artefacts`, and `residue: [ResidualTool(name: "search_code_subagent", category: .agents)]` with a comment listing the nine spellings the flag rejected (Research R5) so nobody re-runs that experiment
- [ ] T018 [P] Add `cursor` to `ToolPolicyCatalog` with `lever: .words`, no removals, and `residue: [ResidualTool(name: "Task", category: .agents), ResidualTool(name: "CreateGoal", category: .standingArrangements), ResidualTool(name: "UpdateGoal", category: .standingArrangements)]`, with a comment giving the reason from Research R7: Cursor's permission vocabulary has no rule kind that names a built-in tool, and its config directory holds the credentials
- [ ] T019 Add `public static let builtIn: [ToolPolicy] = [claude, grok, copilot, cursor]` to `ToolPolicyCatalog`, in the same order as `RuntimeCatalog.builtIn`

### Held by tests

- [ ] T020 [P] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ToolPolicyTests.swift`: every runtime in `RuntimeCatalog.builtIn` has a policy in `ToolPolicyCatalog.builtIn`, and every policy names a runtime that exists. Follow `AgentGroupTests` — the point is that a new runtime cannot arrive unscoped by accident
- [ ] T021 [P] Add to `ToolPolicyTests`: no tool name appears in more than one of `removed`, `kept` and `residue` within a policy; no `removed` or `residue` entry has an empty name; every `RemitCategory` case has a non-empty `instead` that names an app tool where one exists
- [ ] T022 [P] Add to `ToolPolicyTests`: the three wire shapes, checked against [contracts/runtime-launch.md](./contracts/runtime-launch.md) — Claude's `sessionMeta` is `_meta.claudeCode.options.disallowedTools` holding exactly its seventeen names; Grok's is `_meta.agentProfile` with `tools`, `name` and `description`; Copilot's `sessionMeta` is `nil` and its `launchArguments` are the three flags followed by five names after one `--excluded-tools`; Cursor's policy produces `nil`, `[]` and `[]`
- [ ] T023 [P] Add to `ToolPolicyTests`: `residual(matching:)` finds a residual tool by a prefixed name (`mcp__something__workflow` matches `workflow`), and does not match a different tool that merely contains the name

**Checkpoint**: the policy exists and is held by tests. Nothing applies it yet, so the app behaves exactly as before.

---

## Phase 3: User Story 1 — The morning check that lands in the app (Priority: P1) 🎯 MVP

**Goal**: A scheduling tool is not in front of the agent, so a standing arrangement becomes a workflow in the app.

**Independent test**: Ask a Claude agent and a Grok agent for a recurring check. A workflow appears in the project for both; no cron entry and no scheduler row is created.

- [ ] T024 [US1] Add `meta: JSONValue? = nil` to `sessionParams(cwd:additionalDirectories:mcpServers:)` in `Packages/AgentsKit/Sources/AgentsKit/ACP/ACPSession.swift:253` and set `params["_meta"] = meta` when it is non-nil, with a comment saying the app's scoping rides here and that a runtime with nothing to say sends no `_meta` at all
- [ ] T025 [US1] Add the same `meta: JSONValue? = nil` parameter to `newSession(cwd:additionalDirectories:mcpServers:)` and `continueSession(id:cwd:additionalDirectories:mcpServers:)` in the same file, passing it through to `sessionParams`
- [ ] T026 [US1] Add `meta: JSONValue? = nil` to `forkSession(cwd:additionalDirectories:)` in `Packages/AgentsKit/Sources/AgentsKit/ACP/ACPSession.swift:318` and merge it into the parameters it builds by hand, with a comment that a branch is a new conversation by any other name and would otherwise be the one door left open (FR-012)
- [ ] T027 [US1] Pass `meta: ToolPolicyCatalog.policy(for: runtimeID).sessionMeta` at the `newSession` call in `freshSession` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:206`
- [ ] T028 [US1] Pass the same at both `newSession` calls and the `continueSession` call in the pick-up path in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:371-384`, taking the runtime id from `agent.runtimeID` so a resumed agent is scoped exactly as a new one (FR-012)
- [ ] T029 [US1] Pass the same at the `forkSession` call in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Runtimes.swift:165`
- [ ] T030 [P] [US1] Add an integration test to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ResidualToolTests.swift` (or a new `Integration/ToolScopingTests.swift` if it reads better there) driving the real daemon with the fake agent: a Claude-shaped agent's `session/new` carries `_meta.claudeCode.options.disallowedTools`, a picked-up session carries the same, and a Cursor-shaped agent's carries no `_meta` at all
- [ ] T031 [P] [US1] Create `Packages/AgentsKit/Tests/AgentsKitTests/Live/RuntimeToolScopingLiveTests.swift` with `@Suite("Live: what a scoped runtime will admit to having", .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"), .timeLimit(.minutes(5)))`, and the Claude case: start the runtime as `RuntimeCatalog` does, make a session with the policy's `sessionMeta`, ask for its tools in one prompt, and expect none of `Workflow`, `CronCreate`, `ScheduleWakeup`, `Agent`, `ListAgents`, `ReportFindings` in the answer, and `AskUserQuestion`, `Bash`, `Read`, `Edit` and `Write` all still in it
- [ ] T032 [P] [US1] Add the Grok case to the same Live suite: none of `scheduler_create`, `scheduler_delete`, `scheduler_list`, `spawn_subagent`, `send_feedback`; `ask_user_question`, `read_file`, `grep`, `run_terminal_command` and `write` still there; and `workflow` and `monitor` expected to be *present*, asserted as residue so the test fails loudly the day Grok lets us remove them

**Checkpoint**: Claude and Grok are scoped. Copilot and Cursor behave exactly as before.

---

## Phase 4: User Stories 2, 3 and 4 — the launch-time lever (Priority: P1, P2)

**Goal**: Copilot loses its rival escalation queue, its rival suggestion tool, its subagents and its session store; Grok gets its overlay file.

**Independent test**: A Copilot agent with a decision to make raises a held question the phone can answer, ends its turn with chips above the prompt, and has no `software-factory-*` tool at all.

- [ ] T033 [US2] Create `Packages/AgentsKit/Sources/AgentsKit/Runtimes/RuntimePolicyFiles.swift` with `public struct RuntimePolicyFiles: Sendable` holding a `StoreLocations`, and `public func environment(for policy: ToolPolicy, onto base: [String: String]) throws -> [String: String]`: for each `EnvironmentFile`, create `<root>/runtimes/` if needed, write `contents` whole to `<root>/runtimes/<name>` (overwriting, atomically), and set `base[variable]` to that path. Doc comment in the house voice: the root is the daemon's identity, a second daemon gets a second copy, and nothing goes near `~/.grok`
- [ ] T034 [US2] Give `ProcessSessionLauncher` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift:440` a `locations: StoreLocations` stored property and an initialiser that takes it, and change `launch(runtime:path:cwd:)` to use `runtime.arguments + policy.launchArguments` and `RuntimePolicyFiles(locations:).environment(for: policy, onto: LoginShellPath.environment())`, with the policy looked up by `runtime.id`
- [ ] T035 [US2] Change `DaemonCore.init` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift:126` to build its default launcher as `ProcessSessionLauncher(locations: locations)` — the one place that already knows the root
- [ ] T036 [US2] Make a failure to write an environment file non-fatal in `RuntimePolicyFiles`: log it through `DaemonLog.shared` and carry on without the variable, with a comment that a session that will not start is worse than a runtime keeping its image tools, and that the check script is what notices
- [ ] T037 [P] [US2] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ToolPolicyTests.swift`: `RuntimePolicyFiles` against a temporary root writes exactly one file for Grok, at `<root>/runtimes/grok-overlay.toml`, returns an environment carrying `GROK_CONFIG_PATH` pointing at it, rewrites it when called twice, and writes nothing at all for the other three
- [ ] T038 [P] [US3] Add the Copilot case to `Packages/AgentsKit/Tests/AgentsKitTests/Live/RuntimeToolScopingLiveTests.swift`: started with the policy's launch arguments, its tool list has no `software-factory-` anything (so no `escalation_raise`, no `prompt_suggest`, no `output_list`), no `github-mcp-server-` anything, and none of `task`, `list_agents`, `read_agent`, `write_agent`, `session_store_sql`; `bash`, `view` and `apply_patch` are still there
- [ ] T039 [P] [US4] Add the artefact case to the same Live suite: a Claude session scoped by the policy lists no `mcp__claude_ai_Claude_Docs__*` and no `mcp__claude_ai_Google_Drive__*` tool, and still lists the connectors this app has no opinion about — at least one `mcp__claude_ai_Crustdata__*` — so the test would catch a policy that quietly took everything
- [ ] T040 [P] [US2] Add to the Live suite the stale-name case (FR-014): a Copilot policy with one nonsense name added still starts a session and still removes the real names

**Checkpoint**: all four runtimes are as scoped as their levers allow. Residue is still uncovered.

---

## Phase 5: User Stories 1 and 2 — covering the residue (Priority: P1)

**Goal**: What could not be removed is said in words, and refused where the runtime asks.

**Independent test**: A Cursor agent asked for a recurring check uses `manage_workflows`; a Grok agent that calls `workflow` under a runtime that asks first gets a refusal naming the app's tool, and the person is never shown the question.

- [ ] T041 [US1] Change `Briefing.workflows` in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift` into `static func workflows(scheduling isRemoved: Bool) -> String`: the full line as today when the runtime keeps its own scheduling tools, and a shorter one without the "do not write cron entries, launch agents, or scripts that nothing will run" sentence when they are gone. Update the doc comment: removal is the first line now, and words are what is left where removal failed
- [ ] T042 [US1] Add `static func residue(_ tools: [ResidualTool]) -> String?` to `Briefing` in the same file, returning `nil` for an empty list and otherwise one sentence naming the tools and one giving the `instead` of their categories, de-duplicated, in the order the policy lists them
- [ ] T043 [US1] Replace `Briefing.lines` and `Briefing.text` with `static func lines(for policy: ToolPolicy) -> [String]` and `static func text(for policy: ToolPolicy) -> String` in the same file, keeping the order suggestions → escalation → workflows → residue, and keeping the existing comment about why the order and the brevity matter
- [ ] T044 [US1] Update the call site in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:425` to `Briefing.text(for: ToolPolicyCatalog.policy(for: agent.runtimeID))`, taking the agent from `agents[agentID]`
- [ ] T045 [US2] Add `func autoRefused(_ request: PermissionRequest) -> (option: PermissionOption, note: String)?` to `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift`, beside `autoAllowed(_:)` at line 148: look up the agent's policy by `agents[request.agentID]?.runtimeID`, match `request.toolCall.name ?? request.toolCall.title` with `residual(matching:)`, and return the request's `rejectOnce` option — or `rejectAlways` if that is all there is — together with the sentence "`<tool>` is not available in this app. <category.instead>"
- [ ] T046 [US2] Call `autoRefused` in `DaemonCore.swift:339`, immediately after the `autoAllowed` branch: answer the permission, record `.runtimeNote(note)` for the agent, and return without holding, broadcasting or moving the agent. Comment it as the mirror of `autoAllowed` — the app answers its own tools yes and the tools it wishes were gone no — and note that a runtime which auto-approves its own tools never asks, so this is the second line and not the first (Research R8)
- [ ] T047 [P] [US1] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Unit/BriefingTests.swift`: the residue line names every residual tool of Cursor's policy and no tool of Claude's; Claude's briefing carries no residue line at all; the workflows line drops its cron sentence exactly when the runtime's scheduling tools are removed; and the existing length ceiling still holds for the longest of the four
- [ ] T048 [P] [US2] Add to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ResidualToolTests.swift`, against the fake agent: a permission request for `workflow` on a Grok agent is answered with a reject option, never reaches `pendingPermissions`, is never broadcast, and leaves a runtime note naming `manage_workflows`; a permission request for an ordinary tool on the same agent is held as it is today

**Checkpoint**: every conflicting tool on every runtime is either gone or spoken to.

---

## Phase 6: User Story 5 — knowing it still holds (Priority: P3)

**Goal**: One command re-asks every runtime what it has and reports anything the policy does not account for.

**Independent test**: Run the script; it prints removed, residue and unaccounted-for per runtime, and its exit code is the number of unaccounted-for tools.

- [ ] T049 [US5] Create `scripts/runtime-tools.sh` as a zsh wrapper around an inline Python script, built exactly like `scripts/acp-handshake.sh` (same `set -u`, same `python3 - "$@" <<'PY'` shape, same login-shell PATH lookup, same `CLIENT` capability block kept beside `ACP.ClientCapabilities.app`), taking an optional runtime id argument and a header comment saying what it re-checks and when it is worth running
- [ ] T050 [US5] In that script, implement the two runs per runtime from [contracts/tool-check.md](./contracts/tool-check.md): start the runtime, `initialize`, `session/new` — once plain, once with the policy's launch arguments, environment and `_meta` — and one prompt asking for every tool it can call, with permission requests answered by rejecting and every other incoming request answered `-32601`
- [ ] T051 [US5] Mirror the four policies into the script as a literal table with a comment saying it is a copy of `ToolPolicyCatalog` and that the unit tests are what keep the Swift honest — the script exists to catch a *runtime* that moved, not a table that did
- [ ] T052 [US5] Print the report in the shape [contracts/tool-check.md](./contracts/tool-check.md) gives — `removed (n of n)`, `kept`, `residue … covered by the briefing`, `NEW … NOT IN THE POLICY` — ending with the count of unaccounted-for tools and exiting with it, and say plainly in the closing line that a NEW tool is a question for a person rather than a failure
- [ ] T053 [P] [US5] Add a "Scoping an agent's tools" section to `README.md` after "What the app does with a runtime": what is taken away and why, that nothing of the person's is touched, that Cursor has no lever, and the one command to re-check — matching the existing `./scripts/acp-handshake.sh` paragraph in length and tone

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T054 [P] Run the five checks in [quickstart.md](./quickstart.md) against a branch root (`open -n … --args --root /tmp/agents-015`) and fix what they catch, particularly check 4: confirm the mtimes of `~/.claude/settings.json`, `~/.copilot/mcp-config.json`, `~/.grok/config.toml` and `~/.cursor/cli-config.json` are unchanged after a day's use (SC-004)
- [ ] T055 [P] Run `AGENTS_LIVE=1 swift test --package-path Packages/AgentsKit --filter Live` and record, in [research.md](./research.md), any measurement that has changed since 2026-09-19 — including whether Copilot's `search_code_subagent` has become excludable and whether Grok's `workflow` has become removable
- [ ] T056 Run `swift test --package-path Packages/AgentsKit` and `xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build`, both clean
- [ ] T057 [P] Check the spec's Out of scope section still holds after the work: no per-project exception crept in, no settings screen, nothing that reads or writes the person's configuration

---

## Dependencies

- **Phase 1 → Phase 2**: the files exist before they are filled.
- **Phase 2 → everything**: `ToolPolicy` and the catalog are read by every later phase.
- **Phase 3 (US1)** needs only Phase 2. It is the MVP: two of the four runtimes scoped, through the session rather than the launch.
- **Phase 4 (US2, US3, US4)** needs Phase 2, and is independent of Phase 3 — it touches the launcher, not the session. It can be built in parallel with Phase 3 by a second pair of hands.
- **Phase 5 (residue)** needs Phase 2 for the policy and Phase 4's `DaemonCore` changes only if both edit `DaemonCore.swift` at once; the briefing half (T041–T044, T047) is independent of everything but Phase 2.
- **Phase 6 (US5)** needs the policies to exist (Phase 2) and is best run once Phases 3–5 have landed, so its report is about the shipped thing.
- **Phase 7** is last by definition.

## Parallel opportunities

- T002, T003 together after T001.
- T006, T007 together; T015, T016, T017, T018 together once T008–T012 are in (four policies, one file, so land them in one pass if the same hand writes them).
- T020–T023 together.
- T037, T038, T039, T040 together — four independent test cases.
- T047 and T048 together; T053 alongside either.
- T054, T055, T057 together at the end.

## Implementation strategy

**MVP is Phase 3.** Claude and Grok are the two runtimes with a session-level lever, and between them they cover the complaint that started this: ask for a morning check, get a workflow in the app. Nothing in Phase 3 touches how a runtime is launched, so it can ship on its own with the other two runtimes behaving exactly as they do today.

**Then Phase 4**, which is where the biggest single win is — Copilot's rival server carries an escalation queue, a suggestion tool and an artefact store all at once, and one flag removes all three.

**Then Phase 5**, which is the honest part: the two runtimes that keep something conflicting get words about it, and the words are generated from the same table that does the removing, so they cannot drift.

**Phase 6 last**, because a re-check is only worth writing once there is something to re-check.

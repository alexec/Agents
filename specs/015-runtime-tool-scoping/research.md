# Research: Our Tools, Not Theirs

Everything here is a claim about somebody else's software, so everything here was measured rather
than read. The measurements were taken on 2026-09-19 against the versions installed on this Mac:
Claude's ACP adapter `@agentclientprotocol/claude-agent-acp` 0.78.0 (global npm), Copilot 1.0.87-0,
Grok's `agent stdio`, and `cursor-agent` 2026.09.10. Each runtime was started exactly as
`RuntimeCatalog` starts it, handed the same client capabilities the app advertises, given a session,
and asked to name every tool it can call.

---

## R1: What each runtime actually has

**Finding**: four inventories, taken before any scoping.

| Runtime | Tools | The ones that duplicate this app |
|---|---|---|
| Claude | 32 built-ins + ~80 from the person's own connectors | `Workflow`, `CronCreate`, `CronList`, `CronDelete`, `ScheduleWakeup`, `Monitor`, `RemoteTrigger`, `PushNotification`, `Agent`, `ListAgents`, `SendMessage`, `TaskOutput`, `TaskStop`, `ReportFindings`, `DesignSync`, `mcp__claude_ai_Claude_Docs__*`, `mcp__claude_ai_Google_Drive__*` |
| Grok | 33 built-ins | `workflow`, `scheduler_create`, `scheduler_delete`, `scheduler_list`, `monitor`, `spawn_subagent`, `kill_command_or_subagent`, `get_command_or_subagent_output`, `send_feedback` |
| Copilot | 19 built-ins, plus `chrome-devtools`, `github-mcp-server` and the person's `software-factory` server | `task`, `list_agents`, `read_agent`, `write_agent`, `session_store_sql`, and all of `software-factory-*`: `escalation_raise`, `escalation_await`, `escalation_list`, `prompt_suggest`, `agent_create`, `agent_list`, `output_list`, `task_*`, `factory_ask`, `message_send` |
| Cursor | 20 built-ins, no MCP servers loaded | `Task`, `CreateGoal`, `UpdateGoal` |

**Note on Cursor's MCP**: the person's `~/.cursor/mcp.json` is actually named `mcp.json,` — with a
trailing comma in the filename — so Cursor loads no MCP servers at all today. That is an accident,
not a policy, and the policy must assume it will be fixed one day.

**Note on `software-factory`**: it is the person's own MCP server, served over HTTP on
`127.0.0.1:4747`, and it is a second implementation of this app's entire remit — escalations,
artefacts, suggested prompts, agents and a task queue. It was up for the first inventory and down
for a later one, so its tools come and go from Copilot's list depending on the hour. Either way it
is configured in `~/.copilot/mcp-config.json` and in Grok's plugin list.

---

## R2: Claude — a denial list in the session's `_meta`

**Decision**: pass the removals as `_meta.claudeCode.options.disallowedTools` on `session/new`.

**Evidence**: the adapter reads `params._meta.claudeCode.options` into `userProvidedOptions`
(`dist/acp-agent.js:5912`) and merges it into the SDK's `disallowedTools`
(`dist/acp-agent.js:6065`). Measured: with the fifteen Claude tools above in that list, all fifteen
were gone from the agent's own account of what it can call, and everything needed for the work —
`Bash`, `Read`, `Edit`, `Write`, `Skill`, `WebFetch`, `WebSearch`, the notebook and MCP-resource
tools — was still there.

**Alternatives considered**:

- `_meta.claudeCode.options.tools` — an explicit allowlist that replaces the `claude_code` preset
  (`:5942`). Rejected: it takes precedence over the preset, so a tool the adapter adds next month
  would silently not arrive, and the failure would look like an agent that cannot do its job.
- `_meta.disableBuiltInTools` — the legacy shorthand for `tools: []`. Rejected: all or nothing.
- Editing `~/.claude/settings.json` `permissions.deny`. Rejected outright by FR-011: that file is
  the person's.

---

## R3: Claude — removing a connector, not just a tool

**Decision**: name the whole server for the two that store things — `mcp__claude_ai_Claude_Docs` and
`mcp__claude_ai_Google_Drive` — and leave the rest of the person's connectors alone.

**Evidence**: three forms of denial were tested in one session and all three worked — the whole
server (`mcp__claude_ai_Dice`), one exact tool
(`mcp__claude_ai_ZipRecruiter__search_jobs`), and a wildcard (`mcp__claude_ai_Google_Drive__*`).
None of the named tools appeared in the agent's list afterwards.

**Rationale**: a document store and a drive are artefact stores, which FR-004 puts out of bounds.
Crustdata, Dice and ZipRecruiter search the world; they duplicate nothing this app does, and FR-010
says leave them. Whole-server rather than tool-by-tool because the read half of a document store is
only useful for writing to it, and a list of eighty tool names in our source would be stale within
the month.

---

## R4: Claude — leave `settingSources` alone

**Decision**: do not touch it.

**Evidence**: a session started with `settingSources: ["project", "local"]` — dropping the person's
user-scoped settings — still had every `mcp__claude_ai_*` connector, because the connectors come
from the account rather than from `settings.json`. So it buys nothing for this feature.

**Rationale**: it would cost plenty. The person's own `CLAUDE.md`, their skills and their hooks all
come through `user`, and taking those away would make an agent started by this app worse at the work
for no gain in remit.

---

## R5: Copilot — flags at launch

**Decision**: start Copilot with `--disable-mcp-server software-factory`, `--disable-builtin-mcps`
and `--excluded-tools task list_agents read_agent write_agent session_store_sql`.

**Evidence**: measured, in one session. Copilot answered `Info: Disabled tools: list_agents,
read_agent, session_store_sql, task, write_agent`, the named tools were gone from its list, and the
`software-factory` and `github-mcp-server` tools with them. Tool names on this flag are the bare
ones — `task`, not `functions.task`, which is how the model spells them.

**On unknown names**: `--excluded-tools not_a_real_tool` produces `Info: Unknown tool name in the
tool excludedlist: "not_a_real_tool"` and the session starts anyway, with the recognised names still
removed. That is FR-014 satisfied by the runtime itself. One wrinkle worth knowing: those `Info:`
lines arrive as agent message text inside the session, not on stderr, so a stale name is visible in
the conversation. Untidy, not harmful, and an argument for keeping the names fresh (R9).

**One name is still missing**: the model lists `functions.search_code_subagent`, and the flag does
not recognise `search_code_subagent`, `code_search_subagent`, `subagent`, `search_code`,
`code_search`, `search_agent`, `search_codebase`, `codebase_search` or `semantic_search`. The
general subagent tool, `task`, does exclude, so the mechanism for spawning work is closed; the
code-search subagent is recorded as residue until its real id is found.

**Alternatives considered**: `--available-tools` (an allowlist). Rejected for the same reason as
Claude's `tools` array — a work tool added upstream would quietly not arrive. `--deny-tool` was also
rejected: it governs permission to run a tool the model can still see and still call, which leaves
the tool in front of the model on every turn, and this feature exists precisely to stop that.

**On naming somebody's private server in our source**: `software-factory` is named because it is the
one server we have measured that duplicates the remit. The check in R9 is what keeps that list
honest: any other MCP server whose tools look like escalations, artefacts, suggestions or agents
comes out as unaccounted for and gets a line in the policy.

---

## R6: Grok — an agent profile in the session's `_meta`, and an overlay file

**Decision**: pass `_meta.agentProfile` with a `tools` allowlist, and set `GROK_CONFIG_PATH` in the
child environment to an overlay the app writes.

**Evidence**:

- `_meta.agentProfile: {name, description, tools: [...]}` on `session/new` works. With ten work
  tools listed, `scheduler_create`, `scheduler_delete`, `scheduler_list`, `spawn_subagent`,
  `kill_command_or_subagent`, `get_command_or_subagent_output`, `send_feedback` and the seven `x_*`
  search tools were all gone.
- `workflow`, `monitor`, `search_tool`, `use_tool`, `enter_plan_mode`, `exit_plan_mode` and
  `open_page` survive the allowlist. Grok's own documentation explains why: "stock profiles inject
  enabled optional tools before applying the allowlist, while curated profiles remain strict"
  (`~/.grok/docs/user-guide/14-headless-mode.md`). Nothing documented says how to declare a profile
  curated from the client side.
- The documented `--disallowed-tools` flag does nothing over `agent stdio`. Measured twice —
  `grok --disallowed-tools … agent stdio` and again with `--no-leader` — and the full tool list came
  back both times. The flag belongs to the headless `-p` path.
- `GROK_CONFIG_PATH` pointing at an overlay TOML works: `[features] image_gen = false`,
  `video_gen = false` removed `image_gen`, `image_to_video` and `reference_to_video`.
- `GROK_CONFIG` with the same TOML *inline* does not work: the image tools were still there.
- `[workflows] enabled = false` and `[subagents] enabled = false` in the overlay did **not** remove
  `workflow` or `spawn_subagent`. The allowlist is what removes the subagent tools; nothing tested
  removes `workflow`.

**Residue**: `workflow` and `monitor`. Both are covered by words (R8).

**Cost of an allowlist here**: this is the one runtime where we must list what to keep rather than
what to remove, so a work tool Grok adds next month will not reach an agent until the list grows.
Accepted because it is the only lever that works, and R9 is how the drift is noticed.

---

## R7: Cursor — there is no lever

**Decision**: words only, and say so.

**Evidence**: the permission-rule vocabulary in the CLI bundle is `Shell(...)`, `Read(...)`,
`Write(...)`, `Delete(...)` and `Mcp(...)` — there is no rule kind that names a built-in tool, so
`Task`, `CreateGoal` and `UpdateGoal` cannot be denied, let alone hidden. `cursor-agent mcp disable`
and `~/.cursor/cli-config.json` are the person's own configuration and are out of bounds by FR-011.
`CURSOR_CONFIG_DIR` would let the app supply a whole config directory, but that directory also holds
the credentials, so pointing Cursor at ours would sign the person out of theirs.

**Residue**: `Task`, `CreateGoal`, `UpdateGoal`. If an MCP server that duplicates the remit is ever
loaded into Cursor, `Mcp(server:tool)` deny rules exist — but only in the person's file, so that
would stay residue too.

---

## R8: What to do about residue

**Decision**: two things, in this order. A line in the briefing naming what not to use and what to
use instead; and, where the runtime asks the client for permission before running a tool, an
automatic refusal from the daemon with the same sentence.

**Rationale**: the briefing already carries exactly this shape of line for workflows, and this
feature *shrinks* that paragraph everywhere the tool is actually gone — words are the fallback now,
not the first line. The refusal is the mirror of `DaemonCore.autoAllowed(_:)`, which already answers
a permission question about the app's own tools without troubling the person: same seam, opposite
answer, and the agent gets a sentence it can act on (FR-015).

**Limit, stated plainly**: a runtime that auto-approves its own tools never asks, so the refusal
never fires there. Grok's own config on this Mac has `permission_mode = "always-approve"`. For those
cases the words are all there is, which is why the policy keeps the residue list short and visible
rather than pretending it is empty.

---

## R9: How anyone knows it still holds

**Decision**: a script beside `scripts/acp-handshake.sh` that asks every runtime what it has, with
and without scoping, and prints three lists per runtime: removed, residue, and unaccounted for. A
report for a person to read, not a gate.

**Why not something stricter**: ACP has no method that lists an agent's tools. The protocol carries
tool *calls* and permission requests; a catalogue is not in it, and no runtime offers one as an
extension. So the only inventory available is to ask the agent in prose — which is good enough to
spot a new tool and not good enough to trust for exact ids. The evidence for that is R5: Copilot's
own list says `search_code_subagent`, and no such name exists on the flag that removes tools.

**What is asserted automatically**: a Live test (`AGENTS_LIVE=1`) per runtime that has a lever,
checking the specific removals whose names we have verified, plus a unit test that every runtime in
`RuntimeCatalog.builtIn` has a policy — total by construction, in the manner of `AgentGroupTests`.

---

## R10: Where scoping has to be applied

**Decision**: inside `ACPSession.sessionParams`, so `session/new` and `session/load` both carry it,
plus `forkSession`, which builds its own parameters and would otherwise be the one door left open.

**Evidence**: `newSession` and `continueSession` both go through `sessionParams`
(`ACPSession.swift:253`); `forkSession` (`:318`) builds `sessionId` and `cwd` by hand. FR-012 wants a
resumed agent scoped exactly as a new one, and a branch is a new conversation by any other name.

**Who supplies it**: the daemon, which knows the runtime; `ACPSession` takes the metadata as an
argument and stays as it is — no code in it asks which runtime it is talking to, which is the rule
the README sets for the whole app.

---

## R11: Where the Grok overlay file lives

**Decision**: `<root>/runtimes/grok-overlay.toml`, under the daemon's own root, written when the
daemon starts a Grok session and rewritten every time from the policy.

**Rationale**: the root is already the daemon's identity and the only place this app writes
(README). A second daemon on a second root gets its own copy, which is the behaviour every other
file here has. Nothing goes near `~/.grok`.

**Alternatives considered**: inline `GROK_CONFIG` — measured, does not work (R6). A temporary file
deleted at the end of the session — rejected: nothing documents when Grok re-reads the overlay, and
a config file that disappears under a running process is a failure nobody would diagnose twice.

---

## R12: Re-measured 2026-09-20, against the shipped policy

The first time every one of the above was re-taken through the code rather than by hand:
`AGENTS_LIVE=1 swift test --filter RuntimeToolScopingLiveTests`, plus `./scripts/runtime-tools.sh`.
Versions unchanged from the 2026-09-19 header.

**Every policy still holds.** Claude loses all seventeen and keeps `AskUserQuestion`; Grok loses its
seven; Copilot loses its five along with the whole `software-factory` server and `github-mcp-server`;
Cursor has no lever and its three stay. The check script reports **zero tools unaccounted for**
across all four.

**Neither piece of residue has become removable.** Grok still offers `workflow` and `monitor` after
the allowlist, and Copilot still offers `search_code_subagent` under a name `--excluded-tools` will
not accept. The two Live expectations that assert residue is *present* both passed, which is the
answer that keeps them in `residue` rather than in `removed`.

### What had moved

**Both instruments were wrong about Copilot, in the same way, for the reason R5 predicted.** The
first run reported `removed (0 of 5)` — `THE LEVER DID NOT TAKE IT` against every name — and the
Live suite failed seven expectations. Copilot had in fact removed all five. What neither had
allowed for is that Copilot confirms its own scoping *as agent message text*:

```text
Info: Disabled tools: list_agents, read_agent, session_store_sql, task, write_agent
Info: Unknown tool name in the tool excludedlist: "not_a_real_tool_at_all"
```

R5 wrote that line down as "untidy, not harmful". It is harmful to anything that reads the session
for an inventory, because the confirmation names the removed tools verbatim, and a substring search
then finds them. Both the Live suite and the script now drop agent message chunks beginning `Info:`.
Worth knowing before writing a third thing that reads a tool list out of a conversation.

**Claude has grown tools since R1**: `ToolSearch`, `EnterPlanMode`, `ExitPlanMode`, `EnterWorktree`,
`ExitWorktree`. None duplicates the remit — planning and worktrees are the work, and FR-010 leaves
them — so none gets a policy line. `ToolSearch` is the one to keep an eye on: it fetches schemas for
tools held back from the initial list, and nobody has measured whether a denied tool can be reached
through it. The scoped agent did not list any denied tool, so it is not offering them; whether it
would hand one over if asked by name is an open question and the one thing here that could undo a
removal quietly.

**Grok's overlay is narrower than R6 suggested.** `[features] image_gen = false` and
`video_gen = false` still remove `image_gen` and the two video tools, but `image_edit` survives both
the overlay and the allowlist. It duplicates nothing of ours, so it stays unlisted under FR-010 —
recorded because it is a difference from the 2026-09-19 reading, not because it is a problem.

**Copilot's `chrome-devtools` server is inconsistent.** Its tools were in the inventory on the first
run and absent from the second, with `--disable-builtin-mcps` passed both times. Unexplained. It
duplicates nothing of this app's remit either way, so it changes no policy line, but a flag that
works four times in five is worth knowing about before it is leaned on for something that matters.

**Copilot's `functions.sql` is worth a second look.** `session_store_sql` is removed and stays
removed; a bare `sql` tool is in the list and was in R1's count of nineteen built-ins without being
named. If it reaches the same store, it is a second door to an artefact store this feature closed —
the check script's word list does not catch it because `sql` alone is not in `SUSPECT`. Not changed
here, because guessing at a tool's reach and removing a working one are both worse than writing the
question down.

---

## R13: Grok cannot ask the person over ACP at all

Chased because 016's live run had Grok meet a decision it could not make and guess. Two questions:
**did scoping take away the escalation path**, and **why does the tool not get called**.

**Scoping did not take it away.** The control was already on record from before this feature existed:
`specs/014-agent-outcomes/research.md` has an unscoped Grok, given a question it could not answer,
ending `finished`, raising nothing at all, and putting the question into a `needs_answer` outcome
report instead. No policy, no allowlist, same behaviour.

**The reason is that there is no channel, and this is documented rather than inferred.** From Grok's
own docs on this Mac:

- `ask_user_question` is a **terminal-UI card**. `docs/user-guide/03-keyboard-shortcuts.md` files it
  under "Blocking cards": *"Four surfaces block the agent on your answer and take over the keyboard
  while they are open: the question card (`ask_user_question`), the MCP elicitation card
  (`x.ai/mcp/elicit`), the permission prompt, and the cancel-turn panel."* Its whole interface is
  arrow keys, `Tab`, and `1`–`9` in Grok's own scrollback.
- The ACP page, `docs/user-guide/15-agent-mode.md`, lists every `sessionUpdate` kind, every `x.ai/`
  extension method, and every agent-to-client notification. **None of them carries a question.** The
  only elicitation named anywhere is `x.ai/mcp/elicit`, which is Grok rendering a card when *an MCP
  server* asks *Grok's user* for input — the opposite direction from the one we need.

So over `agent stdio` there is no terminal to draw the card in and no notification to forward it
down. The tool exists, the model lists it, and calling it can reach nobody.

**The `search_tool` hunt was a red herring, and the first write-up of this had it wrong.** Those are
not an indirection over built-ins. `docs/user-guide/07-mcp-servers.md`: *"`search_tool` — Discover
available integration tools across all enabled MCP servers"*, and `use_tool` calls one by qualified
catalog key (`github__create_issue`). Grok was searching the **MCP catalogue** — which in our
sessions is this app's own server, `agents__suggest_next_prompts` and its three siblings, and those
names appear in the transcript with exactly that `server__tool` shape. It went looking for an
escalation tool among the app's MCP tools, because that is where every other tool the briefing names
lives.

**Can `agentProfile` promote it?** No, and promotion is the wrong idea: `agentProfile` governs which
tools exist (a name or a JSON object, per `15-agent-mode.md`), not how a tool reaches a client. No
profile field can give a TUI card a transport it does not have.

### What changed here

`ask_user_question` **stays** in Grok's `keep` list and in `kept`. Removing it buys nothing today and
costs us the day Grok gives it a way out.

`ToolPolicy.escalationTool` is **`nil` for Grok**. It was briefly set, and the live run of the same
day measured what that does: told *"Yours is called `ask_user_question`"*, the agent spent its turn
searching the MCP catalogue for that exact string, called `use_tool`, reached nobody, and guessed
anyway. Naming a tool that cannot reach the person is worse than naming none, which is what FR-008
says for a slightly different reason. The field now means *a tool that can actually put a question to
the person*, which is narrower than *has a question tool*, and Claude is the only runtime of the four
that qualifies.

**What this leaves.** Grok's questions arrive as `needs_answer` on the agent row — visible, and the
app already draws it — but not waiting and not on a phone. The briefing needs no extra line for it:
016's `outcome` line already tells every agent to report how it went, and that is the channel Grok
actually uses. Worth revisiting the day `15-agent-mode.md` grows a notification that carries a
question.

---
name: assess-runtime
description: Assess an agent runtime's integration with the Agents daemon and the app's own tools (#47) — a fixed series of steps, one per tool group, that the daemon scores from its own record, plus a self-report in .agents/reviews/runtimes/<runtime>-<date>.md. Use when asked to assess, check or qualify a runtime (Claude, Codex, Copilot, OpenCode, …), after a runtime or adapter update, or when a new runtime is added.
---

# Assess a runtime

`scripts/acp-handshake.sh` and `scripts/runtime-tools.sh` check what a runtime *says* it can
do. This checks what an agent on it *does* with the app's tools, and the daemon scores it
from its own record, so the result never rests on the agent's word.

## Starting one

The usual way in is **Settings ▸ Agent Runtimes ▸ <runtime> ▸ Assess…**, which picks a
project and calls the daemon's `runtimes/assess`. That starts an agent on the runtime, on
the cheapest model it offers (Haiku for Claude), read from a draft of the session it starts on, labelled `assess-runtime`, with
the brief: `RuntimeAssessment.brief` in
`Packages/AgentsKit/Sources/AgentsKitCore/Model/RuntimeAssessment.swift`. The brief is the
source of truth for the steps; this file names the same ones, and a test keeps the ids in
step.

From a script, or on a scratch root (see the run-app skill):

```sh
S=.agents/skills/run-app/scripts
$S/rpc.py $ROOT call runtimes/assess "{\"runtimeID\":\"claude\",\"folder\":\"file://$ROOT/work\"}"
# … later, at any point, the daemon's own score:
$S/rpc.py $ROOT call runtimes/assessment '{"agentID":"…"}'
```

Unattended, `.agents/skills/assess-runtime/scripts/assess.py` does both and answers what a
person would (the form, the runtime's own question, permission cards) — see below.

Runtimes out of the pool (not installed, not signed in, or marked out on the Runtimes page)
are not assessed: `start_agent` would refuse them too. Say which were skipped and why.

## The steps

Six turns. Each step uses the app's own tools; the agent does every one for real, exactly
as written, even when it expects a failure, and records what the tool answered.

| Step | Turn | What the agent does | Passes when (from the daemon's record) |
| --- | --- | --- | --- |
| `show_file` | 1 | `show_file` on the report before it exists, then writes it | the call answered "open, empty", and the report is on disk at the end |
| `leases` | 1 | `lease_resource assess-<id>`, `list_resources`, `release_resource` | all three answered; `lease.granted` and `lease.released` on the log; nothing held |
| `workflows` | 1 | `manage_workflows` `list`, `write` a throwaway `assess-<id>` (waits on `custom.assess_never`), `list`, `remove` it | listed; the write was left waiting for the person's OK (and off, #124); listed again; removed, with no file left. **Not offered** when the project already has as many waiting as it may (#132) |
| `events` | 1 | `wait_for_event recent`, `publish_event custom.assess_ping`, `wait_for_event` on it from that position; then `wait_for_event custom.assess_never` with no time limit and `cancel_wait` | the event is on the log from this agent; the wait came back with it; `cancel_wait` answered after the second wait |
| `ask_form` | 1 | `ask_form` with a choice (`pick`) and a text field (`words`) | answered; the typed text came back in the tool's answer unchanged, and is in the report |
| `own_ask` | 1 | one question with the runtime's own tool (Claude `AskUserQuestion`, Codex `request_user_input`, Cursor `AskQuestion`, Antigravity `ask_question`) | an elicitation reached the app beyond `ask_form`'s; **not offered** where `ToolPolicy.escalationTool` is nil (Grok, Copilot, Gemini, OpenCode) and none came |
| `helpers` | 1–2 | `start_agent` a helper on the same runtime, `list_my_agents`, `wait_for_event agents` it, which ends the turn (refused if it has already finished, which counts); then `park_agent` and `archive_agent` it | helper marked as this agent's; the "block … has cleared" prompt resumed it; `agent.parked` on the log; helper archived by an agent |
| `wait` | 2–3 | `wait_for_event custom.assess_never until_minutes 1`, then ends its turn | the "timed out" prompt started it again |
| `ending` | 1–6 | `wait_for_event` on the helper, `wait_for_event until_minutes 1` with no events, then `park_agent` with no id | both waits recorded as blocks (#481; `finish_turn blocked` with `waiting_on` or `check_again_in_minutes`, from a conversation briefed before the tool was removed, counts the same). The daemon works out how every turn ended (#479) |
| `worktree` | 4–5 | `move_worktree worktree assess-<id>` and ends its turn, then, in it, `move_worktree leave_worktree remove` and ends its turn (a `move` on `finish_turn`, as before #481, counts the same) | the app's notes say it moved into the worktree, then back, and removed it; it is in no worktree at the end. **Not offered** outside a git repository, or where the runtime cannot move |
| `sessions` | 5 | `list_sessions`, then `read_session` on its own id | the list names this session; the read gives back its id and title |
| `scope` | 5 | write a line, with its own file tool, to `<root>/assessments/scope-<id>.txt` (outside every project) | a permission card asked about it, or the runtime refused it; never written without asking |
| `permissions` | 5 | records the card for that write and its answer | a card came and its answer held: written only if allowed. **Not offered** where the runtime refused without asking |
| `report` | 6 | finishes `.agents/reviews/runtimes/<runtime>-<date>.md`: a row per step and "What to fix" | the file is there and names every step |

### A third party's view (#191), by hand

Not one of the scored steps yet: it needs a person's own MCP Apps server. Check it after an
adapter update, or when a runtime comes back to the pool, because the app finds a third
party's tool call only by the shape of the runtime's ACP updates (`ACPToolShape`).

1. Serve an ext-apps example over streamable http in a scratch folder, e.g.
   `npm i @modelcontextprotocol/server-basic-vanillajs` and
   `PORT=3191 node node_modules/@modelcontextprotocol/server-basic-vanillajs/dist/index.js`.
2. Put it in the scratch project's `.agents/mcp.json` as
   `{"type": "http", "url": "http://localhost:3191/mcp"}`, and approve it (`mcp/list` for the
   digest, then `mcp/approve`): a server waiting for approval is left out of the session.
3. Start the runtime with "Call the get-time tool of the basic-vanillajs MCP server once".
4. **Passes** when the transcript has an `appView` entry with `"server": "basic-vanillajs"`,
   done, whose `result` has `structuredContent.time`. Running first, then done, for a runtime
   that names the server outright (`rawInput.server`, or `mcp__<s>__<t>`); done only, for a
   joined title (`<s>-<t>`). **No entry** for a runtime that passes text only (OpenCode, Q7):
   that is by design, and its view can still be pinned.
5. Record the tool call's `title`, `name`, `rawInput` and `rawOutput` in the report, so a
   new shape can be added to `ACPToolShape` and its tests.

As of 2026-10-06: Claude walked (running, then done); Codex, Copilot and OpenCode covered by
`ACPToolShapeTests` from the #186 probe's wire lines, not run live.

## How it is scored

Every call an agent makes to the app's tools is kept by the daemon, as it answered it, in
`<root>/agents/<id>/app-tools.jsonl` (method, arguments without the token, answered or
refused and the words, how long it was held). `RuntimeAssessmentVerifier` reads that, the
transcript the daemon wrote (endings, questions and their answers, the prompts that started
the agent again), the event log, the helpers' records and the lease book, and gives each step
passed, failed or not offered with the evidence. It runs when the assessing agent finishes a
turn that is not `blocked`; the table goes into the conversation as a note from the app, and
the score to `<root>/assessments/<agentID>.json`. `runtimes/assessment` scores again on
demand.

The agent's own report is its account and may disagree with the daemon's table. Where they
disagree, the daemon's table is the result, and the difference is itself a finding.

## Running it unattended

```sh
.agents/skills/assess-runtime/scripts/assess.py $ROOT claude [codex …] --folder $ROOT/work
```

It starts each assessment through `runtimes/assess`, answers the form (`pick` → the first
option, `words` → a fixed phrase), the runtime's own question and every permission card with
allow-once — except the card for the write outside the project, which it rejects, so the
`permissions` step sees a refusal held — follows the agent to its last turn (about six minutes: two one-minute waits, a 45-second hold before `cancel_wait`, and two moves),
then prints the daemon's table and the report's path. When the cheapest model stops the
run before any step (a free model whose provider is down: OpenCode's did, 2026-10-03), it
runs again on the runtime's own default. `--model M` picks one instead (`default` for the
runtime's own), and so does `"model"` on `runtimes/assess`. Codex and OpenCode are installed
on a scratch root with `rpc.py $ROOT call runtimes/install '{"runtimeID":"codex"}'`, into
the root's own `tools/`. It never answers for anything but the
agents it started.

## After

- **All passed:** the agent ends `done` and parks itself. Nothing to do.
- **Anything failed:** it ends `needs_answer`, naming each failure and a likely fix (the app,
  the adapter, the runtime's version, a setting). File the app ones as issues; the runtime
  ones go with the nightly check (#39).
- Archive the assessing agent once read. Its helper is archived by the agent itself.
- The report is a file in the project like any other: commit it only if asked.

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
| `dashboard` | 1 | `set_tile` a status tile, `read_dashboard`, `remove_tile` | all three answered |
| `events` | 1 | `wait_for_event recent`, `publish_event custom.assess_ping`, `wait_for_event` on it from that position; then `wait_for_event custom.assess_never` with no time limit and `cancel_wait` | the event is on the log from this agent; the wait came back with it; `cancel_wait` answered after the second wait |
| `ask_form` | 1 | `ask_form` with a choice (`pick`) and a text field (`words`) | answered; the typed text came back in the tool's answer unchanged, and is in the report |
| `own_ask` | 1 | one question with the runtime's own tool (Claude `AskUserQuestion`, Codex `request_user_input`, Cursor `AskQuestion`, Antigravity `ask_question`) | an elicitation reached the app beyond `ask_form`'s; **not offered** where `ToolPolicy.escalationTool` is nil (Grok, Copilot, Gemini, OpenCode) and none came |
| `helpers` | 1–2 | `start_agent` a helper on the same runtime, `list_my_agents`, `finish_turn blocked waiting_on` it (refused if it has already finished, which counts); then `park_agent` and `archive_agent` it | helper marked as this agent's; the "block … has cleared" prompt resumed it; `agent.parked` on the log; helper archived by an agent |
| `wait` | 2–3 | `wait_for_event custom.assess_never until_minutes 1`, then `finish_turn blocked` | the "timed out" prompt started it again |
| `ending` | 1–6 | `finish_turn` blocked on the helper (with title and next prompt), blocked on the wait, blocked with `check_again_in_minutes 1`, then `done` + park or `needs_answer` | every one recorded as sent; the last is done or needs_answer; no turn ended without an account |
| `worktree` | 4–5 | `finish_turn partly_done worktree assess-<id>`, then, in it, `finish_turn partly_done leave_worktree remove` | the app's notes say it moved into the worktree, then back, and removed it; it is in no worktree at the end. **Not offered** outside a git repository, or where the runtime cannot move |
| `sessions` | 5 | `list_sessions`, then `read_session` on its own id | the list names this session; the read gives back its id and title |
| `scope` | 5 | write a line, with its own file tool, to `<root>/assessments/scope-<id>.txt` (outside every project) | a permission card asked about it, or the runtime refused it; never written without asking |
| `permissions` | 5 | records the card for that write and its answer | a card came and its answer held: written only if allowed. **Not offered** where the runtime refused without asking |
| `report` | 6 | finishes `.agents/reviews/runtimes/<runtime>-<date>.md`: a row per step and "What to fix" | the file is there and names every step |

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
then prints the daemon's table and the report's path. It never answers for anything but the
agents it started.

## After

- **All passed:** the agent ends `done` and parks itself. Nothing to do.
- **Anything failed:** it ends `needs_answer`, naming each failure and a likely fix (the app,
  the adapter, the runtime's version, a setting). File the app ones as issues; the runtime
  ones go with the nightly check (#39).
- Archive the assessing agent once read. Its helper is archived by the agent itself.
- The report is a file in the project like any other: commit it only if asked.

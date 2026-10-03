# First runtime assessments, 2026-10-02 (#47)

The first real runs of the `assess-runtime` skill, on scratch roots (`/tmp/run-a47`,
`/tmp/run-a47-first`) built from `agents/work-github-issue-47`, driven unattended by
`.agents/skills/assess-runtime/scripts/assess.py`, which answered the form, the runtime's own
question and every permission card for the agents it started.

**Assessed:** Claude (Haiku 4.5) and Copilot (claude-haiku-4.5, Copilot's cheapest).
**Not assessed:**
- Grok, Cursor, Gemini and Antigravity: out of the pool on the real Mac.
- Codex and OpenCode: the app installs its own copy of each, and these scratch roots had
  neither installed. Copilot is the person's own install, so it was the one of the three
  already on the root.

## Claude: 11 of 11 passed

Run on `fb66cb78`. This is the daemon's table, as `runtimes/assessment` gave it:

| Step | Result | From the app's record |
| --- | --- | --- |
| `show_file` | passed | `show_file` opened claude-2026-10-02.md empty, before the first write |
| `leases` | passed | assess-bb85be32: granted, listed, released; nothing left held |
| `workflows` | passed | `manage_workflows` listed them |
| `dashboard` | passed | `set_tile`, `read_dashboard` and `remove_tile` answered |
| `events` | passed | published custom.assess_ping; the wait came back with it in 0.0 s |
| `ask_form` | passed | answered; "plum lantern 47" came back unchanged and is in the report |
| `own_ask` | passed | 1 question reached the app through `AskUserQuestion` |
| `helpers` | passed | helper 499012A1 on claude: marked as this agent's, resumed this one when it finished, parked, archived |
| `wait` | passed | waited 1 min for custom.assess_never; started again when it timed out |
| `ending` | passed | recorded: blocked, blocked, blocked, done; every turn ended with an account |
| `report` | passed | claude-2026-10-02.md names every step |

The agent's own report from the first run (on `ac210c7e`) said all passed. The daemon then
said `leases` failed. The fault was the verifier's: `lease.released` names only the resource,
not the agent. That was fixed in `fb66cb78`, and the run above is clean.

## Copilot: 9 passed, 1 not offered, and a runaway helper on the second run

**First run** (on `ac210c7e`), rescored by the fixed daemon on its kept root:

| Step | Result | From the app's record |
| --- | --- | --- |
| `show_file` | passed | `show_file` opened copilot-2026-10-02.md empty, before the first write |
| `leases` | passed | assess-33883c01: granted, listed, released; nothing left held |
| `workflows` | passed | `manage_workflows` listed them |
| `dashboard` | passed | `set_tile`, `read_dashboard` and `remove_tile` answered |
| `events` | passed | published custom.assess_ping; the wait came back with it in 0.0 s |
| `ask_form` | passed | answered; "plum lantern 47" came back unchanged and is in the report |
| `own_ask` | not offered | the runtime has no question tool the app can carry |
| `helpers` | passed | helper 972F0774 on copilot: marked as this agent's, resumed this one when it finished, parked, archived |
| `wait` | passed | waited 1 min for custom.assess_never; started again when it timed out |
| `ending` | passed | recorded: blocked, blocked, done (1 refused first); every turn ended with an account |
| `report` | passed at the time | It named every step when it was scored. The rescore reads `failed` only because the root was renamed afterwards, so the recorded path pointed at the second run's file. |

At the time, the daemon failed `helpers` and `ending`. Again the fault was the verifier's:
Copilot's helper finished in about 20 s, before its starter blocked on it, and the daemon
rightly refused a block on an agent that had already ended. That now counts, and the brief
tells the agent to go straight on.

**Second run** (on `fb66cb78`): the helper was told only "Reply with the word OK, then call
finish_turn with outcome done and the message OK." It called `finish_turn` done, and then
**its turn did not end**:
- It went on working in the same ACP turn. It found the project's other report, ran its own
  version of the assessment (leases, workflows, a report under another name), and ended
  `done`, then `needs_answer`, then `nothing_to_do`, still without the turn ending.
- So the assessing agent, blocked on it, was never started again, and was stopped by hand
  after 13 minutes.

On the first run, the same prompt ended the turn at once. So whether Copilot's turn ends at
`finish_turn` is not consistent. This is the "runtimes differ in whether they call
finish_turn" class that #47 was opened to catch.

## What was checked against what

The daemon's score was never taken from the agents' reports. Each agent's report said
"all passed" both times, including the runs where the daemon (rightly or wrongly) said
otherwise. Every disagreement above was settled from `app-tools.jsonl`, the transcript and
the event log.

## The rest of the issue's steps: Claude 15 of 15

Later the same evening, after the steps the issue asked for and the branch lacked were added
(`worktree`, `sessions`, `scope`, `permissions`, the throwaway workflow and `cancel_wait`).
Three Claude Haiku runs, on a git scratch project, rebased onto main `3a6a5b0b`:

1. **14 of 15** (`ask_form` failed). This was the driver's fault: it rejected every card that
   quoted the scope file's path, including the agent's own edits to its report. It now
   matches by where a write lands, and so does the verifier (`8c81d8d9`).
2. **12 of 15.** One was a real finding and two were ours:
   - `leases`, the finding: Haiku called `lease_resource "screen"` where the brief said
     `list_resources`. The model didn't follow the brief, and the record caught it.
   - `ending`, ours: a permission card after `finish_turn` was counted as a new turn
     starting, so three accounted turns read as silent.
   - `show_file`, ours: the first run's report was already there. A second assessment the
     same day now gets `-2.md` (`1b002d34`).
3. **15 of 15**, on the rebuilt host, with a same-day report put there first. It got
   `claude-2026-10-02-2.md`, opened empty. The app's note names the adapter and host:
   *claude (@agentclientprotocol/claude-agent-acp 0.81.2, model haiku, on this Mac (…))*.
   Afterwards the project had no worktree, no `assess-…` branch, no workflow file, and no
   scope file outside the project. The driver rejected the scope card, and nothing was
   written.

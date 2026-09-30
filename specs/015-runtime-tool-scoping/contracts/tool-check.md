# Contract: the tool check

`scripts/runtime-tools.sh`, beside `scripts/acp-handshake.sh` and built the same way — a zsh wrapper
around a Python script, no dependencies, no build. The handshake script answers *does the app do
something with everything a runtime advertises*. This one answers *does the policy still cover
everything a runtime offers*.

```sh
./scripts/runtime-tools.sh              # every runtime
./scripts/runtime-tools.sh grok         # one of them
```

## What it does

For each runtime, twice: start it exactly as `RuntimeCatalog` does, hand it the same client
capabilities, make a session — the second time with the policy's launch arguments, environment and
`_meta` — and ask, in one prompt, for every tool it can call. Then compare both answers with the
policy.

## What it prints

```text
== grok, scoped by an allow list as _meta.agentProfile.tools, plus a config overlay on disk
   removed (4 of 4)
   kept    ask_user_question, spawn_subagent, kill_command_or_subagent, get_command_or_subagent_output
   residue workflow, monitor                        covered by the briefing
   NEW     some_new_tool                            NOT IN THE POLICY

== cursor, scoped by none; no rule kind names a built-in tool
   no lever on this runtime; everything conflicting is residue
   kept    Task, CreateGoal, UpdateGoal
   NEW     —

3 tools offered by a runtime that the policy neither removes, keeps, nor explains.
```

Exit code is the count of unaccounted-for tools, so it can be a step in a check later without being
one now.

`kept` is a list of things a runtime had taken away once and must have again, which is what makes
this the check for the reversal of 2026-09-29: a run that prints `GONE … KEPT ON PURPOSE AND NOT
THERE` has found a runtime that dropped its own sub-agents or task tracker.

## What it is not

It is a report to read, not a gate to pass. The reason is in R9: ACP has no method that lists an
agent's tools, so the inventory is the agent's own prose, and that is reliable enough to notice a
new tool and not reliable enough to trust for an exact id. A tool listed as NEW is a question for a
person, not a failure.

## What is asserted automatically instead

In `Packages/AgentsKit/Tests/AgentsKitTests/`:

| Test | Kind | What it holds |
|---|---|---|
| Every runtime in `RuntimeCatalog.builtIn` has a policy | Unit | The mapping is total |
| Every `RemovedTool` and `ResidualTool` names a category, and every category names the app tool that replaces it | Unit | No removal without a reason |
| A policy with a `words` lever produces no `_meta`, no flags and no environment | Unit | Cursor is not accidentally sent something |
| A policy with nothing to deny sends no deny list and no policy file, and one with a rule sends it | Unit | An empty `disabledTools` is a different message from no `_meta` |
| The three levers each produce the exact wire shape in [runtime-launch.md](./runtime-launch.md) | Unit | The contract, in a test |
| `Briefing.text(for:)` names every residual tool of that runtime and no other | Unit | Words and policy cannot drift |
| A residual tool's permission request is refused with the category's sentence, and never held | Integration, against the fake agent | The refusal path |
| Per runtime with a lever: the named removals are gone, the escalation tool and the work tools are still there | Live (`AGENTS_LIVE=1`) | The claim about somebody else's software |
| A policy carrying one nonsense name still starts a session | Live | FR-014 |

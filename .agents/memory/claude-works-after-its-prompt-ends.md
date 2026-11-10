---
name: claude-works-after-its-prompt-ends
description: "Claude's ACP adapter answers session/prompt with end_turn, then works on its own (a background command's end) with no prompt in flight; agentsd calls that an unprompted turn (#4323)"
metadata:
  type: project
---

claude-agent-acp (0.81) settles `session/prompt` with `end_turn` when the model stops, also
with a background Bash still running. When the command ends, the CLI starts a cycle of its
own (result `origin.kind` `task-notification`; also `peer`, `coordinator`, `observer`) and
streams its updates with no prompt in flight. The cycle ends with a `usage_update` whose
`_meta` has `_claude/origin`. Only background subagents hold the prompt open
(`deferredSettle`); background commands do not.

**Why:** agentsd took that cycle for a finished agent: Done in every list, and
hand_to_person, ask_question and ask_secret refused ("… while this agent is working").

**How to apply:** since #4323 `Go/internal/agentsd/unprompted.go` begins a turn on the
cycle's first words, thought or tool call (or an app tool call that needs a turn), and ends
it at that `usage_update`, a stop, the runtime's exit, or 2 minutes quiet with nothing in
flight. An `agent.ended` can now come twice for one prompt: once at the prompt's end, once
at the cycle's. A test of out-of-turn updates uses the fake runtime's "build in the
background, then wait for <file>" prompt (`turns_test.go`).

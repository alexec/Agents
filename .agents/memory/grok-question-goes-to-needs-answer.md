---
name: grok-question-goes-to-needs-answer
description: Grok cannot raise a question over ACP at all; ask_user_question is a terminal-UI card with no ACP channel.
metadata:
  type: reference
---

Grok cannot reach the app's escalation path, and it is not a bug either side can fix from
here. `ask_user_question` is a **terminal-UI blocking card** — Grok's own docs file it
beside the permission prompt, driven by arrow keys — and its ACP page lists every update
kind, extension method and agent-to-client notification without one that carries a
question. Over `agent stdio` there is no terminal to draw it in and nothing to forward it
down. Its questions arrive instead as a `needs_answer` outcome report on the agent row:
visible, but not waiting and not on a phone.

**Why:** measured twice, and the unscoped control in 014 behaves the same, so this is not
caused by tool scoping — do not go hunting in `ToolPolicyCatalog` when a Grok agent guesses
instead of asking. Naming the tool in the briefing was tried and made it worse: the agent
searched the MCP catalogue for it and guessed anyway.

**How to apply:** leave `ask_user_question` in Grok's allowlist for the day it gets a
channel, but keep `ToolPolicy.escalationTool` nil for it. Full write-up with the doc
citations is `specs/015-runtime-tool-scoping/research.md` R13; re-check before relying on
it, since it is a claim about someone else's software.

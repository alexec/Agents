---
name: repo-is-agent-loops
description: The repo is agentloops-dev/agent-loops since 2026-11-13 (#5296); old names redirect; the daemon learns the alias at its daily check
metadata:
  type: project
---

The GitHub repo is `agentloops-dev/agent-loops` (renamed from `agentloops-dev/Agents` on 2026-11-13, #5296; it moved from `alexec/Agents` the same day, #4929). GitHub redirects both old names, for git and the API. `origin` is `https://github.com/agentloops-dev/agent-loops.git` in the main checkout, and every worktree reads it from there.

**Why:** the product is Agent Loops (Alex, 2026-11-13, #4925).

**How to apply:** use the new name in new links and commands. The Go module path and most links still say `agentloops-dev/agents` until #5320. The daemon's repo alias book (#4957, `repo-aliases.json` in the store root) learns `agentloops-dev/agents → agentloops-dev/agent-loops` at its daily check, or 2 minutes after it starts; until then an old ref and a new event may not match.

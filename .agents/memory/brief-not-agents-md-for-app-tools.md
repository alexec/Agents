---
name: brief-not-agents-md-for-app-tools
description: "An app tool an agent must find goes in the brief (Go/internal/agentsd/brief.go), not AGENTS.md or this repo's skills"
metadata:
  type: feedback
  modified: 2026-11-06T04:42:26.790Z
---

To make agents aware of an app tool, put it in the brief (`Go/internal/agentsd/brief.go`). Do not count on AGENTS.md or `.agents/skills` (Alex, 2026-11-05).

**Why:** AGENTS.md and the skills belong to this repo only. An agent in any other folder gets only the brief and the tool names. Claude defers MCP tools, so it never reads a tool's description unless it goes looking for that tool (#2171).

**How to apply:** when a PR adds an app tool, add a line to the brief that says when to use it. If only some hosts serve the tool, gate the line the same way the tool list is gated (`offersBrowser`, `offersDriveScreen`, `isBot`, `appToolServed`). A tool named only in AGENTS.md, a skill or its own description is missing for agents.

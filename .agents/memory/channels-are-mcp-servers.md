---
name: channels-are-mcp-servers
description: "Alex 2026-10-16 reversed the Channels layer — Slack/Discord/WhatsApp/email are MCP servers (events in, tools out), not built-in adapters; removal is #1223"
metadata:
  type: project
  modified: 2026-10-17T01:09:25.190Z
---

Chat apps (Slack, Discord, WhatsApp, Teams, email) are MCP servers that emit events and give agents tools to reply. They are not built-in channel adapters. Alex called the #1012/#1009 adapter layer "a mistake" on 2026-10-16.

**Why:** one MCP server is a whole integration (#383). Channel code would have to be kept in step in two control planes (Swift + Go port #1137).

**How to apply:** do not file or build per-service adapters again. #1223 removed Slack + NeedsChannel + --secrets-home on all three clients and both control planes (MERGED 838d1a3b, PR #1230, 2026-10-16). Go records.Settings.Channels was left as dead (the #1136 lane's file). #1008/#1009/#1013/#1014/#1015 were closed as superseded. Needs You in Slack comes back as a workflow plus a Slack MCP server, in a separate issue. Related: [[383-mcp-events-lane-a]].

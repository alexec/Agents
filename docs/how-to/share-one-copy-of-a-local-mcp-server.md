---
diataxis: how-to
description: Have the app run one copy of a local MCP server on a host, shared by every agent and workflow.
---

# Share one copy of a local MCP server

A local (stdio) MCP server is usually started by each agent's runtime, one copy per
session, and by the app once more for a workflow that hears its events. A server that
watches something all day, or that is slow to start, is better run once. Ask the app to
host it.

## Mark it hosted

In the project's `.agents/mcp.json`, or your own `~/.agents/mcp.json`, add
`"hosted": true` to a server with a `command`:

```json
{ "mcpServers": {
    "ci": { "command": "node", "args": ["Integrations/ci-watcher/server.ts"], "hosted": true } } }
```

Only a local server can be hosted: `"hosted"` on an entry with a `url` is a problem with
the file, and the Shared tab says so. A project's entry with `"hosted"` added or changed is
approved again, in the project's **MCP servers** section, as any changed entry is.

## What the app does with it

- **One copy per host.** Each agent is handed the server as an http address on the app's
  own loopback endpoint, with its session's key, so every runtime takes it, Copilot
  included. A workflow's events come from the same copy.
- **Started when used.** The copy starts the first time an agent or a workflow asks it
  something, and is let go once no session has it open and no workflow listens for its
  events. The next call starts it again.
- **Started again when it stops.** A copy that exits while in use is started again after
  1 second, then 2, 4 and so on up to a minute, and back to 1 second once it has run a
  minute. Agents keep their sessions across a restart.
- **Ended with the app.** Stopping or restarting Agents Host ends every hosted copy; the
  next call starts it again. Keep nothing in the server's memory that it cannot rebuild.
- **At most eight** hosted servers in use on a host at once. A ninth runs in each session
  as an ordinary local server, and the app's log says why.

## See what it is doing

**Resources** (under Activity) has a **Hosted MCP servers** group, on the Mac, the Remote
and in a browser: each server, whose file names it, whether it is running, idle or
starting again, and why it last stopped. The server's stderr goes to
`mcp-logs/<name>-<digest>.log` in the app's data folder, rolled at 1 MB.

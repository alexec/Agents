---
diataxis: how-to
description: Have the app run one copy of a local connector on a host, shared by every agent and workflow.
---

# Share one copy of a local connector

A local (stdio) connector, an MCP server, is usually started by each agent's runtime, one copy per
session, and by the app once more for a workflow that hears its events. A server that
watches something all day, or that is slow to start, is better run once. Ask the app to
host it.

## Mark it hosted

In the folder's `.agents/mcp.json`, or your own `~/.agents/mcp.json`, add
`"hosted": true` to a server with a `command`:

```json
{ "mcpServers": {
    "github": { "command": "github-mcp", "hosted": true } } }
```

`github-mcp` is one of the connectors Agents ships: a single binary beside the app's own
`agentsd`, in Agents Host on a Mac and in `~/.agents-server/bin` on a Linux host, which the
app puts first on the PATH of every server it starts. Named by its bare name, the same entry
runs on any host, with nothing else installed there.

Only a local server can be hosted: `"hosted"` on an entry with a `url` is a problem with
the file, and the Agent Configuration page says so. A folder's entry with `"hosted"` added or changed is
approved again, in **Folder Settings ▸ Agent Configuration ▸ Connectors**, as any changed entry is.

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

**Connectors** under Activity lists every connector in your own `~/.agents/mcp.json`, and a
folder's own **Connectors** row, under it in the sidebar, lists the connectors in its
`.agents/mcp.json`. Every folder has the row, also one with no connectors. Both are on the Mac, the Remote and in
a browser (#753). A hosted server's row says whether it is running, idle or starting
again, and why it last stopped. Any other server is checked by the host as a session
would reach it (`initialize`, then `tools/list`) when the app starts, when its entry
changes, every four hours, and on **Check Now**; its row says whether it answered, when,
and why not. A folder's server waiting for approval, and one missing a secret, are never
started to check them. The row's icon in the sidebar turns red when a server does not
answer, or a hosted one stopped while in use.

A hosted server's stderr goes to `mcp-logs/<name>-<digest>.log` in the app's log folder
(`~/Library/Logs/Agents` on a Mac),
rolled at 1 MB. The folder keeps the logs of the newest 32 servers.

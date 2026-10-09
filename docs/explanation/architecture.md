---
diataxis: explanation
description: Which programs make up Agents on a Mac, which one starts which, and how they reach each other.
devices: [mac, iphone, ipad, server]
---

# The processes behind Agents

Agents on a Mac is a handful of programs. Only one of them, the daemon, starts anything to
do with your agents; the window you look at starts nothing. This page shows them all, which
one starts which, and how they connect.

![Processes on this Mac and what starts what](../assets/architecture.svg)

A solid arrow means one program starts another, so the child is in the parent's process
tree. A dashed arrow is a connection, pointing the way it is made.

## What macOS starts

**Agents Host** (`Host/`) is the menu-bar app you install outside the App Store. It does
little itself: it registers two login items with macOS, and launchd runs them from then on,
whether Agents Host is open or not.

| launchd job | Program | What it is |
| --- | --- | --- |
| `com.alexecollins.agentshost.daemon` | `agentsd --control-network` | This Mac's host: the daemon. |
| `com.alexecollins.agentshost.control` | `agents-control serve --port 8791` | The control plane, if it runs on this Mac. |

Both programs are in `Agents Host.app/Contents/Helpers`, beside `agents-relay.app`, which is
optional and not in this build yet. Any other LaunchAgent you add is separate from these,
such as the CI watcher (`com.agents.ci-watcher`, `Integrations/ci-watcher`).

## The clients start nothing

The **Agents window** (`App/`, App Store sandbox), the **Remote** on iPhone and iPad
(`Remote/`) and the **web page** (`Web/`) are clients. Each connects to the control plane,
which passes its requests to the host they concern and sends it updates. A client never has
a child process: a terminal, a file read, a git command or a sign-in it asks for runs on a
host.

The control plane listens on `:8791` (WebSocket over TLS, for windows, phones and hosts) and
on `localhost:8792` (plain http, loopback only, for the web page it serves). See
[The control plane](control-plane.md).

## The daemon starts everything else

`agentsd` owns every agent. It connects out to the control plane like any other host, and
every process to do with an agent is its child, in a process group of its own, so that
stopping an agent or the daemon takes the whole group with it.

- **A runtime per agent.** It speaks ACP over stdio pipes. For Claude that is
  `npm exec @agentclientprotocol/claude-agent-acp` → `node` (the ACP adapter) → `claude`
  (the Agent SDK binary). The runtime starts its own children: shells for its Bash tool, and
  the stdio MCP servers named in `.mcp.json` and in plugins. Codex, Copilot, OpenCode,
  Cursor, Grok and Gemini have the same shape with a different adapter.
- **Terminals.** Shells on a pseudo-terminal: the terminal in the Files pane, and the
  Control-` project shell. Any client draws them, through the control plane.
- **Commands for an agent.** A runtime that asks its client to run a command over ACP's
  `terminal/*` gets one started by the daemon, with its output kept to a cap.
- **MCP servers for events.** A stdio server in `.agents/mcp.json` that a workflow triggers
  on is started by the daemon itself, which polls its `events/poll`.
- **Short-lived helpers.** git, runtime installers, ssh to install on a server, the Claude
  Keychain sign-in, and opening files and Finder for the sandboxed window.

## Connections back into the daemon and out to MCP servers

An agent's own tools, the `mcp__agents__*` ones, are not a process. The daemon serves them
at `http://127.0.0.1:<port>/mcp/agents`, with a token for each session, and the runtime
calls them there. Before #185 each runtime started an `agentsd mcp` helper for this; that
helper is gone.

An http MCP server, such as the CI watcher on `127.0.0.1:8795`, is not started by anyone in
this tree. Runtimes call its tools over http, and the daemon polls its events over http.

## Other hosts

A Linux server, or another Mac running Agents Host, runs the same `agentsd`, with the same
tree of children under it. It connects out to the control plane, so nothing has to be able
to reach it. Its agents, terminals and records stay on it.

## Related

- [The window and the host](window-and-daemon.md).
- [The control plane](control-plane.md).
- [How the phone and iPad reach your agents](phone-and-ipad.md).

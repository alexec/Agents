---
diataxis: how-to
devices: [mac]
description: Put your skills, instructions, MCP servers and plugins in ~/.agents once, and every agent the app starts gets them, on every runtime.
---

# Share skills, instructions and servers with every agent

`~/.agents` in your home folder is your own set of things every agent should have: how you
like to work, your skills, your MCP servers and your plugins. Put each one there once, and
every agent the app starts gets it, whichever runtime it runs on and whichever project it is
in. You do not set anything up per runtime.

| Put this | Here | Every agent then |
| --- | --- | --- |
| How you like to work | `~/.agents/AGENTS.md` | reads it as your personal instructions |
| A skill | `~/.agents/skills/<name>/SKILL.md` | is offered the skill |
| MCP servers | `~/.agents/mcp.json` | has the servers' tools |
| A plugin | `~/.agents/plugins/<name>/` | gets its skills, commands and servers, where the runtime can take a plugin |

A project's own `.agents` folder still applies inside that project, as well as these.

## Before you start

- The app has made `~/.agents`, with `skills/` and `personas/` in it, the first time it ran.
  A copy of the app built to try something out, on a folder of its own, leaves your home
  folder alone and does none of this.

## Add a skill

1. Make a folder in `~/.agents/skills` named for the skill, with a `SKILL.md` in it, the
   same shape as a Claude Code skill: a front matter with `name` and `description`, then
   the instructions.
2. Start an agent. You do not need to restart the app: it checks `~/.agents` before
   every agent starts.

Codex, Grok, Cursor and Copilot read `~/.agents/skills` themselves. For Claude the app puts
a link to the skill in `~/.claude/skills`, and for Antigravity a link in the folder the app
gives it. If you delete one of those links, the app does not put it back, so deleting the
link is how you keep one skill away from Claude.

## Write your instructions

Edit `~/.agents/AGENTS.md`. The app links it into the file each runtime reads:
`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.grok/AGENTS.md` and
`~/.copilot/copilot-instructions.md`. Cursor keeps its User Rules in its own settings, and
Antigravity reads no instructions file when the app starts it, so neither gets it.

## Add an MCP server

Add it to `~/.agents/mcp.json`, in the same shape Claude Code and Cursor use:

```json
{
  "mcpServers": {
    "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                "env": { "GITHUB_TOKEN": "…" } },
    "docs":   { "url": "https://example.com/mcp", "headers": { "Authorization": "Bearer …" } },
    "older":  { "type": "sse", "url": "https://example.com/sse" }
  }
}
```

A server with `command` runs on your Mac; one with `url` is reached over http, or sse when
`type` says so. The next agent to start, or to be picked back up, has it. The file is read
each time and never copied anywhere, and its env and header values are never shown or
logged. **Settings ▸ Shared** lists them by name only.

What each runtime does with them:

- Copilot takes no server it would have to start itself, so the app runs those for it and
  hands it each one over a local http address that only that agent can use. This is also
  how Copilot agents get the app's own tools.
- Codex takes no sse servers: those are left out for Codex agents.
- If a runtime has a server of the same name in its own config, Codex and Copilot use their
  own, Claude and Grok use yours, and Cursor runs both.
- If `mcp.json` cannot be read, agents still start, without your servers, and **Settings ▸
  Shared** says what is wrong and on which line.

## Add a plugin

Put the plugin's folder in `~/.agents/plugins`, laid out as a Claude Code plugin is, with
its `.claude-plugin/plugin.json`, and `.mcp.json` if it has servers.

- Claude and Grok are handed it when an agent starts. Grok does not start a plugin's
  servers itself, so the app sends them along with your MCP servers.
- Codex keeps a copy of each plugin. The app writes `~/.agents/plugins/marketplace.json`
  and adds the plugin to Codex, and adds it again whenever anything in its folder changes,
  before the next Codex agent starts. An index you wrote yourself is left alone.
- Gemini gets a link in `~/.gemini/extensions`. Gemini has no folder for a project's own
  plugins, so before a Gemini agent starts, each plugin in the project's `.agents/plugins`
  gets a link there too, switched on only inside that project in
  `~/.gemini/extensions/extension-enablement.json`. A name Gemini already has is left to
  whoever has it: two extensions with one name stop Gemini loading any.
- Cursor, Copilot and Antigravity cannot take a plugin from the app.

To remove a plugin, delete its folder. The next agent starts without it, and the app takes
it out of Codex and removes its Gemini link.

## A project's own plugins

A project can also keep plugins in `.agents/plugins` inside the project folder. Those
apply only in that project. Because a plugin can run hooks and start MCP servers when a
session begins, a new or changed project plugin does not reach any agent until you approve
it on the project's page — the same idea as [a workflow waiting for your OK](set-up-a-workflow.md).

On the Mac, open the project. Under **Plugins**, each plugin lists what it carries. One
that is new or has changed since you approved it says it is waiting; click **Approve**
(or **Show in Finder** first if you want to look). Plugins that were already there when
this version began were approved as they stood. Your own plugins in `~/.agents/plugins`
are never asked about: that folder is yours.

## What the app moves in the first time

The first time it lays out `~/.agents`, the app takes in what Claude already has, so that
nothing needs copying by hand:

- Each skill folder in `~/.claude/skills` moves to `~/.agents/skills`, and a link to it takes
  its place. A skill with the same name already in `~/.agents/skills` is a clash: both are
  left exactly where they are, and **Settings ▸ Shared** shows it.
- If there is no `~/.agents/AGENTS.md`, the first instructions file found moves there, from
  Claude, then Codex, then Copilot, then Grok, and is linked back. With none anywhere, the app
  writes a short `AGENTS.md` that says what it is for.

Folders another tool keeps in step, such as claude.ai's synced skills, are never moved,
linked into or deleted.

## See what every agent gets

Open **Settings ▸ Shared**. The overview shows, for each runtime, how many of your
instructions, skills, servers and plugins it gets, and lists everything that needs a look:
a clash, something left out, a runtime with no way in. Each page has **Edit** to open the
file in your editor and **Reveal in Finder**.

## See also

- [Settings](../reference/settings.md)
- [Runtimes](../reference/runtimes.md)
- [Projects, hosts and worktrees](../explanation/projects-hosts-worktrees.md)

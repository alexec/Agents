---
diataxis: reference
devices: [mac, server]
description: The four coding agents the app can start, what it runs for each, and what each can do in the app.
---

# Runtimes

A runtime is the coding agent that does the work in a conversation. This page lists the
four the app knows how to start. You install and sign in to each one yourself; the app
finds it on your Mac, or on a server when the project is on a server.

What a runtime can do in the app is decided by what it says about itself when it starts,
not by its name. The columns for pictures and signing in are what each runtime said when
it was last measured. If a newer version says something different, the app follows the
newer version.

| Runtime | Command it starts | Pictures | Sign in from the app | App tools available | Notes |
| --- | --- | --- | --- | --- | --- |
| **Claude** | `npx -y @agentclientprotocol/claude-agent-acp` | Yes | No. Sign in with Claude Code itself, outside the app. | All | `claude` has no mode the app can talk to, so the app runs this adapter through your Node instead. Its questions reach you as a card you can answer on the Mac or phone. It asks your permission before using some of the app's tools. |
| **Grok** | `grok agent stdio` | No | Yes, with **grok.com** | All | It cannot ask you a question mid-turn in a way the app can show, so it ends its turn with the question instead, and the agent shows **Waiting on your answer**. Its image and video generation is switched off for the conversations the app starts. |
| **Copilot** | `copilot --acp` | Yes | Hands you the exact command to run in Terminal, with **Open Terminal** and **Copy** | None | Its conversations get none of the app's tools, including the one it uses to say how a turn went, so its turns end without a report. It uses its own follow-up suggestions instead of the app's. It asks permission before every tool call. |
| **Cursor** | `cursor-agent acp` | Yes | Yes | All | The command is `cursor-agent`, not `agent`, which is Grok's. It offers no options to pick from and no way to sign out, so the app shows neither. Three of its own tools, which overlap with the app's, cannot be turned off. It asks your permission before using some of the app's tools. |

In every column:

- **Pictures**: a picture you attach goes to the runtime as the picture itself where it
  takes pictures, and as a reference to the file where it does not. An attachment a
  runtime cannot take is refused before the prompt is sent.
- **Sign in from the app**: when a runtime needs signing in, the runtime menu above the
  prompt says **Needs signing in**, and **Sign in, sign out, providers…** opens the
  runtime's sign-in. The sheet says one of **Signed in and ready**, **Installed, and
  needs signing in** or **Not asked yet**.
- **App tools available**: the tools on [Tools the app gives agents](agent-tools.md).
- **On a server**: an agent in a server project is offered only the runtimes on that
  server. Claude is the exception: with a Claude token in **Settings ▸ Servers**, Agents
  installs Claude on the server itself and signs it in with that token. See
  [Add a Linux server](../how-to/add-a-linux-server.md).

For the conversations the app starts, each runtime's own tools for scheduling, starting
other agents, sending notifications and saving documents elsewhere are taken away, so that
the work stays where the app can see it. Reading, searching, editing, running commands,
planning and asking you questions are not touched. The same runtime started from Terminal
has everything it always had.

## See also

- [How-to guides](../how-to/index.md)
- [Explanation](../explanation/index.md)
